Code.require_file("support.exs", __DIR__)

defmodule AtlasE2E.Pull.BenchTest do
  @moduledoc """
  The bench's guards (`AtlasE2E.Pull.Bench`, `AtlasE2E.Pull.Run`, `pull/run.sh`,
  `AtlasE2E.Pull.Await`, `AtlasE2E.Pull.Runtime.check_path/2`, `AtlasE2E.Pull.Reader`):

  - the reaper's proof finds what is left, never signals the bench's own process or group,
    takes no graceful step on the fast path, kills every recorded core, and signals nothing
    that is another process now (pid reuse);
  - a graceful step is bounded (a gate no agent waits at, a stop that hangs);
  - the wrapper TERMs the test BEAM before it reaps, and a leak makes it exit 5 on every path;
  - the watchdog fires, a step over its budget fails, nothing escapes the verdict;
  - commands and readers end with their owner, however it ends;
  - a negative check counts only polls begun after its mark; a real codex on PATH refuses
    the run.

  Injected process tables and recorders where the OS would decide otherwise; liveness FIFOs
  where a real process must be shown gone (no `ps`). `@tag :ps` for the live-table one.
  """
  use ExUnit.Case, async: true

  alias AtlasE2E.Pull.{Await, Bench, Hub, Reader, Run, Runtime}
  alias AtlasE2E.PullTest.Support

  @t1 "Wed Nov 18 10:00:00 2026"
  @t2 "Wed Nov 18 10:05:00 2026"
  @t0 "Wed Nov 18 09:55:00 2026"

  setup do
    run = Support.tmp!("bench")
    on_exit(fn -> File.rm_rf!(run) end)
    test = self()
    kill = fn target, sig -> send(test, {:kill, target, sig}) && true end
    %{run: run, kill: kill}
  end

  defp line(pid, pgid, lstart, command \\ "x", ppid \\ 1),
    do: %{pid: pid, ppid: ppid, pgid: pgid, stat: "S", lstart: lstart, command: command}

  defp quiet(table), do: [ps: fn -> table end, connect: fn _ -> true end]

  defp killed do
    receive do
      {:kill, target, sig} -> [{target, sig} | killed()]
    after
      0 -> []
    end
  end

  # ---- the reaper's guards ----------------------------------------------------------------

  test "reaping the bench's own pgid is refused", c do
    Bench.record(c.run, "runtime_group", %{pid: 4001, pgid: 4000, lstart: @t1, leader_lstart: @t1})

    Bench.record(c.run, "core", %{pid: 4100, pgid: 900, lstart: @t1, leader_lstart: @t1})
    table = [line(4000, 4000, @t1), line(4001, 4000, @t1), line(900, 900, @t1)]

    assert {:error, rows} =
             Bench.reap(c.run, [fast: true, own_pgid: 900, kill: c.kill] ++ quiet(table))

    sent = killed()
    assert {-4000, "KILL"} in sent
    refute Enum.any?(sent, &match?({-900, _}, &1))
    assert Enum.any?(rows, &(&1.stopped_by =~ "own_pgid"))
    assert Bench.kill_group(900, 900, c.kill) == {:error, :own_pgid}
  end

  test "the bench's own process is never signalled, also when the registry names its pid (F1)",
       c do
    me = Bench.me()
    Bench.record(c.run, "bench", %{bench_pid: me, own_pgid: 1})
    Bench.record(c.run, "bench", %{pid: me, lstart: @t1})
    table = [line(me, 1, @t1, "beam.smp -- mix atlas.pull_e2e --run #{c.run}")]

    assert {:ok, _} =
             Bench.reap(
               c.run,
               [fast: false, own_pgid: 1, kill: c.kill, cmd: fn _, _, _, _, _ -> {"", 0} end] ++
                 quiet(table)
             )

    refute Enum.any?(killed(), &match?({^me, _}, &1))
  end

  test "fast reap issues no service stop or atlas-ops stop; the graceful one does", c do
    Bench.record(c.run, "runtime_home", %{name: "rt", home: "/h", cli: "/bin/atlas-runtime"})
    Bench.record(c.run, "instance", %{file: "/i/test.json", root: "/root"})
    test = self()

    cmd = fn _what, command, args, _env, within ->
      send(test, {:cmd, Path.basename(command), args, within}) && {"", 0}
    end

    assert {:ok, _} =
             Bench.reap(c.run, [fast: true, own_pgid: 1, kill: c.kill, cmd: cmd] ++ quiet([]))

    refute_received {:cmd, _, _, _}

    assert {:ok, _} =
             Bench.reap(c.run, [fast: false, own_pgid: 1, kill: c.kill, cmd: cmd] ++ quiet([]))

    assert_received {:cmd, "atlas-runtime", ["service", "stop", "--force"], 60_000}
    assert_received {:cmd, "atlas-ops", ["stop", "--rela", "--env", "test"], 30_000}
  end

  @tag timeout: 30_000
  test "the graceful reap passes a gate no agent waits at, at once (F2)", c do
    stub = Support.stub!()
    gate = Path.join(c.run, "gate")
    {_, 0} = System.cmd("mkfifo", [gate])

    Bench.record(c.run, "stub", %{
      pid: 999_990,
      pgid: 999_990,
      gate: gate,
      bin: stub,
      lstart: @t1,
      leader_lstart: @t1
    })

    assert {:ok, rows} = Bench.reap(c.run, [fast: false, own_pgid: 1, kill: c.kill] ++ quiet([]))
    assert Enum.any?(rows, &(&1.stopped_by =~ "gate" and &1.stopped_by =~ "exit 3"))
  end

  @tag timeout: 30_000
  test "a graceful stop that hangs is KILLed at its budget (F2)", c do
    stub = Support.stub!()
    {fifo, watcher} = Support.liveness!(c.run)
    cli = Path.join(c.run, "hanging-cli")
    File.write!(cli, "#!/bin/sh\nexec 5>'#{fifo}'\necho up >&5\nexec '#{stub}' hold\n")
    File.chmod!(cli, 0o755)
    Bench.record(c.run, "runtime_home", %{name: "rt", home: c.run, cli: cli})

    reaper =
      Task.async(fn ->
        Bench.reap(c.run, [fast: false, own_pgid: 1, kill: c.kill] ++ quiet([]))
      end)

    assert_receive {^watcher, {:data, "up\n"}}
    # Its budget, run out now (`:pull_deadline`): the stop is KILLed and the reap goes on.
    send(reaper.pid, :pull_deadline)
    assert {:ok, rows} = Task.await(reaper)
    assert Enum.any?(rows, &(&1.stopped_by =~ "timed out"))
    assert_receive {^watcher, {:exit_status, 0}}
  end

  test "a process left in the run dir fails the reap and is killed", c do
    table = [line(999_991, 999_991, @t1, "#{c.run}/bin/pull-stub hold")]

    assert {:error, rows} =
             Bench.reap(c.run, [fast: true, own_pgid: 1, kill: c.kill] ++ quiet(table))

    assert {999_991, "KILL"} in killed()
    assert Enum.any?(rows, &(&1.pid == 999_991 and &1.gone == false))
  end

  test "a process in a recorded session whose command line lacks the run dir fails the reap", c do
    Bench.record(c.run, "core", %{
      pid: 5000,
      pgid: 5000,
      session: true,
      lstart: @t1,
      leader_lstart: @t1
    })

    table = [
      line(5000, 5000, @t1, "atlas-ops"),
      line(5003, 5000, @t2, "beam.smp -- mix run --no-halt")
    ]

    assert {:error, _} =
             Bench.reap(c.run, [fast: true, own_pgid: 1, kill: c.kill] ++ quiet(table))

    assert {5003, "KILL"} in killed()
  end

  test "a second recorded core pid is killed and proved gone", c do
    Bench.record(c.run, "core", %{pid: 6001, lstart: @t1})
    Bench.record(c.run, "core", %{pid: 6002, lstart: @t2})
    table = [line(6001, 6001, @t1), line(6002, 6002, @t2)]
    # The proof then reads a table without them (KILLed).
    {:ok, agent} = Agent.start_link(fn -> [table, []] end)

    ps = fn ->
      Agent.get_and_update(agent, fn [now | rest] ->
        {now, if(rest == [], do: [now], else: rest)}
      end)
    end

    assert {:ok, rows} =
             Bench.reap(c.run,
               fast: true,
               own_pgid: 1,
               kill: c.kill,
               ps: ps,
               connect: fn _ -> true end
             )

    sent = killed()
    assert {6001, "KILL"} in sent and {6002, "KILL"} in sent
    assert Enum.count(rows, &(&1.what == "core" and &1.gone == true)) == 2
  end

  test "a recorded pid or group that is another process now is never signalled (F6)", c do
    Bench.record(c.run, "core", %{pid: 6001, lstart: @t1})

    Bench.record(c.run, "runtime_group", %{pid: 7001, pgid: 7000, lstart: @t1, leader_lstart: @t1})

    # Both numbers were reused: the same pids, started later, by someone else.
    table = [
      line(6001, 6001, @t2, "someone's job"),
      line(7000, 7000, @t2, "someone's job"),
      line(7001, 7000, @t2, "theirs")
    ]

    assert {:ok, rows} =
             Bench.reap(c.run, [fast: true, own_pgid: 1, kill: c.kill] ++ quiet(table))

    assert killed() == []
    assert Enum.any?(rows, &(&1.stopped_by =~ "another process"))
  end

  test "a group whose leader ended loses only the members started after it (F6)", c do
    Bench.record(c.run, "core-restart", %{
      pid: 8000,
      pgid: 8000,
      session: true,
      lstart: @t1,
      leader_lstart: @t1
    })

    table = [
      line(8003, 8000, @t2, "beam.smp core"),
      line(8004, 8000, @t0, "older than the leader")
    ]

    {:ok, agent} = Agent.start_link(fn -> [table, []] end)

    ps = fn ->
      Agent.get_and_update(agent, fn [now | rest] ->
        {now, if(rest == [], do: [now], else: rest)}
      end)
    end

    assert {:ok, _} =
             Bench.reap(c.run,
               fast: true,
               own_pgid: 1,
               kill: c.kill,
               ps: ps,
               connect: fn _ -> true end
             )

    sent = killed()
    assert {8003, "KILL"} in sent
    refute {8004, "KILL"} in sent
    refute Enum.any?(sent, &match?({-8000, _}, &1))
  end

  test "a recorded pid still alive at the proof fails the reap", c do
    Bench.record(c.run, "stub", %{pid: 7101, pgid: 7100, lstart: @t1, leader_lstart: @t1})
    table = [line(7101, 7100, @t1), line(7100, 7100, @t1)]

    assert {:error, _} =
             Bench.reap(c.run, [fast: true, own_pgid: 1, kill: c.kill] ++ quiet(table))
  end

  test "a port that still accepts fails the reap", c do
    Bench.record(c.run, "listen", %{port: 4242, name: "control"})

    assert {:error, _} =
             Bench.reap(c.run,
               fast: true,
               own_pgid: 1,
               kill: c.kill,
               ps: fn -> [] end,
               connect: fn _ -> false end
             )
  end

  @tag :ps
  test "live: a stub left in the run dir is found by the proof and killed", c do
    stub = Path.join(c.run, "bin/pull-stub")
    File.mkdir_p!(Path.dirname(stub))
    File.cp!(Support.stub!(), stub)
    File.chmod!(stub, 0o755)
    port = Support.port!(stub, ["hold"])
    assert {:error, _} = Bench.reap(c.run, fast: true)
    assert_receive {^port, {:exit_status, _}}
  end

  # ---- bounded commands and steps (F5) -----------------------------------------------------

  test "a step over its budget fails, even when nothing in it waited" do
    {:ok, clock} = Agent.start_link(fn -> [0, 5_000] end)

    tick = fn ->
      Agent.get_and_update(clock, fn [t | rest] -> {t, if(rest == [], do: [t], else: rest)} end)
    end

    assert_raise Bench.OverBudget, fn -> Bench.within("slow", 2, fn -> :done end, clock: tick) end
    assert Bench.within("quick", 2, fn -> :done end) == :done
  end

  test "a bounded command is KILLed at its deadline, its group with it", c do
    stub = Support.stub!()
    {fifo, watcher} = Support.liveness!(c.run)

    owner =
      owner(fn ->
        Bench.bounded("/bin/sh", Support.holding(fifo, [stub, "hold"]),
          within: 600_000,
          stub: stub
        )
      end)

    assert_receive {^watcher, {:data, "up\n"}}
    # Its deadline, now (`:pull_deadline`), rather than a wait for time.
    send(owner, :pull_deadline)
    assert_receive {:result, {_, :timeout}}
    # Gone while its owner still runs (an owner's end would close the Port anyway).
    assert_receive {^watcher, {:exit_status, 0}}
    send(owner, :release)
  end

  # A process that runs `fun`, sends its result, and stays until released.
  defp owner(fun) do
    test = self()

    spawn_link(fn ->
      send(test, {:result, fun.()})

      receive do
        :release -> :ok
      end
    end)
  end

  test "a session is KILLed at its deadline", c do
    stub = Support.stub!()
    {fifo, watcher} = Support.liveness!(c.run)
    test = self()

    owner =
      owner(fn ->
        Bench.session(c.run, "probe", "/bin/sh", Support.holding(fifo, [stub, "hold"]),
          stub: stub,
          within: 600_000,
          on_deadline: :return,
          lstart: fn pid -> send(test, {:recorded, pid}) && nil end
        )
      end)

    assert_receive {^watcher, {:data, "up\n"}}
    assert_receive {:recorded, _}
    send(owner, :pull_deadline)
    assert_receive {:result, {_, :timeout}}
    assert_receive {^watcher, {:exit_status, 0}}
    send(owner, :release)
  end

  test "a session is recorded with its pgid before the command ends", c do
    stub = Support.stub!()
    {out, 0} = Bench.session(c.run, "probe", stub, ["ids"], stub: stub, lstart: fn _ -> nil end)
    ids = JSON.decode!(out)

    assert [%{"what" => "probe", "pid" => pid, "pgid" => pid, "session" => true}] =
             Bench.registry(c.run)

    assert ids["pid"] == pid and ids["pgid"] == pid
  end

  # ---- every exit path ends what was started (the orphan finding) ---------------------------

  test "a tethered command ends when its Port closes (the BEAM gone, however)", c do
    stub = Support.stub!()
    {fifo, watcher} = Support.liveness!(c.run)
    args = ["tether", "--", "/bin/sh" | Support.holding(fifo, ["/bin/cat"])]
    port = Port.open({:spawn_executable, stub}, [:binary, :exit_status, args: args])
    assert_receive {^watcher, {:data, "up\n"}}
    Port.close(port)
    assert_receive {^watcher, {:exit_status, 0}}
  end

  test "a session's command ends when its Port closes", c do
    stub = Support.stub!()
    {fifo, watcher} = Support.liveness!(c.run)
    args = ["session", "--", "/bin/sh" | Support.holding(fifo, [stub, "hold"])]
    port = Port.open({:spawn_executable, stub}, [:binary, :exit_status, args: args])
    assert_receive {^watcher, {:data, "up\n"}}
    Port.close(port)
    assert_receive {^watcher, {:exit_status, 0}}
  end

  test "a reader's command ends when its owner is killed, without a tether too", c do
    {fifo, watcher} = Support.liveness!(c.run)
    events = Path.join(c.run, "events.fifo")
    {_, 0} = System.cmd("mkfifo", [events])
    test = self()

    owner =
      spawn(fn ->
        {:ok, reader} =
          Reader.start_link(
            command: "/bin/sh",
            args: ["-c", ~s(exec 5>"$1"; echo up >&5; exec 3<>"$0"; exec cat <&3), events, fifo],
            source: :stub,
            name: "probe",
            hub: Support.hub!()
          )

        send(test, {:reader, reader})

        receive do
          :never -> :ok
        end
      end)

    assert_receive {:reader, reader}
    assert_receive {^watcher, {:data, "up\n"}}
    ref = Process.monitor(reader)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^reader, _}
    assert_receive {^watcher, {:exit_status, 0}}
  end

  @tag timeout: 120_000
  test "nothing a harness test starts outlives its test BEAM when that BEAM is killed (N1)", c do
    # A second test BEAM starts, through the same helpers the tests use, each kind of child
    # N1 found untethered: a reader blocked on a FIFO nobody writes, the wrapper with its
    # fake `mix` blocked, and a `pull-stub hold`. Each holds a liveness FIFO. That BEAM is
    # then SIGKILLed: every one of them must end (the watchers see the end of file).
    stub = Support.stub!()
    [{a1, w1}, {a2, w2}, {a3, w3}] = for _ <- 1..3, do: Support.liveness!(c.run)
    nobody = Path.join(c.run, "nobody.fifo")
    {_, 0} = System.cmd("mkfifo", [nobody])
    inner = Path.join(c.run, "inner")
    File.mkdir_p!(inner)
    script = Path.join(c.run, "inner.exs")

    File.write!(script, """
    [support, stub, a1, a2, a3, nobody, dir] = System.argv()
    Code.require_file(support)
    alias AtlasE2E.PullTest.Support
    Support.port!("/bin/sh", Support.holding(a1, ["/bin/cat", nobody]))
    Support.wrapper!(dir, 0, :hold, alive: a2, reader: false)
    Support.port!("/bin/sh", Support.holding(a3, [stub, "hold"]))
    IO.puts("pid " <> System.pid())

    receive do
      :never -> :ok
    end
    """)

    paths =
      Enum.flat_map(
        Path.wildcard(Path.join(Mix.Project.build_path(), "lib/*/ebin")),
        &["-pa", &1]
      )

    elixir =
      :code.lib_dir(:elixir) |> to_string() |> Path.join("../../bin/elixir") |> Path.expand()

    args = paths ++ [script, Path.expand("support.exs", __DIR__), stub, a1, a2, a3, nobody, inner]
    beam = Support.port!(elixir, args)

    for w <- [w1, w2, w3], do: assert_receive({^w, {:data, "up\n"}})
    pid = beam_pid(beam, "")
    assert Bench.signal(pid, "KILL")

    for w <- [w1, w2, w3], do: assert_receive({^w, {:exit_status, 0}})
  end

  defp beam_pid(port, acc) do
    case Regex.run(~r/pid (\d+)\n/, acc) do
      [_, pid] ->
        String.to_integer(pid)

      nil ->
        receive do
          {^port, {:data, data}} ->
            beam_pid(port, acc <> data)

          {^port, {:exit_status, status}} ->
            flunk("the inner test BEAM ended (#{status}): #{acc}")
        end
    end
  end

  # ---- the wrapper (B7, F4) -------------------------------------------------------------

  defp wrapper(c, reap_status, run_mode), do: Support.wrapper!(c.run, reap_status, run_mode)

  defp lines(w), do: File.read!(w.log) |> String.split("\n", trim: true)

  defp exit_status(port, acc \\ "") do
    receive do
      {^port, {:data, data}} -> exit_status(port, acc <> data)
      {^port, {:exit_status, status}} -> {status, acc}
    end
  end

  test "the wrapper TERMs the test BEAM before it reaps (signal path)", c do
    w = wrapper(c, 0, :hold)
    reader = w.reader
    assert_receive {^reader, {:data, "ready\n"}}
    {:os_pid, pid} = Port.info(w.port, :os_pid)
    assert Bench.signal(pid, "TERM")
    assert {143, _} = exit_status(w.port)
    assert lines(w) == ["prepare", "run", "beam-term", "reap"]
  end

  test "a leak found by the wrapper's reap exits 5, after a signal (F4)", c do
    w = wrapper(c, 5, :hold)
    reader = w.reader
    assert_receive {^reader, {:data, "ready\n"}}
    {:os_pid, pid} = Port.info(w.port, :os_pid)
    assert Bench.signal(pid, "TERM")
    assert {5, out} = exit_status(w.port)
    assert out =~ "pull-e2e: LEAK"
  end

  test "a leak found by the wrapper's reap exits 5, after a run that passed (F4)", c do
    w = wrapper(c, 5, :exit0)
    assert {5, out} = exit_status(w.port)
    assert out =~ "pull-e2e: LEAK"
    assert lines(w) == ["prepare", "run", "reap"]
  end

  test "a run that passed and left nothing exits 0", c do
    w = wrapper(c, 0, :exit0)
    assert {0, _} = exit_status(w.port)
  end

  # ---- watchdog, verdicts ------------------------------------------------------------------

  test "the watchdog fires at its deadline, and not once cancelled" do
    test = self()
    Bench.watchdog(Bench.now() - 1, fn -> send(test, :fired) end)
    assert_receive :fired

    dog = Bench.watchdog(Bench.now() + 3_600_000, fn -> send(test, :late) end)
    ref = Process.monitor(dog)
    Bench.cancel(dog)
    assert_receive {:DOWN, ^ref, :process, ^dog, _}
    refute_received :late
  end

  test "the watchdog's verdict is 5 when its reap found a leak, else 3 (F4)" do
    assert Run.watchdog_status({:error, []}) == 5
    assert Run.watchdog_status({:ok, []}) == 3
  end

  test "an exit or a throw in a scenario is a failure, not an escape (F4)" do
    assert {:error, :exit, :boom, _} = Run.guard(fn -> exit(:boom) end)
    assert {:error, :throw, :ball, _} = Run.guard(fn -> throw(:ball) end)
    assert {:error, :error, %RuntimeError{}, _} = Run.guard(fn -> raise "x" end)
    assert {:ok, 1} = Run.guard(fn -> 1 end)
  end

  test "each run keeps its artifacts in a folder of its own (F12)" do
    refute Run.artifacts("/tmp/pe.AAAAAA") == Run.artifacts("/tmp/pe.BBBBBB")
    assert Path.basename(Run.artifacts("/tmp/pe.AAAAAA")) == "pe.AAAAAA"
  end

  # ---- waits and the run's inputs --------------------------------------------------------------

  test "polls begun before the mark do not count" do
    hub = Support.hub!()

    poll = fn began ->
      Hub.publish(:wire, %{route: :poll, status: 200, began: began, req: %{}, resp: %{}}, hub)
    end

    poll.(100)
    poll.(200)
    poll.(1_000)
    task = Task.async(fn -> Await.polls(2, 500, hub: hub) end)
    poll.(1_200)
    assert task |> Task.await() |> Enum.map(& &1.data.began) == [1_000, 1_200]
  end

  test "S3's first poll after the restart is one that began after the refused one (F3)" do
    hub = Support.hub!()

    publish = fn data ->
      Hub.publish(:wire, Map.merge(%{route: :poll, req: %{}, resp: %{}}, data), hub)
    end

    # A poll the old core answered; its record ends after the refused one's (a long poll).
    refused = publish.(%{status: 502, upstream: :refused, began: 100, ended: 110})
    publish.(%{status: 200, upstream: :ok, began: 90, ended: 120})
    publish.(%{status: 200, upstream: :ok, began: 200, ended: 205})
    assert AtlasE2E.Pull.Steps.up_after(refused, hub: hub).data.began == 200
  end

  test "S5 requires a lost lease's attempt to end lost (expired), not to stay running (F10)" do
    attempt = fn values -> %{"key" => "TA-x-1", "values" => values, "links" => %{}} end

    ended = %{
      "lease_id" => "L",
      "state" => "lost",
      "result_kind" => "expired",
      "ended_at" => "2026-11-18T10:00:00Z"
    }

    assert AtlasE2E.Pull.Steps.attempt_lost?(attempt.(ended))
    # Today's behaviour (the bug Main ruled on) must fail the gate, not pass it.
    refute AtlasE2E.Pull.Steps.attempt_lost?(attempt.(%{"lease_id" => "L", "state" => "running"}))
    refute AtlasE2E.Pull.Steps.attempt_lost?(attempt.(Map.delete(ended, "ended_at")))
    refute AtlasE2E.Pull.Steps.attempt_lost?(attempt.(%{ended | "result_kind" => "completed"}))
  end

  test "a real codex on PATH refuses the run", c do
    real = Path.join(c.run, "real")
    ours = Path.join(c.run, "ours")

    for dir <- [real, ours] do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "codex"), "#!/bin/sh\n")
      File.chmod!(Path.join(dir, "codex"), 0o755)
    end

    assert Runtime.check_path("#{real}:#{ours}:/usr/bin:/bin", Path.join(ours, "codex")) ==
             {:error, Path.join(real, "codex")}

    assert Runtime.check_path("#{ours}:#{real}:/usr/bin:/bin", Path.join(ours, "codex")) == :ok
  end

  test "a scenario that requires D2 reports it missing until the tree carries put_blob", c do
    file = Path.join(c.run, "platform/atlas_runtime/lib/atlas_runtime/sources/http_target.ex")
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, "def put_blob(_ref, _blob), do: :too_large\n")
    assert [{:d2, "D2", _}] = AtlasE2E.Pull.Needs.missing([:d2], c.run)
    File.write!(file, "def put_blob(ref, blob), do: Client.put_blob(%{}, [])\n")
    assert AtlasE2E.Pull.Needs.missing([:d2], c.run) == []
  end

  test "S5 runs on a short lease the Runtime accepts, the rest on one S3 and S4 outlast" do
    assert AtlasE2E.Pull.Core.short_lease_ttl() in 1..86_400
    # Renewed at every poll (poll_max 5 s), checked every 5 s: at least three polls of margin.
    assert AtlasE2E.Pull.Core.short_lease_ttl() >= 3 * 5
    assert AtlasE2E.Pull.Core.lease_ttl() > 160
  end

  test "a Runtime home starts from a copy of the warm service build", c do
    build = Path.join(c.run, "cache/runtime-build")
    File.mkdir_p!(Path.join(build, "lib/x/ebin"))
    File.write!(Path.join(build, "lib/x/ebin/x.beam"), "beam")
    stub = Support.stub!()

    rt =
      Runtime.prepare(c.run, :rt,
        edge_port: 1,
        ca_pem: "pem",
        cli: "/bin/true",
        stub: stub,
        build: build
      )

    assert File.read!(Path.join(rt.home, "build/lib/x/ebin/x.beam")) == "beam"
    File.write!(Path.join(rt.home, "build/lib/x/ebin/x.beam"), "changed")
    assert File.read!(Path.join(build, "lib/x/ebin/x.beam")) == "beam"
  end
end
