defmodule AtlasRuntime.FailedContinuationTest do
  use ExUnit.Case, async: false

  alias AtlasRuntime.{BackendPolicy, ExecutionEvents, FakeNative, Service, Workspaces}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)
    FakeNative.install!(Path.join(bin, "codex"), "admission", [dir])
    previous = System.fetch_env!("PATH")
    System.put_env("PATH", bin <> ":" <> previous)
    on_exit(fn -> System.put_env("PATH", previous) end)

    state = %{
      dir: dir,
      policy: BackendPolicy.empty(),
      events: ExecutionEvents.open(dir),
      workers: %{},
      stopping: false
    }

    %{state: state}
  end

  defp call(state, request) do
    assert {:reply, {reply, false}, next} =
             Service.handle_call(request, {self(), make_ref()}, state)

    {reply, next}
  end

  # Drive the service with native messages directly: no polling or timer sleeps.
  defp ended(state, pid, monitor) do
    # Successful completion demonitor/flushes the service's monitor. Observe exit
    # independently so the callback cannot remove the notification we await.
    exit_monitor = Process.monitor(pid)
    state = terminal(state, pid, monitor)
    assert_receive {:DOWN, ^exit_monitor, :process, ^pid, _}, 5_000
    state
  end

  defp terminal(state, pid, monitor) do
    if Enum.any?(state.workers, fn {_, worker} -> worker.agent == pid end) do
      receive do
        {:DOWN, ^monitor, :process, ^pid, _} = message ->
          {:noreply, state} = Service.handle_info(message, state)
          terminal(state, pid, monitor)

        {:agent, ^pid, _} = message ->
          {:noreply, state} = Service.handle_info(message, state)
          terminal(state, pid, monitor)
      after
        5_000 -> flunk("Native fixture did not reach a terminal service state")
      end
    else
      state
    end
  end

  test "completion and failure both release the worker and confirm process exit", %{
    state: initial
  } do
    for {outcome, number} <- Enum.with_index([:success, :failure], 1) do
      owner = self()

      {pid, monitor} =
        spawn_monitor(fn ->
          receive do
            :finish ->
              case outcome do
                :success -> send(owner, {:agent, self(), {:ended, "done"}})
                :failure -> exit(:fixture_failure)
              end
          end
        end)

      on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
      id = "turn-" <> String.pad_leading(Integer.to_string(number), 16, "0")
      folder = Path.join([initial.dir, "turns", id])
      File.mkdir_p!(folder)

      run = %{
        id: id,
        worker_id: "alpha",
        state: "running",
        backend: "codex",
        started_at: "2026-11-12T00:00:00Z",
        artifacts: folder
      }

      state = %{initial | workers: %{"alpha" => %{agent: pid, monitor: monitor, run: run}}}
      send(pid, :finish)
      state = ended(state, pid, monitor)
      worker = state.workers["alpha"]
      assert worker.agent == nil
      assert worker.monitor == nil
      assert worker.run.state == if(outcome == :success, do: "finished", else: "failed")
      refute Process.alive?(pid)
      refute_received {:DOWN, ^monitor, :process, ^pid, _}
    end
  end

  test "failed Codex turns resume their confirmed session through either selector", %{
    state: initial
  } do
    for selector <- [:worker, :turn] do
      {started, state} =
        call(initial, %{
          "command" => "start",
          "worker_id" => "alpha",
          "cwd" => initial.dir,
          "assignment" => "plain:fail"
        })

      assert %{id: _} = started
      worker = state.workers["alpha"]

      on_exit(fn ->
        if Process.alive?(worker.agent), do: AtlasRuntime.Agent.Native.stop(worker.agent)
      end)

      state = ended(state, worker.agent, worker.monitor)
      source = state.workers["alpha"].run
      assert source.state == "failed"
      assert is_binary(source.session_id)

      request = %{"command" => "continue", "worker_id" => "alpha", "assignment" => "plain:next"}

      {request, state} =
        if selector == :turn,
          do: {Map.put(request, "turn_id", started.id), %{state | workers: %{}}},
          else: {request, state}

      {resumed, state} = call(state, request)
      assert resumed.id != source.id
      assert resumed.source_turn_id == source.id
      worker = state.workers["alpha"]

      on_exit(fn ->
        if Process.alive?(worker.agent), do: AtlasRuntime.Agent.Native.stop(worker.agent)
      end)

      state = ended(state, worker.agent, worker.monitor)
      assert state.workers["alpha"].run.state == "finished"
      assert state.workers["alpha"].run.session_id == source.session_id

      launches =
        initial.dir
        |> Path.join("native-starts.jsonl")
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&JSON.decode!/1)

      last = List.last(launches)
      assert last["resumed"]
      assert "resume" in last["argv"]
      assert Enum.take(last["argv"], -2) == [source.session_id, "plain:next"]
      assert Workspaces.workspace_path(initial.dir) == source.cwd
    end
  end

  test "failed turns without a session refuse clearly; running turns still refuse", %{
    state: state
  } do
    for {status, sessions} <- [
          {"failed", [nil, "", "  "]},
          {"running", [nil, "", "  ", "confirmed-session"]}
        ],
        session <- sessions do
      run = %{state: status, session_id: session, worker_id: "alpha"}
      state = %{state | workers: %{"alpha" => %{agent: nil, monitor: nil, run: run}}}

      {reply, ^state} =
        call(state, %{"command" => "continue", "worker_id" => "alpha", "assignment" => "next"})

      assert reply.command_error ==
               if(status == "failed",
                 do: "The selected turn has no confirmed native session",
                 else: "Continue requires a finished, stopped, killed or failed turn"
               )
    end
  end
end
