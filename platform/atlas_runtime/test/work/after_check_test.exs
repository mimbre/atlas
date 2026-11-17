defmodule AtlasRuntime.Work.AfterCheckTest do
  @moduledoc """
  S5a P10a (design §3.10; s5a-plan B16–B18, B23, B24, B28; I-H3 as amended 2026-11-17):
  `after_check` runs once the agent completed, after the frozen result is persisted, through
  `host check` with the turn's own sandbox, and is recorded in the `completed` write; it fails
  closed at submit (no `codex`) and at check time (`codex` gone).

  This tree has no `atlas-runtime host check` yet (P6, #270, is not in this base), so the core
  runs the stand-in `fake-native hostcheck` (test/support/fake_native), which implements
  I-H3's lines and the amendment's three deviations (`check-fault`) and calls the fake
  `codex sandbox` passthrough the work bench puts on `PATH`. Both log their argv to the home:
  `check-launches.jsonl` (the helper) and `check-sandbox.jsonl` (`codex sandbox`).
  """
  use ExUnit.Case, async: false

  import AtlasRuntime.WorkHarness
  import AtlasRuntime.CodeStandIn, only: [base_request: 4, expected_folder: 2, private_attempt: 3]

  alias AtlasRuntime.Boundary.Work, as: F
  alias AtlasRuntime.{CodeStandIn, FakeNative, TestHost}
  alias AtlasRuntime.Work.{Check, Folders, FrozenStore, Queue, Store, Translation}

  @moduletag capture_log: true

  @check_script """
  #!/bin/sh
  echo "check ran"
  echo checked > atlas/check-out.txt
  exit "${1:-0}"
  """
  @files %{"README.md" => "base\n", "check.sh" => @check_script}
  @socket {"c1", [:submit, :cancel, :read, :choose_path]}
  # The same owner without choose_path: WorkHarness.client/0 holds it since S3 (D44).
  @reader {"c1", [:submit, :cancel, :read]}
  # A safety bound on the core's `completed` write, under ExUnit's 60 s test timeout. It
  # bounds a wait for that event and is no poll budget: a healthy run never comes near it.
  @completed_write_ms 50_000

  ## The bench

  defp bench!(policy \\ %{}, options \\ []) do
    test = self()

    options =
      Keyword.merge(
        [
          check_helper: {FakeNative.path(), ["hostcheck"]},
          after_write: fn record ->
            send(test, {:written, record})
            # The event check!/2 awaits: a write whose current attempt is completed (I2: that
            # write carries the check).
            if Queue.current(record).state == :completed,
              do: send(test, {:completed_write, record.work_id})
          end
        ],
        options
      )

    bench = start!(policy, options)
    code = CodeStandIn.start!(bench.dir, @files)

    # Before the bench's own teardown removes the home: the core is stopped (a running
    # check's helper then loses its stdin and stops its group), and each helper it started
    # has ended, so nothing writes into the home while it is removed.
    on_exit(fn ->
      stop_work()
      settled = fn -> length(jsonl(bench, "check-ends.jsonl")) >= length(checks(bench)) end
      Enum.find(1..250, fn _ -> settled.() || (Process.sleep(20) && false) end)
      CodeStandIn.stop(code, bench.dir)
    end)

    {bench, code}
  end

  defp submit_check!(code, goal, check, permissions \\ "workspace-write", client \\ client()) do
    assert %F.Outcome.Accepted{work: work} =
             F.submit(client, base_request(code, goal, permissions, %{after_check: check}))

    work
  end

  defp jsonl(bench, name) do
    case File.read(Path.join(bench.dir, name)) do
      {:ok, bytes} -> bytes |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
      {:error, :enoent} -> []
    end
  end

  defp checks(bench), do: jsonl(bench, "check-launches.jsonl")

  # The core's own `completed` write is the event, not a time-bounded poll of the boundary
  # (WorkHarness.await/2's 10 s budget expired on a loaded CI runner, #332). It arrives
  # whether it was written before or after this call. The work is then read once, as
  # before: by the time the core answers get_work it has finished the commit that sent it.
  defp check!(work_id, client \\ client()) do
    receive do
      {:completed_write, ^work_id} -> :ok
    after
      @completed_write_ms ->
        flunk("no completed write for #{work_id}; the work is #{inspect(work!(work_id, client))}")
    end

    [attempt | _] = Enum.reverse(work!(work_id, client).attempts)
    assert attempt.state == :completed
    attempt.result.work_product.check
  end

  # The records the core wrote for `work_id` so far, in the order it wrote them.
  defp written(work_id) do
    receive do
      {:written, %{work_id: ^work_id} = record} -> [record | written(work_id)]
      {:written, _other} -> written(work_id)
    after
      0 -> []
    end
  end

  defp store_files(dir), do: Path.wildcard(Path.join([dir, "work", "**"])) |> Enum.sort()

  # The turn's leader, or the check's group: alive while `kill -0` finds either.
  def group_probe(pid, _launched) do
    alive? = fn target ->
      match?({_, 0}, System.cmd("/bin/kill", ["-0", "--", target], stderr_to_stdout: true))
    end

    if alive?.(Integer.to_string(pid)) or alive?.("-#{pid}"),
      do: :alive,
      else: {:gone, "kill -0 found no process or group #{pid}"}
  end

  defp codex_off(bench) do
    bin = Path.join(bench.dir, "bin")
    File.rename!(Path.join(bin, "codex"), Path.join(bin, "codex.off"))
    on_exit(fn -> File.rename(Path.join(bin, "codex.off"), Path.join(bin, "codex")) end)
    refute Check.available?()
  end

  defp codex_on(bench) do
    bin = Path.join(bench.dir, "bin")
    File.rename!(Path.join(bin, "codex.off"), Path.join(bin, "codex"))
    assert Check.available?()
  end

  ## Running and recording

  test "a passing and a failing command both leave the attempt completed, with exit_status 0 and 3 and no error" do
    {_bench, code} = bench!()
    pass = submit_check!(code, "write atlas/a.txt pass", %{command: ["sh", "atlas/check.sh"]})

    fail =
      submit_check!(code, "write atlas/b.txt fail", %{command: ["sh", "atlas/check.sh", "3"]})

    for {work, status} <- [{pass, 0}, {fail, 3}] do
      assert %F.CheckResult{
               command: ["sh", "atlas/check.sh" | _],
               exit_status: ^status,
               signal: nil,
               error: nil,
               timed_out: false,
               cancelled: false,
               interrupted: false,
               output: %F.CheckOutput{tail: "check ran\n", complete: true}
             } = check!(work.work_id)

      [attempt] = work!(work.work_id).attempts
      assert attempt.state == :completed and attempt.result.kind == :completed
      assert attempt.result.work_product.frozen
    end
  end

  test "a sleeping command with timeout 1 times out: timed_out, exit_status nil, a signal, still completed" do
    {_bench, code} = bench!()
    work = submit_check!(code, "complete then sleep", %{command: ["sleep", "30"], timeout: 1})

    assert %F.CheckResult{timed_out: true, exit_status: nil, signal: "SIGINT", error: nil} =
             check = check!(work.work_id)

    assert check.duration_ms >= 900 and check.duration_ms < 10_000
    assert [%{state: :completed, result: %{kind: :completed}}] = work!(work.work_id).attempts
  end

  test "the check runs after the frozen result is persisted: its files are absent from it, and nothing says completed before the check is recorded (I2)",
       %{} do
    {bench, code} = bench!()
    work = submit_check!(code, "write atlas/a.txt agent", %{command: ["sh", "atlas/check.sh"]})
    check!(work.work_id)
    records = written(work.work_id)
    attempt = fn record -> hd(record.attempts) end

    # The checking commit: the agent's result and its frozen result, still running.
    [checking | _] = Enum.filter(records, &(attempt.(&1).checking == true))
    assert attempt.(checking).state == :running
    assert attempt.(checking).timestamps.check_started_at
    assert %{frozen: frozen, check: nil} = attempt.(checking).result.work_product

    # The first write that names completed already carries the check.
    [completed | _] = Enum.filter(records, &(attempt.(&1).state == :completed))
    assert %{check: %{exit_status: 0}, frozen: ^frozen} = attempt.(completed).result.work_product

    assert Enum.find_index(records, &(&1 == checking)) <
             Enum.find_index(records, &(&1 == completed))

    # The check wrote atlas/check-out.txt; the frozen result is the agent's alone.
    folder = expected_folder(bench.dir, work.work_id)
    assert File.read!(Path.join(folder, "atlas/check-out.txt")) == "checked\n"
    stored = FrozenStore.get(bench.dir, work.work_id, 1)
    assert [%{entries: entries}] = stored.roots
    assert Enum.map(entries, & &1.path) == ["a.txt"]
    assert attempt.(completed).result.work_product.frozen == frozen
  end

  test "while the check runs the attempt is running at the boundary, with no result" do
    {bench, code} = bench!()
    work = submit_check!(code, "complete before a slow check", %{command: ["sleep", "1"]})
    await(fn -> private_attempt(bench.dir, work.work_id, 1).checking == true end)

    assert [%F.Attempt{state: :running, result: nil, timestamps: timestamps}] =
             work!(work.work_id).attempts

    assert timestamps.check_started_at && is_nil(timestamps.check_ended_at)
    assert %F.CheckResult{exit_status: 0} = check!(work.work_id)
    refute private_attempt(bench.dir, work.work_id, 1).checking
  end

  test "check_started_at <= check_ended_at <= ended_at, and the tail is at most 16 KiB (complete false when longer)" do
    {_bench, code} = bench!()
    long = "i=0; while [ $i -lt 2000 ]; do echo 0123456789; i=$((i+1)); done; echo é-end"
    work = submit_check!(code, "complete with a long check", %{command: ["sh", "-c", long]})
    check = check!(work.work_id)
    [attempt] = work!(work.work_id).attempts
    t = attempt.timestamps
    assert DateTime.compare(t.running_at, t.check_started_at) != :gt
    assert DateTime.compare(t.check_started_at, t.check_ended_at) != :gt
    assert DateTime.compare(t.check_ended_at, t.ended_at) != :gt
    assert byte_size(check.output.tail) <= 16_384 and byte_size(check.output.tail) > 16_000
    assert String.valid?(check.output.tail) and String.ends_with?(check.output.tail, "é-end\n")
    refute check.output.complete
  end

  test "the helper runs in the work folder with the turn's sandbox, --scratch <home>/scratch/check-<work_id>.<n>, the timeout and a 16 KiB tail; the scratch is gone after" do
    {bench, code} = bench!()
    write = submit_check!(code, "write atlas/w.txt w", %{command: ["true"], timeout: 7})
    read = submit_check!(code, "complete read-only", %{command: ["true"]}, "read-only")
    check!(write.work_id)
    check!(read.work_id)
    home = Folders.real(bench.dir)

    for {work, timeout, sandbox} <- [{write, "7", "--scope"}, {read, "120", "--sandbox"}] do
      scratch = Path.join([home, "scratch", "check-#{work.work_id}.1"])

      [%{"argv" => argv}] =
        Enum.filter(
          checks(bench),
          &(Enum.at(&1["argv"], 1) == expected_folder(bench.dir, work.work_id))
        )

      assert ["--cwd", _folder, ^sandbox, value, "--scratch", ^scratch | rest] = argv
      assert rest == ["--timeout", timeout, "--grace", "1", "--tail", "16384", "--", "true"]

      if sandbox == "--scope" do
        # The turn's own scope, as the Service recorded it in turn.json.
        [attempt] = work!(work.work_id).attempts
        assert JSON.decode!(value) == turn(bench, attempt.turn_id)["permissions"]
        assert JSON.decode!(value)["profile"] == "materialized-folder"
      else
        assert value == "read-only"
      end

      refute File.exists?(scratch)
    end
  end

  test "one codex: the one Check.available?/0 finds is the one the helper runs, on the core's PATH" do
    {bench, code} = bench!()
    work = submit_check!(code, "complete for one codex", %{command: ["true"]})
    check!(work.work_id)
    assert [%{"path" => path, "runtime_home" => home}] = checks(bench)
    assert path == System.get_env("PATH") and home == bench.dir

    assert [%{"codex" => codex, "argv" => ["sandbox", "-P", "atlas_folder", "-C", _ | _]}] =
             jsonl(bench, "check-sandbox.jsonl")

    assert codex == Check.codex() and Path.type(codex) == :absolute
  end

  @tag skip: TestHost.missing(:home_private_temp)
  test "a Codex-run and a Claude-run work run the check through the same host check argv shape" do
    profiles = %{
      "light_work" => %{
        "permissions" => ["read-only", "workspace-write", "materialized-folder"],
        "cost_classes" => ["low", "standard"],
        "options" => [%{"provider" => "openai", "harness" => "codex", "model" => "gpt-test"}]
      },
      "claude_work" => %{
        "permissions" => ["read-only"],
        "cost_classes" => ["low", "standard"],
        "options" => [%{"provider" => "anthropic", "harness" => "claude", "model" => "claude-t"}]
      }
    }

    {bench, code} = bench!(%{"profiles" => profiles})
    codex = submit_check!(code, "complete with codex", %{command: ["true"]}, "read-only")

    request =
      base_request(code, "complete with claude", "read-only", %{
        after_check: %{command: ["true"]},
        profile: "claude_work"
      })

    assert %F.Outcome.Accepted{work: claude} = F.submit(client(), request)
    check!(codex.work_id)
    check!(claude.work_id)

    shapes =
      for %{"argv" => argv} <- checks(bench) do
        Enum.map(argv, fn arg -> if String.starts_with?(arg, "/"), do: "<path>", else: arg end)
      end

    assert [shape, shape] = shapes
    harnesses = Enum.map(launches(bench), & &1["backend"]) |> Enum.sort()
    assert harnesses == ["claude", "codex"]
  end

  test "the check is not counted in max_duration: it outlives it without time_limit" do
    profiles = %{
      "light_work" => %{
        "permissions" => ["read-only", "workspace-write", "materialized-folder"],
        "cost_classes" => ["low", "standard"],
        "options" => [%{"provider" => "openai", "harness" => "codex", "model" => "gpt-test"}],
        "limits" => %{"max_duration" => 1}
      }
    }

    {_bench, code} = bench!(%{"profiles" => profiles})

    work =
      submit_check!(code, "complete before the deadline", %{command: ["sleep", "2"], timeout: 5})

    check = check!(work.work_id)
    assert check.exit_status == 0 and not check.timed_out and check.duration_ms >= 1_500
    [attempt] = work!(work.work_id).attempts
    assert attempt.result.kind == :completed and attempt.result.reason == nil
    assert attempt.cancel_reason == nil and attempt.cancel_stage == nil
    assert attempt.timestamps.cancel_requested_at == nil
  end

  test "failed and cancelled attempts run no check" do
    {bench, code} = bench!()
    failed = submit_check!(code, "fail", %{command: ["true"]})
    await_state(failed.work_id, :failed)
    hung = submit_check!(code, "hang", %{command: ["true"]})
    await_launch(bench, hung)

    assert %F.Outcome.Cancelling{} =
             F.cancel(client(), %{work_id: hung.work_id, mode: "graceful"})

    await_state(hung.work_id, :cancelled)
    Process.sleep(300)
    assert checks(bench) == []

    for work <- [failed, hung] do
      [attempt] = work!(work.work_id).attempts
      assert attempt.timestamps.check_started_at == nil
      refute attempt.result.work_product && attempt.result.work_product.check
    end
  end

  # P10a fix M1: a cancel asked for before the agent's result arrived, which the result wins
  # (§5 cancelling -> completed, cancel_stage requested). The cancel stops only the check
  # (§3.10, B20, D43), here before it starts: the attempt ends completed with
  # check.cancelled true and no error, and nothing is run.
  test "a cancel requested before a completing result: completed with check.cancelled true, no error, and no check run" do
    {bench, code} = bench!()
    gate = Path.join(bench.dir, "gate-cancel")
    File.write!(gate, "")
    work = submit_check!(code, "wait gate-cancel", %{command: ["sh", "check.sh"]})
    [%{turn_id: turn}] = await_launch(bench, work).attempts

    # The cancel reaches the core before it hears of the result: requested is written, and
    # the stop finds the turn already finished (as in CancelTest).
    core = GenServer.whereis(AtlasRuntime.Work.Server)
    :sys.suspend(core)
    cancel = Task.async(fn -> F.cancel(client(), %{work_id: work.work_id, mode: "graceful"}) end)

    await(fn ->
      match?({:message_queue_len, n} when n > 0, Process.info(core, :message_queue_len))
    end)

    File.rm!(gate)
    await(fn -> turn(bench, turn)["state"] == "finished" end)
    :sys.resume(core)

    assert %F.Outcome.Ended{work: %{state: :completed, attempts: [attempt]}} = Task.await(cancel)
    assert attempt.cancel_stage == :requested
    assert attempt.result.kind == :completed and attempt.result.answer == "done: wait gate-cancel"

    assert %F.CheckResult{
             command: ["sh", "check.sh"],
             cancelled: true,
             error: nil,
             exit_status: nil,
             signal: nil,
             timed_out: false,
             interrupted: false,
             duration_ms: 0,
             output: %F.CheckOutput{tail: "", complete: true}
           } = attempt.result.work_product.check

    Process.sleep(300)
    assert checks(bench) == [] and jsonl(bench, "check-sandbox.jsonl") == []

    [stored] = Store.read_work(bench.dir, work.work_id).attempts
    assert stored.state == :completed and stored.quiescent and stored.checking != true
    times = stored.timestamps
    assert times.check_started_at != nil

    assert times.check_started_at == times.check_ended_at and
             times.check_ended_at == times.ended_at

    # Only one write says completed, and it carries the check (I2); none is checking.
    records = written(work.work_id)
    refute Enum.any?(records, fn r -> Enum.any?(r.attempts, & &1.checking) end)

    assert [%{attempts: [%{result: %{work_product: %{check: %{cancelled: true}}}}]}] =
             Enum.filter(records, fn r -> hd(r.attempts).state == :completed end)
  end

  # F7 (B29, design §3.10 "a later resume continues the physical folder"): check files included.
  test "a retry resume: true continues in the folder with the check's files, and its frozen result holds them" do
    {bench, code} = bench!()
    work = submit_check!(code, "write atlas/a.txt one", %{command: ["sh", "atlas/check.sh"]})
    check!(work.work_id)
    folder = expected_folder(bench.dir, work.work_id)
    assert File.exists?(Path.join(folder, "atlas/check-out.txt"))

    assert %F.Outcome.Accepted{} = F.retry(client(), %{work_id: work.work_id, resume: true})
    await_work(work.work_id, &(length(&1.attempts) == 2 and &1.state == :completed))
    assert [_, %{"resumed" => true, "cwd" => cwd}] = launches(bench)
    assert Folders.real(cwd) == folder

    paths =
      for %{entries: entries} <- FrozenStore.get(bench.dir, work.work_id, 2).roots,
          entry <- entries,
          do: entry.path

    assert "check-out.txt" in paths and "a.txt" in paths
  end

  ## Refusals at submit (B16, B17)

  test "submit refusals: argv rules and the timeout cap are invalid, a profile without after_check is policy_forbids, another workspace is unsupported_workspace; nothing is written" do
    profiles = %{
      "light_work" => %{
        "permissions" => ["read-only", "workspace-write", "materialized-folder"],
        "cost_classes" => ["low", "standard"],
        "options" => [%{"provider" => "openai", "harness" => "codex", "model" => "gpt-test"}],
        "limits" => %{"max_check_timeout" => 30}
      },
      "strict" => %{
        "permissions" => ["read-only", "workspace-write"],
        "cost_classes" => ["low", "standard"],
        "options" => [%{"provider" => "openai", "harness" => "codex", "model" => "gpt-test"}],
        "allow_after_check" => false
      }
    }

    {bench, code} = bench!(%{"profiles" => profiles})
    before = store_files(bench.dir)

    for {check, reason} <- [
          {%{command: ["/bin/sh", "x"]}, :invalid},
          {%{command: ["../escape.sh"]}, :invalid},
          {%{command: ["atlas/../../escape.sh"]}, :invalid},
          {%{command: []}, :invalid},
          {%{command: [""]}, :invalid},
          {%{command: ["sh", "a" <> <<0>> <> "b"]}, :invalid},
          {%{command: List.duplicate("x", 65)}, :invalid},
          {%{command: ["sh", String.duplicate("x", 4097)]}, :invalid},
          {%{command: ["true"], timeout: 31}, :invalid},
          {%{command: ["true"], timeout: 0}, :invalid}
        ] do
      assert %F.Outcome.Refused{reason: ^reason} =
               F.submit(
                 @socket,
                 base_request(code, "refused", "workspace-write", %{after_check: check})
               ),
             inspect(check)
    end

    strict = base_request(code, "strict", "workspace-write", %{after_check: %{command: ["true"]}})

    assert %F.Outcome.Refused{
             reason: :policy_forbids,
             detail: "after_check not allowed by profile"
           } =
             F.submit(@socket, %{strict | profile: "strict"})

    folder = request(bench, "a folder", %{after_check: %{command: ["true"]}})

    assert %F.Outcome.Refused{reason: :unsupported_workspace} = F.submit(@socket, folder)

    repository = %{
      folder
      | workspace: %{
          kind: "repository",
          url: "https://github.com/x/y",
          branch: "b",
          base: "develop"
        }
    }

    assert %F.Outcome.Refused{reason: :unsupported_workspace} = F.submit(@socket, repository)

    assert store_files(bench.dir) == before

    # At the cap it is accepted.
    assert %F.Outcome.Accepted{work: capped} =
             F.submit(
               @socket,
               base_request(code, "complete at the cap", "workspace-write", %{
                 after_check: %{command: ["true"], timeout: 30}
               })
             )

    assert %F.CheckResult{exit_status: 0} = check!(capped.work_id, @socket)
  end

  test "fail closed at submit: without codex an after_check is policy_forbids after_check_unavailable, without one accepted; codex back, accepted again (no cache)" do
    profiles = %{
      "light_work" => %{
        "permissions" => ["read-only", "workspace-write", "materialized-folder"],
        "cost_classes" => ["low", "standard"],
        "options" => [
          %{"provider" => "openai", "harness" => "codex", "model" => "gpt-test"},
          %{"provider" => "anthropic", "harness" => "claude", "model" => "claude-t"}
        ]
      }
    }

    {bench, code} = bench!(%{"profiles" => profiles})
    codex_off(bench)
    before = store_files(bench.dir)

    with_check =
      base_request(code, "hang with a check", "read-only", %{after_check: %{command: ["true"]}})

    assert %F.Outcome.Refused{reason: :policy_forbids, detail: "after_check_unavailable"} =
             F.submit(@socket, with_check)

    assert store_files(bench.dir) == before
    assert checks(bench) == []

    assert %F.Outcome.Accepted{work: plain} =
             F.submit(@socket, %{with_check | after_check: nil, instructions: "hang without"})

    codex_on(bench)
    assert %F.Outcome.Accepted{} = F.submit(@socket, with_check)
    F.cancel(@socket, %{work_id: plain.work_id, mode: "force"})
  end

  test "codex gone at check time: completed with check.error sandbox_unavailable and the B28 defaults; nothing is started" do
    {bench, code} = bench!()
    gate = Path.join(bench.dir, "gate-p10a")
    File.write!(gate, "")
    work = submit_check!(code, "wait gate-p10a", %{command: ["true"]})
    await_launch(bench, work)
    codex_off(bench)
    File.rm!(gate)

    assert %F.CheckResult{
             command: ["true"],
             error: :sandbox_unavailable,
             exit_status: nil,
             signal: nil,
             timed_out: false,
             cancelled: false,
             interrupted: false,
             duration_ms: 0,
             output: %F.CheckOutput{tail: "", complete: true}
           } = check!(work.work_id)

    assert checks(bench) == []
    assert [%{state: :completed, quiescent: true}] = work!(work.work_id).attempts
  end

  test "helper refusals complete with check.error: leaves_folder (a symlink out of the folder) and not_found (an unknown name)" do
    # Planted once the frozen result is written: a symlink out of a root is no change a freeze
    # accepts (P5 `unsupported_entry`), so the agent cannot leave it there itself.
    plant = fn frozen ->
      link = Path.join(Folders.path(frozen_home(), frozen.work_id), "atlas/esc")
      File.ln_s("/bin/sh", link)
    end

    {bench, code} = bench!(%{}, freeze_hook: fn frozen -> plant.(frozen) end)
    :persistent_term.put({__MODULE__, :home}, bench.dir)
    leaves = submit_check!(code, "complete then leave", %{command: ["atlas/esc", "-c", "true"]})
    unknown = submit_check!(code, "complete then unknown", %{command: ["no-such-tool-p10a"]})

    for {work, error} <- [{leaves, :leaves_folder}, {unknown, :not_found}] do
      assert %F.CheckResult{error: ^error, exit_status: nil, duration_ms: 0} =
               check!(work.work_id)

      assert [%{state: :completed, result: %{kind: :completed}}] = work!(work.work_id).attempts
    end

    assert length(checks(bench)) == 2
    assert jsonl(bench, "check-sandbox.jsonl") == []
  end

  defp frozen_home, do: :persistent_term.get({__MODULE__, :home})

  ## The amendment's deviations (I-H3 (a)-(c), coordinator 2026-11-17)

  test "exit 1 after started without ended: check.error helper_failed, exit_status nil, not quiescent until the probe finds the group gone" do
    {bench, code} = bench!(%{}, probe: &__MODULE__.group_probe/2)
    File.write!(Path.join(bench.dir, "check-fault"), "die_after_started")
    work = submit_check!(code, "complete then die", %{command: ["sleep", "2"]})

    assert %F.CheckResult{error: :helper_failed, exit_status: nil, signal: nil} =
             check!(work.work_id)

    [completed | _] =
      work.work_id |> written() |> Enum.filter(&(hd(&1.attempts).state == :completed))

    refute hd(completed.attempts).quiescent
    assert is_integer(pgid = hd(completed.attempts).check_pgid)
    assert [%{state: :completed, quiescent: false}] = work!(work.work_id).attempts
    # Several heartbeats later the group (the sleep) still lives, and so the attempt stays
    # not quiescent: the turn's end alone settles nothing.
    Process.sleep(500)
    assert group_probe(pgid, 0) == :alive
    assert [%{quiescent: false}] = work!(work.work_id).attempts
    # The sleep ends within 2 s; the probe then finds its group gone.
    assert await_work(work.work_id, &hd(&1.attempts).quiescent)
  end

  test "ended with group_gone false: not quiescent until the probe finds the group gone" do
    {bench, code} = bench!(%{}, probe: &__MODULE__.group_probe/2)
    File.write!(Path.join(bench.dir, "check-fault"), "group_kept")
    work = submit_check!(code, "complete group kept", %{command: ["true"]})
    assert %F.CheckResult{exit_status: 0, error: nil} = check!(work.work_id)

    [completed | _] =
      work.work_id |> written() |> Enum.filter(&(hd(&1.attempts).state == :completed))

    refute hd(completed.attempts).quiescent
    assert await_work(work.work_id, &hd(&1.attempts).quiescent)
  end

  test "a setup error before started: check.error helper_failed, quiescent (nothing ran)" do
    {bench, code} = bench!()
    File.write!(Path.join(bench.dir, "check-fault"), "setup_error")
    work = submit_check!(code, "complete setup error", %{command: ["true"]})
    assert %F.CheckResult{error: :helper_failed, exit_status: nil} = check!(work.work_id)
    assert [%{quiescent: true}] = work!(work.work_id).attempts
    assert jsonl(bench, "check-sandbox.jsonl") == []
  end

  ## The tail and D44 (designer decision 2026-11-17, (A))

  test "a check printing its folder and scratch shows . and <runtime-home> to a client without choose_path, and the real paths to a socket client" do
    {bench, code} = bench!()
    print = ~s(pwd -P; echo "$TMPDIR")

    request =
      base_request(code, "complete printing paths", "workspace-write", %{
        after_check: %{command: ["sh", "-c", print]},
        client_key: "paths-1"
      })

    assert %F.Outcome.Accepted{work: work} = F.submit(@socket, request)
    folder = expected_folder(bench.dir, work.work_id)
    scratch = Path.join([Folders.real(bench.dir), "scratch", "check-#{work.work_id}.1"])
    raw = check!(work.work_id, @socket)
    assert raw.output.tail == "#{folder}\n#{scratch}\n"
    redacted = ".\n<runtime-home>/scratch/check-#{work.work_id}.1\n"

    tail = fn %F.Work{attempts: [attempt]} -> attempt.result.work_product.check.output.tail end

    assert %F.Outcome.Found{work: seen} = F.get_work(@reader, %{work_id: work.work_id})
    assert tail.(seen) == redacted
    assert %F.Outcome.Found{work: seen} = F.find_work(@reader, %{client_key: "paths-1"})
    assert tail.(seen) == redacted
    assert %F.Outcome.Works{works: [seen]} = F.list_work(@reader, %{})
    assert tail.(seen) == redacted
    assert %F.Outcome.Existing{work: seen} = F.submit(@reader, request)
    assert tail.(seen) == redacted
    check = hd(seen.attempts).result.work_product.check
    assert %{check | output: raw.output} == raw

    # The socket client reads the raw tail; the store keeps it raw.
    assert %F.Outcome.Found{work: seen} = F.get_work(@socket, %{work_id: work.work_id})
    assert tail.(seen) == raw.output.tail
    assert %F.Outcome.Existing{work: seen} = F.submit(@socket, request)
    assert tail.(seen) == raw.output.tail

    stored = hd(Store.read_work(bench.dir, work.work_id).attempts)
    assert stored.result.work_product.check.output.tail == raw.output.tail
  end

  ## The projection's name (I-D44; P10a fix M2)

  # I-D44 (frozen) gives `from_model/2` to P2c as `from_model(record, rights)`, with no
  # default; P2c is on develop. The tail's redaction is its own function, which takes the
  # rights as well, also without a default (S5a chain port, round 2); `from_model/1` is gone.
  test "the projection keeps I-D44's from_model/2: the redacting one is from_model_redacting/3, with no default" do
    Code.ensure_loaded!(Translation)
    assert function_exported?(Translation, :from_model, 2)
    refute function_exported?(Translation, :from_model, 1)
    assert function_exported?(Translation, :from_model_redacting, 3)
    refute function_exported?(Translation, :from_model_redacting, 2)
  end
end
