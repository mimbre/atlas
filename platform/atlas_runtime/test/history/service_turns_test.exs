Code.require_file("fixtures.exs", __DIR__)

defmodule AtlasRuntime.History.ServiceTurnsTest do
  # The turn cases of read_api_test.exs, read through the history facade from a running
  # Service over the synthetic native CLI; it is not real worker proof.
  use ExUnit.Case, async: false

  alias AtlasRuntime.Agent.Native
  alias AtlasRuntime.Boundary.History, as: Facade
  alias AtlasRuntime.{History, Output, Service}
  import AtlasRuntime.HistoryFixtures

  @moduletag capture_log: true
  @all {"local:admin", [:read, :read_all]}
  @owner {"local:owner", [:read]}

  setup do
    dir = home!()
    bin = Path.join(dir, "bin")
    Enum.each([bin, Path.join(dir, "alpha"), Path.join(dir, "beta")], &File.mkdir_p!/1)
    AtlasRuntime.FakeNative.install!(Path.join(bin, "claude"), "question")
    previous = System.fetch_env!("PATH")
    System.put_env("PATH", bin <> ":" <> previous)
    on_exit(fn -> System.put_env("PATH", previous) end)
    %{dir: dir}
  end

  # Registered as the host service registers it, so the history reads find it.
  defp launch(dir, options \\ []) do
    File.rm(Path.join(dir, "runtime.sock"))
    {:ok, pid} = GenServer.start(Service, {dir, nil, [], options}, name: Service)
    on_exit(fn -> halt(pid) end)
    pid
  end

  defp halt(pid) do
    if Process.alive?(pid) do
      agents =
        for {_id, worker} <- :sys.get_state(pid).workers, is_pid(worker.agent), do: worker.agent

      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
      Enum.each(agents, &Native.stop/1)
    end
  end

  defp command(pid, request) do
    {reply, false} = GenServer.call(pid, request, 10_000)
    refute Map.has_key?(reply, :command_error), inspect(reply)
    reply
  end

  defp start(pid, dir, worker, questions) do
    command(pid, %{
      "command" => "start",
      "worker_id" => worker,
      "cwd" => Path.join(dir, worker),
      "assignment" => "Synthetic read fixture",
      "backend" => "claude",
      "questions_enabled" => questions
    })
  end

  defp await(fun, remaining \\ 500) do
    case fun.() do
      result when result in [nil, false] ->
        if remaining == 0,
          do: flunk("condition not reached"),
          else:
            (
              Process.sleep(10)
              await(fun, remaining - 1)
            )

      result ->
        result
    end
  end

  defp turn(client, id) do
    case Facade.get_turn(client, %{turn_id: id}) do
      %Facade.Outcome.Found{turn: turn} -> turn
      %Facade.Outcome.NotFound{} -> nil
    end
  end

  test "a running Service's turns: live state, the owner's work, stop and finish", %{dir: dir} do
    service = launch(dir)
    run = start(service, dir, "alpha", true)
    id = run.id
    await(fn -> :sys.get_state(service).workers["alpha"].run.pending_question end)

    # A turn of no work: read_all only (Q2).
    assert %Facade.Turn{turn_id: ^id, slot: "alpha", state: :running, harness: "claude"} =
             turn(@all, id)

    assert turn(@owner, id) == nil
    assert Facade.list_turns(@owner, %{}).turns == []

    # Once a work's attempt records the turn, its client sees it, with that provenance.
    work!(dir, "work-1", "local:owner", [{id, %{"harness" => "claude-code"}}])

    assert %Facade.Outcome.Turns{turns: [%Facade.Turn{turn_id: ^id, harness: "claude-code"}]} =
             Facade.list_turns(@owner, %{})

    command(service, %{"command" => "stop", "worker_id" => "alpha", "turn_id" => id})
    stopped = await(fn -> (t = turn(@owner, id)) && t.state == :stopped && t end)
    assert %Facade.Turn{native_outcome: :stopped, ended_at: %DateTime{}} = stopped
    assert DateTime.compare(stopped.started_at, stopped.ended_at) != :gt

    finished = start(service, dir, "beta", false)
    beta = await(fn -> (t = turn(@all, finished.id)) && t.state == :finished && t end)

    assert %Facade.Turn{
             slot: "beta",
             native_outcome: :finished,
             harness: "claude",
             reported_model: "claude-sonnet-4-6"
           } = beta

    assert is_binary(beta.conversation_id)

    assert Enum.sort(Enum.map(Facade.list_turns(@all, %{}).turns, & &1.turn_id)) ==
             Enum.sort([id, finished.id])

    # Reads change nothing: the home and the Service's state are as before.
    before = {:sys.get_state(service), files(dir)}
    Facade.list_turns(@all, %{limit: 1})
    Facade.list_turns(@owner, %{slot: "alpha"})
    Facade.get_turn(@owner, %{turn_id: finished.id})
    History.pre_cutover_output(@all, finished.id)
    assert {:sys.get_state(service), files(dir)} == before
  end

  test "after the Service is gone a turn is unknown; after a restart it is failed", %{dir: dir} do
    service = launch(dir)
    run = start(service, dir, "alpha", true)
    await(fn -> :sys.get_state(service).workers["alpha"].run.pending_question end)
    halt(service)

    # No Service: the saved record of an unfinished turn makes no claim it still runs.
    assert %Facade.Turn{state: :unknown, native_outcome: nil, slot: "alpha"} =
             turn(@all, run.id)

    process = Path.join([dir, "turns", run.id, "process.json"])
    pid = process |> File.read!() |> JSON.decode!() |> Map.fetch!("pid")
    launched = File.stat!(process, time: :posix).mtime

    probe = fn
      ^pid, ^launched -> {:gone, "halted with the previous service"}
      _, _ -> :unknown
    end

    launch(dir, process_probe: probe)
    assert %Facade.Turn{state: :failed, native_outcome: :failed} = turn(@all, run.id)
    assert turn(@all, "turn-00000000000000bb") == nil
  end

  test "a pre-cutover turn's output: its buffer for read_all, not_found without (RQ5)", %{
    dir: dir
  } do
    service = launch(dir)
    run = start(service, dir, "alpha", true)
    await(fn -> :sys.get_state(service).workers["alpha"].run.pending_question end)

    assert {:ok, buffer, execution} = History.pre_cutover_output(@all, run.id)

    page =
      await(fn ->
        case Output.read(execution, nil, buffer) do
          {:ok, %{"events" => [_ | _]} = page} -> page
          _ -> nil
        end
      end)

    assert Enum.any?(page["events"], &(&1["tool_name"] == "AskUserQuestion"))

    assert History.pre_cutover_output(@owner, run.id) == :not_found
    assert History.pre_cutover_output(@all, "turn-00000000000000bb") == :not_found

    work!(dir, "work-1", "local:owner", [{run.id, %{}}])
    assert History.pre_cutover_output(@all, run.id) == :work
  end
end
