defmodule AtlasRuntime.RestartReconciliationTest do
  use ExUnit.Case, async: true

  alias AtlasRuntime.{BackendPolicy, ExecutionEvents, Service}
  alias AtlasRuntime.Execution.RestartReconciliation

  @moduletag :tmp_dir
  @now ~U[2026-11-11 16:00:00.000000Z]
  @launch 1_794_416_000

  # A turn record as a previous service left it; `pid` writes its process evidence.
  defp turn(dir, number, fields, pid \\ nil) do
    id = "turn-" <> String.pad_leading(Integer.to_string(number, 16), 16, "0")
    folder = Path.join([dir, "turns", id])
    File.mkdir_p!(folder)

    record =
      Map.merge(
        %{
          "id" => id,
          "worker_id" => "alpha",
          "backend" => "codex",
          "state" => "running",
          "started_at" => "2026-11-11T14:53:13.251513Z",
          "ended_at" => nil,
          "error" => nil,
          "session_id" => "01a1cb33-a3a5-74b3-9ded-ebf8936311bd",
          "model" => "fixture-model",
          "assignment" => "fixture assignment",
          "cwd" => dir,
          "sandbox" => "read-only",
          "artifacts" => folder
        },
        fields
      )

    File.write!(Path.join(folder, "turn.json"), JSON.encode!(record))

    if pid do
      process = Path.join(folder, "process.json")
      File.write!(process, JSON.encode!(%{"pid" => pid, "command" => ["native"]}))
      File.touch!(process, @launch)
    end

    {id, Path.join(folder, "turn.json")}
  end

  defp probe(answer) do
    test = self()

    fn pid, started ->
      send(test, {:probed, pid, started})
      answer
    end
  end

  defp reconcile(dir, answer) do
    events = RestartReconciliation.reconcile(dir, ExecutionEvents.open(dir), probe(answer), @now)
    {events, ExecutionEvents.query(events, nil, 100)["events"]}
  end

  defp read(path), do: path |> File.read!() |> JSON.decode!()

  test "a turn whose process is gone becomes failed, keeps its record and emits the event", %{
    tmp_dir: dir
  } do
    {id, path} = turn(dir, 1, %{}, 1464)
    before = read(path)

    {_, events} = reconcile(dir, {:gone, "pid 1464 runs no process and leads no process group"})

    assert_received {:probed, 1464, @launch}
    after_ = read(path)

    assert after_["state"] == "failed"
    assert after_["recorded_state"] == "running"
    assert after_["ended_at"] == DateTime.to_iso8601(@now)

    assert after_["error"] ==
             "interrupted: the Runtime service restarted while the turn ran; its process " <>
               "(pid 1464) is gone: pid 1464 runs no process and leads no process group"

    assert Map.drop(after_, ~w(state recorded_state ended_at error pending_question)) ==
             Map.drop(before, ~w(state ended_at error))

    assert [
             %{
               "kind" => "execution_failed",
               "turn_id" => ^id,
               "worker_id" => "alpha",
               "backend" => "codex",
               "session_id" => "01a1cb33-a3a5-74b3-9ded-ebf8936311bd",
               "model" => "fixture-model",
               "interruption" => "service_restart",
               "timestamp" => timestamp
             } = event
           ] = events

    assert map_size(event) == 9

    assert timestamp == DateTime.to_iso8601(@now)
    # Reconciled once: a later start finds a terminal record and asks nothing.
    {_, [%{"turn_id" => ^id}]} = reconcile(dir, {:gone, "again"})
    refute_received {:probed, _, _}
  end

  test "a turn whose process may still run, or cannot be judged, stays as recorded", %{
    tmp_dir: dir
  } do
    {_, alive} = turn(dir, 1, %{}, 2001)
    {_, unknown} = turn(dir, 2, %{"state" => "stopping"}, 2002)
    {_, unrecorded} = turn(dir, 3, %{})
    {_, invalid} = turn(dir, 4, %{}, 2004)
    File.write!(Path.join(Path.dirname(invalid), "process.json"), ~s({"pid":"2004"}))
    bytes = Map.new([alive, unknown, unrecorded, invalid], &{&1, File.read!(&1)})

    {_, events} = reconcile(dir, :alive)
    {_, more} = reconcile(dir, :unknown)

    assert events == [] and more == []
    assert Map.new(Map.keys(bytes), &{&1, File.read!(&1)}) == bytes
    # Only turns with valid process evidence are probed.
    assert_received {:probed, 2001, @launch}
    assert_received {:probed, 2002, @launch}
    refute_received {:probed, 2004, _}
  end

  test "terminal turns are never probed or changed", %{tmp_dir: dir} do
    paths =
      for {state, number} <- Enum.with_index(~w(finished failed stopped killed), 1) do
        {_, path} =
          turn(
            dir,
            number,
            %{"state" => state, "ended_at" => "2026-11-11T15:00:00Z"},
            3000 + number
          )

        path
      end

    bytes = Enum.map(paths, &File.read!/1)
    assert {_, []} = reconcile(dir, {:gone, "never"})
    assert Enum.map(paths, &File.read!/1) == bytes
    refute_received {:probed, _, _}
  end

  test "an interrupted stop keeps its termination request and records why it ended", %{
    tmp_dir: dir
  } do
    termination = %{
      "mode" => "stop",
      "stop_requested_at" => "2026-11-11T14:59:00Z",
      "error" => nil
    }

    {_, path} = turn(dir, 1, %{"state" => "stopping", "termination" => termination}, 1464)

    {_, [%{"kind" => "execution_failed"}]} = reconcile(dir, {:gone, "gone"})
    run = read(path)

    assert run["recorded_state"] == "stopping"
    assert run["termination"]["stop_requested_at"] == "2026-11-11T14:59:00Z"
    assert run["termination"]["error"] =~ "interrupted: the Runtime service restarted"
  end

  test "after a restart the worker's latest saved turn identifies it", %{tmp_dir: dir} do
    {old, _} =
      turn(dir, 1, %{
        "state" => "finished",
        "session_id" => nil,
        "started_at" => "2026-11-11T14:00:00Z"
      })

    {interrupted, _} = turn(dir, 2, %{"session_id" => nil}, 1464)
    {events, _} = reconcile(dir, {:gone, "gone"})

    state = %{
      dir: dir,
      policy: BackendPolicy.empty(),
      events: events,
      workers: %{},
      stopping: false
    }

    call = &Service.handle_call(&1, {self(), make_ref()}, state)

    assert {:reply,
            {%{"id" => ^interrupted, "state" => "failed", "error" => "interrupted: " <> _},
             false},
            _} =
             call.(%{"command" => "status", "worker_id" => "alpha"})

    assert {:reply, {%{"id" => ^interrupted, answer: nil}, false}, _} =
             call.(%{"command" => "output", "worker_id" => "alpha"})

    # An interrupted turn without a confirmed native session cannot continue.
    assert {:reply,
            {%{command_error: "The selected turn has no confirmed native session"}, false},
            _} =
             call.(%{"command" => "continue", "worker_id" => "alpha", "assignment" => "next"})

    # An earlier finished turn stays selectable by ID; this one has no saved session.
    assert {:reply,
            {%{command_error: "The selected turn has no confirmed native session"}, false},
            _} =
             call.(%{
               "command" => "continue",
               "worker_id" => "alpha",
               "turn_id" => old,
               "assignment" => "next"
             })

    assert {:reply, {%{command_error: "Unknown worker: beta"}, false}, _} =
             call.(%{"command" => "status", "worker_id" => "beta"})

    assert File.ls!(Path.join(dir, "turns")) |> Enum.sort() == Enum.sort([old, interrupted])
  end

  describe "process listing" do
    # pid= pgid= etime= lines; this BEAM is 900 and PID 1 is launchd.
    defp listing(rows),
      do:
        Enum.map_join([{1, 1, "10-01:00:00"}, {900, 900, "05:00"} | rows], "\n", fn {p, g, e} ->
          "  #{p}  #{g} #{e}"
        end)

    @own 900
    @at 1_000_000

    test "the recorded leader within the launch tolerance may still run" do
      assert RestartReconciliation.classify(
               listing([{1464, 1464, "01:00:00"}]),
               @own,
               1464,
               @at - 3_600 + 4,
               @at
             ) == :alive
    end

    test "a reused PID is another process" do
      assert {:gone, why} =
               RestartReconciliation.classify(
                 listing([{1464, 1464, "02:00"}]),
                 @own,
                 1464,
                 @at - 3_600,
                 @at
               )

      assert why =~ "pid 1464 now belongs to a process started 3480 s from the recorded launch"

      assert {:gone, _} =
               RestartReconciliation.classify(
                 listing([{1464, 1, "1-00:00:00"}]),
                 @own,
                 1464,
                 @at - 60,
                 @at
               )
    end

    test "an absent leader is gone unless its group survives" do
      assert {:gone, "pid 1464 runs no process and leads no process group"} =
               RestartReconciliation.classify(listing([]), @own, 1464, @at, @at)

      assert RestartReconciliation.classify(
               listing([{1470, 1464, "10:00"}]),
               @own,
               1464,
               @at,
               @at
             ) == :alive
    end

    test "a listing that does not prove itself, or cannot be read, proves nothing" do
      assert RestartReconciliation.classify("  1  1 01:00", @own, 1464, @at, @at) == :unknown
      assert RestartReconciliation.classify("", @own, 1464, @at, @at) == :unknown

      assert RestartReconciliation.classify(listing([{1500, 1500, "soon"}]), @own, 1464, @at, @at) ==
               :unknown
    end
  end
end
