defmodule Model.ToDoHistoryTest do
  use ExUnit.Case, async: true

  alias RelaDSL.RunIdentity

  # Frozen input from merged PR196, before adding To-Do. It is independent of the
  # candidate's generator and includes every state and migration history entry.
  @base "test/fixtures/slice14-digests.json" |> File.read!() |> JSON.decode!()

  test "To-Do and capacity preserve every earlier history and unrelated identity" do
    current =
      RunIdentity.current(
        Model.AtlasEyra.__flows__(),
        Model.AtlasEyra.__rela__(:gates),
        [:prod, :test]
      )

    migrations = Model.AtlasEyra.__rela__(:migrations)
    document = RunIdentity.document(current, migrations)
    # Capacity subsequently changes only these two owner definitions. Every earlier
    # entry remains in history, and every other identity is still exactly PR196's.
    assert Map.drop(document["subflows"], ~w(to_do issue pull_request)) ==
             Map.drop(@base["subflows"], ~w(issue pull_request))

    for name <- ~w(issue pull_request), environment <- ~w(prod test) do
      old = @base["subflows"][name][environment]
      entry = document["subflows"][name][environment]
      assert entry["digest"] != old["digest"]
      assert Enum.all?(old["history"], &(&1 in entry["history"]))
    end

    assert RunIdentity.base_problems(@base, document, migrations) == []

    for environment <- ~w(prod test) do
      entry = document["subflows"]["to_do"][environment]
      assert entry["states"] == ~w(done open wont_do)

      assert entry["history"] == [
               %{"digest" => entry["digest"], "states" => entry["states"]}
             ]
    end
  end
end
