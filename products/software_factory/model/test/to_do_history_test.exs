defmodule Model.ToDoHistoryTest do
  use ExUnit.Case, async: true

  alias RelaDSL.RunIdentity

  # Frozen input from merged PR196, before adding To-Do. It is independent of the
  # candidate's generator and includes every state and migration history entry.
  @base "test/fixtures/slice14-digests.json" |> File.read!() |> JSON.decode!()

  test "To-Do and the restored review preserve existing identities and declared history" do
    current =
      RunIdentity.current(
        Model.AtlasEyra.__flows__(),
        Model.AtlasEyra.__rela__(:gates),
        [:prod, :test]
      )

    migrations = Model.AtlasEyra.__rela__(:migrations)
    document = RunIdentity.document(current, migrations)
    # Restoration adds exactly one approved review migration after this frozen base;
    # all other production and test identities and histories remain byte-for-byte data.
    restored = "05019b5d840dc936ea1f6f59f7be2849967f321a975b62bba01dacde16fa1682"

    expected =
      Map.update!(@base["subflows"], "pr_review", fn environments ->
        Map.new(environments, fn {environment, entry} ->
          history =
            (entry["history"] ++ [%{"digest" => restored, "states" => entry["states"]}])
            |> Enum.sort_by(& &1["digest"])

          {environment, %{entry | "digest" => restored, "history" => history}}
        end)
      end)

    assert Map.delete(document["subflows"], "to_do") == expected
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
