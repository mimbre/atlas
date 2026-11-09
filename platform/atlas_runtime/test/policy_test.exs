defmodule AtlasRuntime.PolicyTest do
  use ExUnit.Case, async: true
  alias AtlasRuntime.{Availability, Policy}
  @moduletag :tmp_dir

  @now 1_794_050_000
  @claude %{"provider" => "anthropic", "harness" => "claude", "model" => "claude-opus-5-5"}
  @codex %{"provider" => "openai", "harness" => "codex", "model" => "gpt-6.1-sol"}
  # The S1 mini policy (design §7, §13 S1d): deep_coding prefers Claude, then Codex.
  @mini %{
    "version" => 3,
    "changed_by" => "operator",
    "changed_at" => "2026-11-16T09:00:00Z",
    "slots" => ["dev1", "dev2"],
    "profiles" => %{
      "deep_coding" => %{
        "permissions" => ["dedicated-repository", "materialized-folder", "workspace-write"],
        "cost_classes" => ["standard", "high"],
        "options" => [@claude, @codex],
        "limits" => %{"max_duration" => 7_200}
      },
      "independent_review" => %{
        "permissions" => ["review-packet", "read-only"],
        "cost_classes" => ["low", "standard"],
        "options" => [@codex, @claude]
      }
    }
  }
  @weekly Path.join(__DIR__, "fixtures/claude_weekly_quota.json")
          |> File.read!()
          |> JSON.decode!()
          |> Map.fetch!("rate_limit_info")
  @reset @weekly["resetsAt"]

  defp write_policy(dir, policy), do: File.write!(Policy.path(dir), JSON.encode!(policy))

  defp loaded(dir, policy \\ @mini) do
    write_policy(dir, policy)
    Policy.load(dir)
  end

  # Codex has no credits: marked out locally, with no known return.
  defp codex_out(availability) do
    put_in(availability, ["quota", "codex"], %{
      "evidence" => %{"source" => "operator", "note" => "no credits", "resetsAt" => nil},
      "turn_id" => nil,
      "observed_at" => @now,
      "reenabled_at" => nil
    })
  end

  defp claude_out(availability, reset \\ @reset) do
    put_in(availability, ["quota", "claude"], %{
      "evidence" => Map.put(@weekly, "resetsAt", reset),
      "turn_id" => "turn-00000000000000aa",
      "observed_at" => @now,
      "reenabled_at" => nil
    })
  end

  defp request(changes \\ %{}),
    do:
      Map.merge(
        %{profile: "deep_coding", cost_class: :standard, permission: "dedicated-repository"},
        changes
      )

  describe "resolution table (design §7)" do
    test "each row resolves mechanically", %{tmp_dir: dir} do
      policy = loaded(dir)
      none = Availability.empty()
      both = ["claude", "codex"]
      until = DateTime.from_unix!(@reset)

      rows = [
        {"unknown profile", policy, none, request(%{profile: "other"}), both,
         {:refused, :policy_forbids}},
        {"disallowed permission", policy, none, request(%{permission: "review-packet"}), both,
         {:refused, :policy_forbids}},
        {"disallowed cost class", policy, none, request(%{cost_class: "low"}), both,
         {:refused, :policy_forbids}},
        {"missing policy.json", {:error, :missing}, none, request(), both,
         {:refused, :policy_forbids}},
        {"all available", policy, none, request(), both, {:ok, @claude, "preferred", []}},
        {"Codex out: Claude preferred", policy, codex_out(none), request(), both,
         {:ok, @claude, "preferred", []}},
        {"Claude out: Codex fallback", policy, claude_out(none), request(), both,
         {:ok, @codex, "fallback",
          [%{"option" => @claude, "why" => "quota", "until" => DateTime.to_iso8601(until)}]}},
        {"Claude and Codex out: profile_unavailable until Claude's reset", policy,
         none |> claude_out() |> codex_out(), request(), both,
         {:at_capacity, :profile_unavailable, until}},
        {"Claude out without reset, Codex not installed: unavailable, no until", policy,
         claude_out(none, nil), request(), ["claude"], {:at_capacity, :profile_unavailable, nil}},
        {"nothing installed", policy, none, request(), [], {:refused, :no_permitted_option}},
        {"delisted resume option", policy, none,
         request(%{resume: Map.put(@claude, "model", "claude-sonnet-4-6")}), both,
         {:refused, :resume_unavailable}},
        {"listed resume option continues even while out", policy, claude_out(none),
         request(%{resume: @claude}), both, {:ok, @claude, "continuation", []}},
        {"workspace-write skips Claude, which cannot serve it", policy, none,
         request(%{permission: "workspace-write"}), both,
         {:ok, @codex, "fallback", [%{"option" => @claude, "why" => "unsupported_permission"}]}},
        {"at Claude's reset it is preferred again", policy, claude_out(none), request(), both,
         {:ok, @claude, "preferred", []}, @reset}
      ]

      for row <- rows do
        row = if tuple_size(row) == 6, do: Tuple.insert_at(row, 6, @now), else: row
        {name, policy, availability, request, installed, expected, now} = row
        result = Policy.resolve(policy, availability, request, installed, now)

        case {expected, result} do
          {{:refused, reason}, {:refused, reason, detail}} ->
            assert is_binary(detail), name

          {{:ok, option, reason, skipped}, {:ok, selection}} ->
            assert selection["option"] == option, name
            assert selection["reason"] == reason, name
            assert selection["skipped"] == skipped, name
            assert selection["profile"] == "deep_coding", name
            assert selection["policy_version"] == 3, name

            assert selection["selected"] == %{
                     "backend" => option["harness"],
                     "model" => option["model"]
                   },
                   name

          {{:at_capacity, reason, until}, {:at_capacity, reason, detail}} ->
            assert detail.until == until, name

          _ ->
            flunk("#{name}: expected #{inspect(expected)}, got #{inspect(result)}")
        end
      end
    end

    test "an invalid policy forbids everything rather than guessing", %{tmp_dir: dir} do
      File.write!(Policy.path(dir), "{\"version\": 1")

      assert {:refused, :policy_forbids, detail} =
               Policy.resolve(Policy.load(dir), Availability.empty(), request(), ["claude"], @now)

      assert detail =~ "invalid"
    end

    test "a skipped permanent cause never turns a temporary one into a refusal", %{tmp_dir: dir} do
      # Codex not installed (permanent), Claude out of quota (temporary): the client waits.
      assert {:at_capacity, :profile_unavailable, _} =
               Policy.resolve(
                 loaded(dir),
                 claude_out(Availability.empty()),
                 request(),
                 &(&1 == "claude"),
                 @now
               )
    end
  end

  describe "profiles/4 (capacity view)" do
    test "per profile availability without request checks", %{tmp_dir: dir} do
      policy = loaded(dir)
      out = Availability.empty() |> claude_out() |> codex_out()
      until = DateTime.from_unix!(@reset)

      assert Policy.profiles(policy, codex_out(Availability.empty()), ["claude", "codex"], @now) ==
               %{"deep_coding" => %{available: true}, "independent_review" => %{available: true}}

      assert Policy.profiles(policy, out, ["claude", "codex"], @now)["deep_coding"] ==
               %{available: false, reason: :quota, until: until}

      assert Policy.profiles(policy, Availability.empty(), [], @now)["deep_coding"] ==
               %{available: false, reason: :not_installed}

      assert Policy.profiles({:error, :missing}, Availability.empty(), [], @now) == %{}
    end
  end

  describe "slots, buffer and limits" do
    test "slots follow F1 and the buffer defaults to one per slot", %{tmp_dir: dir} do
      assert Policy.slots({:error, :missing}) == ["default"]
      assert Policy.buffer_size({:error, :missing}) == 1
      policy = loaded(dir)
      assert Policy.slots(policy) == ["dev1", "dev2"]
      assert Policy.buffer_size(policy) == 2
      unslotted = loaded(dir, Map.delete(@mini, "slots") |> Map.put("buffer_size", 6))
      assert Policy.slots(unslotted) == ["default"]
      assert Policy.buffer_size(unslotted) == 6
    end

    test "limits use the profile's max_duration, else the design defaults", %{tmp_dir: dir} do
      policy = loaded(dir)

      assert Policy.limits(policy, "deep_coding") ==
               %{max_duration: 7_200, cancel_grace: 30, retry_after: 60}

      assert Policy.limits(policy, "independent_review").max_duration == 3_600
      assert Policy.limits({:error, :missing}, "light_work").max_duration == 1_800
    end
  end

  describe "load/1" do
    test "missing is distinct from invalid", %{tmp_dir: dir} do
      assert Policy.load(dir) == {:error, :missing}
      assert {:ok, @mini} = loaded(dir)
    end

    test "strict validation names the offending field", %{tmp_dir: dir} do
      deep = @mini["profiles"]["deep_coding"]

      for {policy, why} <- [
            {Map.put(@mini, "preferred", "claude"), "unknown fields"},
            {Map.delete(@mini, "version"), "version"},
            {Map.put(@mini, "slots", ["dev1", "dev1"]), "slots"},
            {Map.put(@mini, "slots", ["Dev 1"]), "slots"},
            {Map.put(@mini, "slots", []), "slots"},
            {Map.put(@mini, "buffer_size", -1), "buffer_size"},
            {Map.put(@mini, "independence", %{"different_from" => "vendor"}), "independence"},
            {put_in(@mini, ["profiles", "deep_coding"], Map.put(deep, "options", [])), "options"},
            {put_in(@mini, ["profiles", "deep_coding", "options"], [
               Map.put(@claude, "harness", "gemini")
             ]), "options"},
            {put_in(@mini, ["profiles", "deep_coding", "options"], [
               Map.put(@claude, "model", "--unsafe")
             ]), "options"},
            {put_in(@mini, ["profiles", "deep_coding", "permissions"], ["unrestricted"]),
             "permissions"},
            {put_in(@mini, ["profiles", "deep_coding", "cost_classes"], ["free"]),
             "cost_classes"},
            {put_in(@mini, ["profiles", "deep_coding", "limits"], %{"max_duration" => 0}),
             "limits"},
            # Each strict-shape check alone refuses an extra key.
            {put_in(@mini, ["profiles", "deep_coding", "notes"], "x"),
             ~s("deep_coding": unknown fields)},
            {put_in(@mini, ["profiles", "deep_coding", "options"], [
               Map.put(@claude, "notes", "x"),
               @codex
             ]), ~s("deep_coding": options)},
            {put_in(@mini, ["profiles", "deep_coding", "limits"], %{
               "max_duration" => 7_200,
               "cancel_grace" => 30
             }), ~s("deep_coding": limits)}
          ] do
        write_policy(dir, policy)
        assert {:error, {:invalid, message}} = Policy.load(dir)
        assert message =~ why, inspect({why, message})
      end
    end

    test "an explicit backend gets the policy's model only when unambiguous", %{tmp_dir: dir} do
      policy = loaded(dir)
      assert Policy.configured_model(policy, "claude") == "claude-opus-5-5"

      ambiguous =
        put_in(@mini, ["profiles", "independent_review", "options"], [
          Map.put(@codex, "model", "gpt-6.1-mini")
        ])

      assert Policy.configured_model(loaded(dir, ambiguous), "codex") == nil
      assert Policy.configured_model({:error, :missing}, "codex") == nil
    end
  end

  describe "availability.json (the former claude_quota evidence)" do
    test "weekly evidence is recorded atomically with its turn and survives reload", %{
      tmp_dir: dir
    } do
      entry = Availability.record_quota(dir, "claude", @weekly, "turn-00000000000000aa", @now)

      assert entry == %{
               "evidence" => @weekly,
               "turn_id" => "turn-00000000000000aa",
               "observed_at" => @now,
               "reenabled_at" => nil
             }

      assert Availability.load(dir)["quota"]["claude"] == entry
      refute File.exists?(Availability.path(dir) <> ".tmp")
      assert Availability.status(Availability.load(dir), "claude", @reset - 1) == {:out, @reset}
      assert Availability.status(Availability.load(dir), "claude", @reset) == :available
      assert Availability.status(Availability.load(dir), "codex", @now) == :available
    end

    test "authentication, network, other windows and usable overage are never quota", %{
      tmp_dir: dir
    } do
      for event <- [
            %{"type" => "error", "message" => "weekly limit authentication network"},
            Map.put(@weekly, "rateLimitType", "five_hour"),
            Map.put(@weekly, "status", "allowed"),
            Map.put(@weekly, "overageStatus", "allowed"),
            Map.put(@weekly, "isUsingOverage", true)
          ] do
        assert Availability.record_quota(dir, "claude", event, "turn-00000000000000aa", @now) ==
                 nil
      end

      refute File.exists?(Availability.path(dir))
    end

    test "unknown resets stay out until a local re-enable, which keeps the evidence", %{
      tmp_dir: dir
    } do
      for reset <- [nil, "1pm", -1] do
        Availability.record_quota(
          dir,
          "claude",
          Map.put(@weekly, "resetsAt", reset),
          "turn-00000000000000aa",
          @now
        )

        availability = Availability.load(dir)
        assert availability["quota"]["claude"]["evidence"]["resetsAt"] == nil
        assert Availability.status(availability, "claude", @now + 99_999_999) == {:out, nil}
      end

      enabled = put_in(Availability.load(dir), ["quota", "claude", "reenabled_at"], @now)
      Availability.persist(dir, enabled)
      assert Availability.status(Availability.load(dir), "claude", @now) == :available
      assert Availability.load(dir)["quota"]["claude"]["evidence"]["rateLimitType"] == "seven_day"
    end

    test "a recording keeps a local operator mark for another harness", %{tmp_dir: dir} do
      Availability.persist(dir, codex_out(Availability.empty()))
      Availability.record_quota(dir, "claude", @weekly, "turn-00000000000000aa", @now)
      availability = Availability.load(dir)
      assert Availability.status(availability, "codex", @now) == {:out, nil}
      assert Availability.status(availability, "claude", @now) == {:out, @reset}
    end

    test "invalid evidence fails visibly", %{tmp_dir: dir} do
      for bytes <- [
            "not json",
            JSON.encode!(%{"format_version" => 2, "quota" => %{}}),
            JSON.encode!(%{"format_version" => 1, "quota" => %{"gemini" => %{}}}),
            JSON.encode!(%{
              "format_version" => 1,
              "quota" => %{
                "codex" => %{
                  "evidence" => %{"message" => "quota"},
                  "turn_id" => nil,
                  "observed_at" => @now,
                  "reenabled_at" => nil
                }
              }
            })
          ] do
        File.write!(Availability.path(dir), bytes)
        assert_raise RuntimeError, fn -> Availability.load(dir) end
      end
    end

    test "extra fields are refused, each by its own check", %{tmp_dir: dir} do
      native = claude_out(Availability.empty())
      operator = codex_out(Availability.empty())

      pair = %{
        "preferred" => %{"backend" => "claude", "model" => nil},
        "fallback" => %{"backend" => "codex", "model" => nil}
      }

      # Each base is valid; each change adds one field (or swaps the pair) and must be refused.
      for valid <- [native, operator, Map.put(native, "preferences", pair)],
          do: assert(Availability.validate!(valid) == valid)

      for {availability, why} <- [
            {put_in(native, ["quota", "claude", "note"], "x"), "quota record"},
            {put_in(operator, ["quota", "codex", "evidence", "by"], "x"), "quota evidence"},
            {Map.put(native, "notes", "x"), "unknown fields"},
            {Map.put(native, "preferences", Map.put(pair, "x", 1)), "preferences"},
            {Map.put(native, "preferences", put_in(pair, ["preferred", "x"], 1)), "preferences"},
            {Map.put(native, "preferences", %{
               "preferred" => pair["fallback"],
               "fallback" => pair["preferred"]
             }), "preferences"}
          ] do
        File.write!(Availability.path(dir), JSON.encode!(availability))
        error = assert_raise RuntimeError, fn -> Availability.load(dir) end
        assert Exception.message(error) =~ why, inspect({why, Exception.message(error)})
      end
    end

    test "backends.json quota is imported once and never read again", %{tmp_dir: dir} do
      legacy = %{
        "preferred" => %{"backend" => "claude", "model" => "claude-opus-5-5[1m]"},
        "fallback" => %{"backend" => "codex", "model" => "gpt-6.1-sol"},
        "claude_quota" => %{
          "evidence" => @weekly,
          "turn_id" => "native-quota-turn",
          "observed_at" => @now,
          "reenabled_at" => nil
        }
      }

      File.write!(Path.join(dir, "backends.json"), JSON.encode!(legacy))
      assert :ok = Availability.import_legacy!(dir)
      assert Availability.load(dir)["quota"] == %{"claude" => legacy["claude_quota"]}

      assert Availability.preferences(Availability.load(dir)) ==
               Map.take(legacy, ["preferred", "fallback"])

      File.write!(
        Path.join(dir, "backends.json"),
        JSON.encode!(%{legacy | "claude_quota" => nil})
      )

      assert :ok = Availability.import_legacy!(dir)
      assert Availability.load(dir)["quota"] == %{"claude" => legacy["claude_quota"]}
    end

    test "no backends.json writes nothing; a corrupt one fails visibly", %{tmp_dir: dir} do
      assert :ok = Availability.import_legacy!(dir)
      refute File.exists?(Availability.path(dir))
      File.write!(Path.join(dir, "backends.json"), "corrupt")
      assert_raise RuntimeError, fn -> Availability.import_legacy!(dir) end
      refute File.exists?(Availability.path(dir))
    end
  end
