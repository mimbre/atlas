defmodule AtlasRuntime.LifecycleControlTest do
  @moduledoc "Stop, kill, latch and continuation through the real Service and native host with a scripted fake Codex."
  use ExUnit.Case, async: false

  alias AtlasRuntime.{ExecutionEvents, Service}

  @moduletag capture_log: true

  # The fake Codex: confirms a session, then behaves by assignment. It never contacts a provider.
  @fixture ~S"""
  #!/bin/sh
  root='ROOT'
  cd_dir=; out=; prev=; resume=0; penult=; last=
  for a; do
    case "$prev" in --cd) cd_dir=$a ;; --output-last-message) out=$a ;; esac
    [ "$a" = resume ] && resume=1
    prev=$a; penult=$last; last=$a
  done
  goal=$last
  session=00000000-0000-4000-8000-0000000000aa
  [ $resume = 1 ] && session=$penult
  printf '%s %s %s\n' "$goal" "$resume" "$session" >> "$root/launches.log"
  echo $$ > "$root/$goal.pid"
  started() { printf '{"type":"thread.started","thread_id":"%s"}\n' "$session"; }
  # The session is confirmed only after the stop behaviour is in place.
  case "$goal" in
    edit) printf 'worker\n' > "$cd_dir/notes.txt"; trap 'exit 0' INT ;;
    ignore) trap '' INT ;;
    child) sleep 60 </dev/null >/dev/null 2>&1 & echo $! > "$root/descendant.pid"; trap 'exit 0' INT ;;
    continue)
      started
      cat "$cd_dir/notes.txt" > "$out"
      printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"resumed"}}' '{"type":"turn.completed"}'
      exit 0 ;;
    *) trap 'exit 0' INT ;;
  esac
  started
  while :; do sleep 0.1; done
  """

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "lc-#{Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)}"
      )

    bin = Path.join(dir, "bin")
    workspace = Path.join(dir, "workspace")
    File.mkdir_p!(bin)
    File.mkdir_p!(workspace)
    File.write!(Path.join(bin, "codex"), String.replace(@fixture, "ROOT", dir))
    File.chmod!(Path.join(bin, "codex"), 0o700)
    previous = System.fetch_env!("PATH")
    previous_home = System.get_env("CODEX_HOME")
    System.put_env("PATH", bin <> ":/usr/bin:/bin")
    System.put_env("CODEX_HOME", Path.join(dir, "codex-home"))
    {:ok, service} = GenServer.start(Service, dir)

    on_exit(fn ->
      System.put_env("PATH", previous)

      if previous_home,
        do: System.put_env("CODEX_HOME", previous_home),
        else: System.delete_env("CODEX_HOME")

      for pid_file <- Path.wildcard(Path.join(dir, "*.pid")),
          {pid, _} <- [Integer.parse(File.read!(pid_file))],
          do: System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)

      if Process.alive?(service), do: Process.exit(service, :kill)
      File.rm_rf!(dir)
    end)

    %{dir: dir, workspace: workspace, service: service}
  end

  defp call(context, request) do
    {reply, false} = GenServer.call(context.service, request, 10_000)
    reply
  end

  defp ok(context, request) do
    reply = call(context, request)
    refute Map.has_key?(reply, :command_error), inspect(reply)
    reply
  end

  defp status(context, worker), do: ok(context, %{"command" => "status", "worker_id" => worker})

  defp await(context, worker, predicate, remaining \\ 500) do
    run = status(context, worker)

    cond do
      predicate.(run) ->
        run

      remaining == 0 ->
        flunk("lifecycle evidence not reached: #{inspect(run)}")

      true ->
        Process.sleep(10)
        await(context, worker, predicate, remaining - 1)
    end
  end

  defp start(context, worker, goal) do
    run =
      ok(context, %{
        "command" => "start",
        "worker_id" => worker,
        "cwd" => context.workspace,
        "backend" => "codex",
        "assignment" => goal
      })

    await(context, worker, &is_binary(&1[:session_id]))
    run
  end

  defp control(context, command, run),
    do: call(context, %{"command" => command, "worker_id" => run.worker_id, "turn_id" => run.id})

  defp pid(context, name),
    do: context.dir |> Path.join(name <> ".pid") |> File.read!() |> String.trim()

  defp alive?(pid) do
    case System.cmd("ps", ["-p", pid, "-o", "stat="], stderr_to_stdout: true) do
      {state, 0} -> not String.starts_with?(String.trim(state), "Z")
      _ -> false
    end
  end

  defp kinds(context),
    do:
      Enum.map(
        ExecutionEvents.query(:sys.get_state(context.service).events, nil, 100)["events"],
        & &1["kind"]
      )

  test "cooperative stop latches; release starts nothing; continuation keeps human edits",
       context do
    run = start(context, "alpha", "edit")
    assert %{state: "stopping", termination: %{"mode" => "stop"}} = control(context, "stop", run)
    stopped = await(context, "alpha", &(&1.state == "stopped"))

    assert %{"exit_code" => 0, "confirmed_at" => confirmed, "stop_signalled_at" => signalled} =
             stopped.termination

    assert is_binary(confirmed) and is_binary(signalled)
    refute alive?(pid(context, "edit"))
    notes = Path.join(context.workspace, "notes.txt")
    assert File.read!(notes) == "worker\n"
    # A human edits the folder before explicitly continuing; nothing restores the old process.
    File.write!(notes, "human edit\n")

    continue = %{
      "command" => "continue",
      "worker_id" => "alpha",
      "turn_id" => run.id,
      "assignment" => "continue"
    }

    assert %{command_error: "Worker alpha is latched after stopping turn " <> _} =
             call(context, continue)

    launches = File.read!(Path.join(context.dir, "launches.log"))

    assert %{released: %{"turn_id" => turn}} =
             ok(context, %{"command" => "release", "worker_id" => "alpha"})

    assert turn == run.id
    assert File.read!(Path.join(context.dir, "launches.log")) == launches
    assert status(context, "alpha").id == run.id
    continued = ok(context, continue)
    assert continued.source_turn_id == run.id
    finished = await(context, "alpha", &(&1.state == "finished"))
    assert finished.session_id == "00000000-0000-4000-8000-0000000000aa"

    assert %{answer: "human edit\n"} =
             ok(context, %{"command" => "output", "worker_id" => "alpha"})

    assert String.split(File.read!(Path.join(context.dir, "launches.log")), "\n", trim: true) ==
             [
               "edit 0 00000000-0000-4000-8000-0000000000aa",
               "continue 1 00000000-0000-4000-8000-0000000000aa"
             ]

    assert File.read!(notes) == "human edit\n"

    assert kinds(context) == [
             "execution_accepted",
             "execution_stopped",
             "execution_accepted",
             "execution_finished"
           ]
  end

  test "an ignored interrupt stays stopping without escalation until an explicit kill", context do
    run = start(context, "alpha", "ignore")
    assert %{state: "stopping"} = control(context, "stop", run)
    Process.sleep(3_500)
    assert %{state: "stopping"} = status(context, "alpha")
    assert alive?(pid(context, "ignore"))

    assert %{command_error: "Worker alpha already has an active agent" <> _} =
             call(context, %{
               "command" => "start",
               "worker_id" => "alpha",
               "cwd" => context.dir,
               "assignment" => "x"
             })

    assert %{state: "killing", termination: %{"mode" => "kill"}} = control(context, "kill", run)
    killed = await(context, "alpha", &(&1.state == "killed"))

    assert %{
             "exit_code" => -9,
             "confirmed_at" => _,
             "stop_requested_at" => _,
             "kill_requested_at" => _
           } = killed.termination

    refute alive?(pid(context, "ignore"))
    assert %{state: "killed"} = control(context, "stop", run)
    assert kinds(context) == ["execution_accepted", "execution_killed"]
  end

  test "a surviving descendant keeps the turn stopping; kill reaps it; duplicates converge",
       context do
    run = start(context, "alpha", "child")

    replies =
      1..6
      |> Enum.map(fn _ -> Task.async(fn -> control(context, "stop", run) end) end)
      |> Enum.map(&Task.await/1)

    assert Enum.all?(replies, &(&1.state == "stopping"))

    assert replies |> Enum.map(& &1.termination["stop_requested_at"]) |> Enum.uniq() |> length() ==
             1

    child = pid(context, "descendant")
    await(context, "alpha", &is_binary(&1.termination["stop_signalled_at"]))
    Process.sleep(1_000)
    refute alive?(pid(context, "child"))
    assert alive?(child)
    assert %{state: "stopping"} = status(context, "alpha")

    kills =
      1..4
      |> Enum.map(fn _ -> Task.async(fn -> control(context, "kill", run) end) end)
      |> Enum.map(&Task.await/1)

    assert Enum.all?(kills, &(&1.state in ["killing", "killed"]))
    assert %{state: "killed"} = await(context, "alpha", &(&1.state == "killed"))
    refute alive?(child)
    assert kinds(context) == ["execution_accepted", "execution_killed"]

    assert %{"turn_id" => _} =
             JSON.decode!(
               File.read!(Path.join([context.dir, "workers", "alpha", "admission-latch.json"]))
             )
  end
end
