defmodule Model.ToDoHistoryTest do
  use ExUnit.Case, async: true

  alias RelaDSL.RunIdentity

  # Frozen input from merged PR196, before adding To-Do. It is independent of the
  # candidate's generator and includes every state and migration history entry.
  @base "test/fixtures/slice14-digests.json" |> File.read!() |> JSON.decode!()

  test "adding To-Do preserves every existing production and test identity and history" do
    current =
      RunIdentity.current(
        Model.AtlasEyra.__flows__(),
        Model.AtlasEyra.__rela__(:gates),
        [:prod, :test]
      )

    migrations = Model.AtlasEyra.__rela__(:migrations)
    document = RunIdentity.document(current, migrations)
    assert Map.delete(document["subflows"], "to_do") == @base["subflows"]
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