end

defmodule AtlasRuntime.PolicyServiceTest do
  # The Service resolves profile starts through the files, and `preferences` only reads.
  use ExUnit.Case, async: false
  alias AtlasRuntime.{Availability, Policy, Service}
  @moduletag capture_log: true

  @claude %{"provider" => "anthropic", "harness" => "claude", "model" => "claude-opus-5-5"}
  @codex %{"provider" => "openai", "harness" => "codex", "model" => "gpt-6.1-sol"}
  @policy %{
    "version" => 7,
    "profiles" => %{
      "deep_coding" => %{
        "permissions" => ["read-only", "workspace-write", "materialized-folder"],
        "cost_classes" => ["standard"],
        "options" => [@claude, @codex]
      }
    }
  }

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "ap-#{Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)}"
      )

    bin = Path.join(dir, "bin")
    workspace = Path.join(dir, "workspace")
    File.mkdir_p!(bin)
    File.mkdir_p!(workspace)
    previous_path = System.fetch_env!("PATH")
    previous_home = System.get_env("CODEX_HOME")
    System.put_env("CODEX_HOME", Path.join(dir, "codex-home"))

    for backend <- ["codex", "claude"],
        do: AtlasRuntime.FakeNative.install!(Path.join(bin, backend), "admission", [dir])

    System.put_env("PATH", bin)

    on_exit(fn ->
      System.put_env("PATH", previous_path)

      if previous_home,
        do: System.put_env("CODEX_HOME", previous_home),
        else: System.delete_env("CODEX_HOME")

      File.rm_rf!(dir)
    end)

    %{dir: dir, workspace: workspace}
  end

  # Registered: runtime.sock forwards each line to the named Service.
  defp launch(dir) do
    {:ok, pid} = GenServer.start(Service, dir, name: Service)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    pid
  end

  defp call(pid, request) do
    {reply, false} = GenServer.call(pid, request, 10_000)
    reply
  end

  defp finished(pid, worker) do
    Enum.find_value(1..200, fn _ ->
      run = call(pid, %{"command" => "status", "worker_id" => worker})
      if run[:state] in ["finished", "failed"], do: run, else: Process.sleep(25) && nil
    end) || flunk("turn did not end")
  end

  defp start(context, worker, changes \\ %{}),
    do:
      Map.merge(
        %{
          "command" => "start",
          "worker_id" => worker,
          "cwd" => context.workspace,
          "assignment" => "admit:#{worker}",
          "profile" => "deep_coding",
          "cost_class" => "standard"
        },
        changes
      )

  defp send_line(dir, request) do
    {:ok, socket} =
      :gen_tcp.connect({:local, Path.join(dir, "runtime.sock")}, 0, [
        :binary,
        active: false,
        packet: :line
      ])

    :ok = :gen_tcp.send(socket, JSON.encode!(request) <> "\n")
    {:ok, line} = :gen_tcp.recv(socket, 0, 5_000)
    :gen_tcp.close(socket)
    JSON.decode!(line)
  end

  test "a profile start runs the policy's preferred option and records the selection", context do
    File.write!(Policy.path(context.dir), JSON.encode!(@policy))
    service = launch(context.dir)

    run = call(service, start(context, "dev1"))
    assert run.backend == "claude"
    assert run.requested_model == "claude-opus-5-5"
    assert run.selection["reason"] == "preferred"
    assert run.selection["option"] == @claude
    assert run.selection["policy_version"] == 7
    saved = finished(service, "dev1")
    assert saved[:selection]["profile"] == "deep_coding"

    # Claude's weekly quota is out: the next start, read from the files, falls back.
    Availability.record_quota(
      context.dir,
      "claude",
      %{"status" => "rejected", "rateLimitType" => "seven_day", "resetsAt" => nil},
      run.id,
      System.system_time(:second)
    )

    run = call(service, start(context, "dev2"))
    assert run.backend == "codex"
    assert run.selection["reason"] == "fallback"
    assert [%{"option" => @claude, "why" => "quota"}] = run.selection["skipped"]
    finished(service, "dev2")
  end

  test "profile starts refuse without a launch when the policy forbids or nothing is left",
       context do
    service = launch(context.dir)
    assert call(service, start(context, "dev1"))[:command_error] =~ "policy_forbids"

    File.write!(Policy.path(context.dir), JSON.encode!(@policy))

    assert call(service, start(context, "dev1", %{"cost_class" => "high"}))[:command_error] =~
             "policy_forbids"

    assert call(service, start(context, "dev1", %{"backend" => "codex"}))[:command_error] =~
             "cannot be combined"

    assert call(service, start(context, "dev1") |> Map.delete("cost_class"))[:command_error] =~
             "together"

    out = %{
      "evidence" => %{"source" => "operator", "note" => "no credits", "resetsAt" => nil},
      "turn_id" => nil,
      "observed_at" => 1,
      "reenabled_at" => nil
    }

    Availability.persist(context.dir, %{
      Availability.empty()
      | "quota" => %{"claude" => out, "codex" => out}
    })

    assert call(service, start(context, "dev1"))[:command_error] =~ "profile_unavailable"
    refute File.exists?(Path.join(context.dir, "native-starts.jsonl"))
  end

  test "preferences answers on runtime.sock and cannot write policy or availability", context do
    File.write!(Policy.path(context.dir), JSON.encode!(@policy))
    File.write!(Path.join(context.dir, "backends.json"), JSON.encode!(%{"claude_quota" => nil}))
    launch(context.dir)
    policy = File.read!(Policy.path(context.dir))
    availability = File.read!(Availability.path(context.dir))

    view = send_line(context.dir, %{"command" => "preferences"})
    assert view["policy"] == @policy
    assert view["policy_error"] == nil
    assert view["slots"] == ["default"]
    assert view["buffer_size"] == 1
    assert view["profiles"] == %{"deep_coding" => %{"available" => true}}
    assert view["availability"]["status"]["claude"] == %{"available" => true}

    for write <- [
          %{"command" => "preferences", "preferred" => "claude", "fallback" => "codex"},
          %{"command" => "preferences", "reenable" => "claude"},
          %{"command" => "preferences", "policy" => %{"version" => 8}}
        ] do
      assert send_line(context.dir, write)["command_error"] =~ "only reads"
    end

    assert File.read!(Policy.path(context.dir)) == policy
    assert File.read!(Availability.path(context.dir)) == availability
    File.rm!(Policy.path(context.dir))
    assert send_line(context.dir, %{"command" => "preferences"})["policy_error"] == "missing"
  end

  test "a start with neither profile nor backend follows the imported preference pair",
       context do
    # Before D3 the CLI may omit both: BackendPolicy's preferred/fallback choice still applies.
    File.write!(Policy.path(context.dir), JSON.encode!(@policy))
    preferred = %{"backend" => "claude", "model" => "claude-opus-5-5[1m]"}
    fallback = %{"backend" => "codex", "model" => "gpt-6.1-sol"}

    File.write!(
      Path.join(context.dir, "backends.json"),
      JSON.encode!(%{"preferred" => preferred, "fallback" => fallback, "claude_quota" => nil})
    )

    service = launch(context.dir)
    legacy = &(start(context, &1) |> Map.drop(["profile", "cost_class"]))

    run = call(service, legacy.("dev1"))
    assert run.backend == "claude"
    assert run.requested_model == "claude-opus-5-5[1m]"

    assert run.selection == %{
             "requested" => preferred,
             "selected" => preferred,
             "reason" => "preferred"
           }

    saved = finished(service, "dev1")

    # Claude's weekly quota is confirmed out: the fallback runs, with the evidence.
    entry =
      Availability.record_quota(
        context.dir,
        "claude",
        %{"status" => "rejected", "rateLimitType" => "seven_day", "resetsAt" => nil},
        saved.id,
        System.system_time(:second)
      )

    run = call(service, legacy.("dev2"))
    assert run.backend == "codex"
    assert run.requested_model == "gpt-6.1-sol"
    assert run.selection["requested"] == preferred
    assert run.selection["selected"] == fallback
    assert run.selection["reason"] == "confirmed_weekly_quota"
    assert run.selection["quota"] == entry
    finished(service, "dev2")

    # Re-enabled locally: Claude again.
    Availability.persist(
      context.dir,
      put_in(Availability.load(context.dir), ["quota", "claude", "reenabled_at"], 1)
    )

    assert call(service, legacy.("dev1")).selection["reason"] == "preferred"
    finished(service, "dev1")

    # Without an imported pair: Codex, as before.
    Availability.persist(context.dir, Availability.empty())
    run = call(service, legacy.("dev2"))
    assert {run.backend, run.selection["reason"]} == {"codex", "default"}
    finished(service, "dev2")
  end

  test "service start imports a former backends.json quota once", context do
    quota = %{
      "evidence" => %{"status" => "rejected", "rateLimitType" => "seven_day", "resetsAt" => nil},
      "turn_id" => "turn-00000000000000aa",
      "observed_at" => 1_794_050_000,
      "reenabled_at" => nil
    }

    File.write!(Path.join(context.dir, "backends.json"), JSON.encode!(%{"claude_quota" => quota}))
    service = launch(context.dir)
    assert Availability.load(context.dir)["quota"]["claude"] == quota

    assert call(service, %{"command" => "preferences"})["availability"]["status"]["claude"] ==
             %{"available" => false, "until" => nil}
  end
end
