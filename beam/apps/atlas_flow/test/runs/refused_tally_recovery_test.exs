defmodule AtlasFlow.Runs.RefusedTallyRecoveryTest do
  use ExUnit.Case, async: true
  alias AtlasFlow.Runs.Run
  alias AtlasFlow.Sorts
  @now ~U[2026-11-14 17:00:00Z]
  @subject %{"key" => "B-recovery", "values" => %{}}

  defp run(flow \\ Sorts.Plain) do
    Run.new("sort", flow, @subject, [], @now)
    |> put_in(["pending", "writes"], [
      %{"id" => "old", "kind" => "box", "content" => %{"values" => %{"total" => 0}}}
    ])
  end

  test "safe reentry retires the whole obligation, keeps history, and never restarts a generation" do
    original =
      run()
      |> put_in(["pending", "synthetic"], %{"id" => "old-offer", "values" => %{"total" => 0}})
      |> put_in(["pending", "effects"], [%{"id" => "succeeded-once"}])
      |> put_in(["pending", "composition"], %{
        "version" => 1,
        "links" => %{},
        "offered" => %{"entry" => 1}
      })

    receipt = %{"class" => "refused", "content" => %{"reasons" => ["historical refusal"]}}
    proof = %{"plan_id" => "reviewed", "receipt" => receipt}

    assert {:ok, next} =
             Run.reenter_refused_tally_wait(
               original,
               Sorts.Plain,
               @subject,
               proof,
               DateTime.add(@now, 1)
             )

    assert next["key"] == original["key"] and next["generation"] == original["generation"]
    assert next["state"] == original["state"] and next["entry"] == original["entry"] + 1

    assert next["input_cursor"] == original["input_cursor"] and
             next["last_input"] == original["last_input"]

    assert next["pending"]["effects"] == original["pending"]["effects"]
    assert next["pending"]["writes"] == [] and next["pending"]["synthetic"] == nil
    [audit] = next["pending"]["migrations"]
    assert audit["retired"] == Map.take(original["pending"], ~w(writes synthetic composition))
    assert audit["receipt"] == receipt
    assert original["pending"]["writes"] != []
  end

  test "reentry refuses finals, definitions, identities, timers, frozen activities and non-singleton outboxes" do
    original = run()

    variants =
      [
        Map.put(original, "status", "completed"),
        Map.put(original, "status", "blocked"),
        Map.put(original, "definition_sha256", "another-definition"),
        Map.put(original, "state", "done"),
        Map.put(original, "key", "different-run"),
        Map.put(original, "generation", 2),
        Map.put(original, "entry", 0),
        put_in(original, ["deadlines", "timers"], [%{"due" => "later"}]),
        put_in(original, ["pending", "writes"], []),
        put_in(
          original,
          ["pending", "writes"],
          original["pending"]["writes"] ++ original["pending"]["writes"]
        )
      ] ++
        for field <- ~w(gate pass effect definition_block),
            do: put_in(original, ["pending", field], %{"id" => "frozen"})

    for bad <- variants do
      assert {:error, :unsafe_tally_wait} =
               Run.reenter_refused_tally_wait(bad, Sorts.Plain, @subject, %{}, @now)
    end

    # Entry writes and activity requests cannot be made safe by clearing the outbox.
    for flow <- [Sorts.Relabelled, Sorts.Publish] do
      assert {:error, :unsafe_tally_wait} =
               Run.reenter_refused_tally_wait(run(flow), flow, @subject, %{}, @now)
    end

    assert {:error, :unsafe_tally_wait} =
             Run.reenter_refused_tally_wait(original, Sorts.Plain, %{"key" => "other"}, %{}, @now)
  end
end
