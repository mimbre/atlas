defmodule AtlasRuntime.History.WorkCoreTest do
  # The history reads on work records as the real work core (D2) writes them, not as a
  # fixture does: a work's turn is its client's, with the work's provenance.
  use ExUnit.Case, async: false

  import AtlasRuntime.WorkHarness
  alias AtlasRuntime.Boundary.History, as: H

  @moduletag capture_log: true

  setup do
    bench = start!()
    previous = Application.get_env(:atlas_runtime, :runtime_home)
    Application.put_env(:atlas_runtime, :runtime_home, bench.dir)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:atlas_runtime, :runtime_home, previous),
        else: Application.delete_env(:atlas_runtime, :runtime_home)
    end)

    %{bench: bench}
  end

  test "a completed work's turn: its client's, with the work's provenance; no other client's",
       %{bench: bench} do
    work = submit!(bench, "complete the history read")
    [attempt] = await_state(work.work_id, :completed).attempts
    turn_id = attempt.turn_id

    turn =
      await(fn ->
        case H.list_turns(client(), %{}) do
          %H.Outcome.Turns{turns: [%H.Turn{state: :finished} = turn]} -> turn
          _ -> nil
        end
      end)

    assert %H.Turn{
             turn_id: ^turn_id,
             slot: "s1",
             native_outcome: :finished,
             harness: "codex",
             configured_model: "gpt-test"
           } = turn

    assert %H.Outcome.Found{turn: ^turn} = H.get_turn(client(), %{turn_id: turn_id})

    other = client("c2")
    assert %H.Outcome.Turns{turns: []} = H.list_turns(other, %{})
    assert %H.Outcome.NotFound{} = H.get_turn(other, %{turn_id: turn_id})
  end
end
