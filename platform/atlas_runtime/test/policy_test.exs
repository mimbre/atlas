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
        "permissions" => ["read-only"],
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
        {"disallowed permission", policy, none,
         request(%{profile: "independent_review", permission: "workspace-write"}), both,
         {:refused, :policy_forbids}},
        # The removed review-packet profile is no permission: a policy that still lists it
        # is invalid and permits nothing (fail closed).
        {"policy listing review-packet",
         loaded(
           dir,
           put_in(@mini, ["profiles", "deep_coding", "permissions"], [
             "dedicated-repository",
             "review-packet"
           ])
         ), none, request(), both,
         {:refused, :policy_forbids,
          ~r/\Ainvalid policy\.json: .*permissions must be a non-empty list of dedicated-repository, materialized-folder, workspace-write, read-only\z/}},
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

          {{:refused, reason, pattern}, {:refused, reason, detail}} ->
            assert detail =~ pattern, name

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

  # Main's #330 round 3: one availability rule for the offer and a retry's check. A profile
  # is available for a work only when an option that serves that work's permission is.
  describe "available?/6 (the one rule)" do
    @light %{
      "version" => 1,
      "profiles" => %{
        "light_work" => %{
          "permissions" => ["read-only", "workspace-write", "materialized-folder"],
          "cost_classes" => ["standard"],
          "options" => [@codex, @claude]
        }
      }
    }

    test "per permission: Codex quota-marked leaves light_work for read-only, not workspace-write",
         %{tmp_dir: dir} do
      policy = loaded(dir, @light)
      out = codex_out(Availability.empty())
      both = ["claude", "codex"]
      available? = &Policy.available?(policy, &1, "light_work", &2, both, @now)

      assert available?.(Availability.empty(), "workspace-write")
      refute available?.(out, "workspace-write")
      assert available?.(out, "read-only")
      assert available?.(out, :"materialized-folder")

      # The offer's view: available for some permission it permits.
      assert Policy.profiles(policy, out, both, @now)["light_work"] == %{available: true}

      # resolve/5 agrees with it for every permission.
      for permission <- ["read-only", "workspace-write", "materialized-folder"] do
        resolved =
          Policy.resolve(
            policy,
            out,
            %{profile: "light_work", cost_class: :standard, permission: permission},
            both,
            @now
          )

        assert match?({:ok, _}, resolved) == available?.(out, permission)
      end

      # Not permitted, unknown, or no policy: never available.
      refute Policy.available?(policy, out, "light_work", "dedicated-repository", both, @now)
      refute Policy.available?(policy, out, "light_wrok", "read-only", both, @now)
      refute Policy.available?({:error, :missing}, out, "light_work", "read-only", both, @now)
    end

    test "a profile no option of which can serve any permission it permits is not offered",
         %{tmp_dir: dir} do
      write_only = put_in(@light, ["profiles", "light_work", "permissions"], ["workspace-write"])
      policy = loaded(dir, write_only)

      out = codex_out(Availability.empty())

      assert Policy.profiles(policy, out, ["claude", "codex"], @now)["light_work"].available ==
               false
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

    # s5a-plan B17 (P10a): exactly two additions per profile.
    test "after_check: allow_after_check and limits.max_check_timeout, strictly", %{tmp_dir: dir} do
      for {value, ok?} <- [
            {%{"allow_after_check" => false}, true},
            {%{"allow_after_check" => true}, true},
            {%{"allow_after_check" => "no"}, false},
            {%{"limits" => %{"max_check_timeout" => 60}}, true},
            {%{"limits" => %{"max_duration" => 600, "max_check_timeout" => 60}}, true},
            {%{"limits" => %{"max_check_timeout" => 0}}, false},
            {%{"limits" => %{"max_check_timeout" => "60"}}, false},
            {%{"limits" => %{}}, false},
            {%{"limits" => %{"check_timeout" => 60}}, false}
          ] do
        policy = update_in(@mini, ["profiles", "deep_coding"], &Map.merge(&1, value))
        write_policy(dir, policy)

        if ok? do
          assert {:ok, ^policy} = Policy.load(dir), inspect(value)
        else
          assert {:error, {:invalid, message}} = Policy.load(dir), inspect(value)
          assert message =~ ~s("deep_coding": ), inspect({value, message})
        end
      end

      policy =
        update_in(@mini, ["profiles", "deep_coding"], fn profile ->
          profile
          |> Map.put("allow_after_check", false)
          |> Map.put("limits", %{"max_duration" => 7_200, "max_check_timeout" => 60})
        end)

      loaded = loaded(dir, policy)

      assert Policy.after_check(loaded, "deep_coding") ==
               %{allowed: false, max_timeout: 60, default_timeout: 60}

      assert Policy.after_check(loaded, "independent_review") ==
               %{allowed: true, max_timeout: 600, default_timeout: 120}

      assert Policy.after_check({:error, :missing}, "x") ==
               %{allowed: true, max_timeout: 600, default_timeout: 120}

      # max_duration is read as before when max_check_timeout sits beside it.
      assert Policy.limits(loaded, "deep_coding").max_duration == 7_200
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

  describe "sources (decision §5.5)" do
    # The decision's example, with a concrete host for its elided url.
    @local %{
      "name" => "local",
      "kind" => "builtin",
      "priority" => 1,
      "max_slots" => 6,
      "max_store_bytes" => 2_147_483_648
    }
    @flow %{
      "name" => "flow-prod",
      "kind" => "remote",
      "url" => "https://flow.example.test/work-source",
      "credential_file" => "sources/flow-prod/token",
      "priority" => 2,
      "max_slots" => 4,
      "max_store_bytes" => 2_147_483_648
    }

    defp with_sources(sources), do: Map.put(@mini, "sources", sources)

    # Each policy is the valid example with one change; it must refuse the whole policy,
    # so nothing is permitted (as for every other key).
    defp assert_refused(dir, sources) do
      write_policy(dir, with_sources(sources))
      assert {:error, {:invalid, _}} = loaded = Policy.load(dir), inspect(sources)
      assert Policy.sources(loaded) == []

      assert {:refused, :policy_forbids, _} =
               Policy.resolve(loaded, Availability.empty(), request(), ["claude"], @now)
    end

    defp flow(changes), do: Map.merge(@flow, changes)

    test "the decision's example loads, in priority order", %{tmp_dir: dir} do
      policy = with_sources([@flow, @local])
      assert {:ok, ^policy} = loaded = loaded(dir, policy)
      assert Policy.sources(loaded) == [@local, @flow]

      lower_first = with_sources([flow(%{"priority" => 0}), @local])
      assert Policy.sources(loaded(dir, lower_first)) == [flow(%{"priority" => 0}), @local]

      # Remote sources alone, an empty list and zero slots are all valid.
      for sources <- [[@flow], [], [Map.put(@local, "max_slots", 0)]],
          do: assert({:ok, _} = loaded(dir, with_sources(sources)), inspect(sources))
    end

    # Main's A6 Q2: no `sources` is `local` alone, at priority 1, with every slot; Flow's
    # source (or any remote one) is pulled only when the policy names it.
    test "sources absent gives local alone, priority 1, every slot", %{tmp_dir: dir} do
      assert [%{"name" => "local", "kind" => "builtin", "priority" => 1} = local] =
               Policy.sources(loaded = loaded(dir))

      assert local["max_slots"] == length(Policy.slots(loaded))
      assert local["max_slots"] > 0

      three = Map.put(@mini, "slots", ["a", "b", "c"])
      assert [%{"name" => "local", "max_slots" => 3}] = Policy.sources(loaded(dir, three))

      # Named sources are taken as written; an explicit empty list names none.
      assert Policy.sources(loaded(dir, with_sources([@flow]))) == [@flow]
      assert Policy.sources(loaded(dir, with_sources([]))) == []
      assert Policy.sources({:error, :missing}) == []
      assert Policy.sources({:error, {:invalid, "x"}}) == []
    end

    test "the policy view is unchanged by sources", %{tmp_dir: dir} do
      without = Policy.view(loaded(dir), Availability.empty(), ["claude", "codex"], @now)
      sourced = loaded(dir, with_sources([@local, @flow]))
      assert Policy.view(sourced, Availability.empty(), ["claude", "codex"], @now) == without
    end

    test "refuses a plaintext source url", %{tmp_dir: dir} do
      for url <- [
            "http://flow.example.test/work-source",
            "HTTP://flow.example.test",
            "//flow.example.test",
            "flow.example.test",
            "ftp://flow.example.test",
            "https://",
            "https:/flow.example.test",
            "https://user:secret@flow.example.test/work-source",
            "https://user@flow.example.test/work-source",
            "https://flow.example.test /work-source",
            "https://flow.example.test/work source",
            "https://flow.example.test/work-source\n",
            "https://flow.example.test/work-source?token=x",
            "https://flow.example.test/work-source#x",
            "",
            nil
          ],
          do: assert_refused(dir, [@local, flow(%{"url" => url})])
    end

    # Paths a source's file (credential_file, ca_file) may not have: outside its own
    # directory, escaping it, absolute, empty, with a control character, or not a string.
    @outside_paths [
      "../x",
      "/etc/token",
      "/sources/flow-prod/token",
      "sources/flow-prod/../other/token",
      "sources/flow-prod/../../token",
      "sources/../flow-prod/token",
      "./sources/flow-prod/token",
      "sources/flow-prod/./token",
      "sources//flow-prod/token",
      "sources/flow-prod//token",
      "sources/other/token",
      "sources/flow-prod",
      "sources/flow-prod/",
      "token",
      "sources/flow-prod/tok\0en",
      "sources/flow-prod/tok\nen",
      "sources/flow-prod/tok\ten",
      "sources/flow-prod/tok\x7Fen",
      "",
      nil
    ]

    test "credential file stays under sources/<name>/", %{tmp_dir: dir} do
      for path <- @outside_paths,
          do: assert_refused(dir, [@local, flow(%{"credential_file" => path})])

      # A deeper file in its own directory is fine.
      assert {:ok, _} =
               loaded(
                 dir,
                 with_sources([flow(%{"credential_file" => "sources/flow-prod/a/token"})])
               )
    end

    # pull-e2e D5: a remote source may trust its own CA file (a test source); the same path
    # rule as its credential applies, and the builtin source has none.
    test "a remote source may name a ca_file under sources/<name>/", %{tmp_dir: dir} do
      with_ca = flow(%{"ca_file" => "sources/flow-prod/ca.pem"})
      policy = with_sources([@local, with_ca])
      assert {:ok, ^policy} = loaded = loaded(dir, policy)
      assert Policy.sources(loaded) == [@local, with_ca]

      deeper = flow(%{"ca_file" => "sources/flow-prod/tls/ca.pem"})
      assert {:ok, _} = loaded(dir, with_sources([deeper]))

      for path <- @outside_paths ++ ["/etc/ssl/cert.pem", "sources/other/ca.pem", 7, %{}],
          do: assert_refused(dir, [@local, flow(%{"ca_file" => path})])

      # Never on the builtin source, and an unknown key stays refused next to it.
      assert_refused(dir, [Map.put(@local, "ca_file", "sources/local/ca.pem"), @flow])
      assert_refused(dir, [@local, Map.put(with_ca, "weight", 1)])
    end

    test "priorities are unique", %{tmp_dir: dir} do
      assert_refused(dir, [@local, flow(%{"priority" => 1})])
      other = flow(%{"name" => "flow-test", "credential_file" => "sources/flow-test/token"})
      assert_refused(dir, [@flow, Map.put(other, "priority", 2)])
    end

    test "names are unique", %{tmp_dir: dir} do
      assert_refused(dir, [@flow, flow(%{"priority" => 3})])
      assert_refused(dir, [@local, Map.put(@local, "priority", 3)])
    end

    test "only local is builtin", %{tmp_dir: dir} do
      assert_refused(dir, [Map.put(@local, "name", "flow-prod")])
      assert_refused(dir, [Map.put(@local, "name", "other"), @flow])
      # Nor is local ever remote: its client holds the local socket's rights.
      local_remote = flow(%{"name" => "local", "credential_file" => "sources/local/token"})
      assert_refused(dir, [local_remote])
    end

    test "each kind has exactly its fields", %{tmp_dir: dir} do
      for sources <- [
            [Map.put(@local, "url", @flow["url"])],
            [Map.put(@local, "credential_file", "sources/local/token")],
            [Map.delete(@flow, "url")],
            [Map.delete(@flow, "credential_file")],
            [Map.put(@flow, "weight", 1)],
            [Map.put(@local, "kind", "other")],
            [Map.delete(@local, "kind")],
            [Map.delete(@flow, "name")]
          ],
          do: assert_refused(dir, sources)

      for key <- ~w(priority max_slots max_store_bytes),
          source <- [@local, @flow],
          do: assert_refused(dir, [Map.delete(source, key)])
    end

    test "names, priorities, slots and store quotas are checked", %{tmp_dir: dir} do
      for name <- ["", "..", "Flow", "flow/prod", "-flow", "flow prod", 7, nil] do
        credential = if is_binary(name), do: "sources/#{name}/token", else: "sources/x/token"
        assert_refused(dir, [flow(%{"name" => name, "credential_file" => credential})])
      end

      # A JSON object or array as name refuses the policy too, for either kind; it must
      # never reach a check that turns it into text and raises instead.
      for name <- [%{}, [%{}], [-1], ["flow-prod"], [], %{"a" => 1}] do
        assert_refused(dir, [flow(%{"name" => name})])
        assert_refused(dir, [Map.put(@local, "name", name)])
      end

      for value <- [1.5, "1", nil], do: assert_refused(dir, [flow(%{"priority" => value})])
      for value <- [-1, 1.0, "4", nil], do: assert_refused(dir, [flow(%{"max_slots" => value})])

      for value <- [0, -1, 1.0, "1", nil],
          do: assert_refused(dir, [flow(%{"max_store_bytes" => value})])
    end

    test "sources must be a list of entries", %{tmp_dir: dir} do
      for sources <- [%{"local" => @local}, "local", nil, [nil], ["local"], [[@local]]] do
        write_policy(dir, with_sources(sources))
        assert {:error, {:invalid, _}} = Policy.load(dir), inspect(sources)
      end
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

  test "runtime.sock refuses preferences; the Service's view cannot write policy or availability",
       context do
    File.write!(Policy.path(context.dir), JSON.encode!(@policy))
    File.write!(Path.join(context.dir, "backends.json"), JSON.encode!(%{"claude_quota" => nil}))
    service = launch(context.dir)
    policy = File.read!(Policy.path(context.dir))
    availability = File.read!(Availability.path(context.dir))
    # The operations contract serves the policy view on backend.sock (S2).
    assert send_line(context.dir, %{"command" => "preferences"})["command_error"] =~
             "backend.sock (GET /v1/policy"

    # In-process, as the Service still answers it, with the reply as JSON.
    served = fn request -> service |> call(request) |> JSON.encode!() |> JSON.decode!() end
    view = served.(%{"command" => "preferences"})
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
      assert served.(write)["command_error"] =~ "only reads"
    end

    assert File.read!(Policy.path(context.dir)) == policy
    assert File.read!(Availability.path(context.dir)) == availability
    File.rm!(Policy.path(context.dir))
    assert served.(%{"command" => "preferences"})["policy_error"] == "missing"
  end

  test "a start with neither profile nor backend follows the imported preference pair",
       context do
    # An in-BEAM caller of the Service may omit both: BackendPolicy's preferred/fallback
    # choice still applies.
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
