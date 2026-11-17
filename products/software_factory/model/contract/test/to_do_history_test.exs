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
    # Restoration added exactly one approved review migration after this frozen base, and
    # F0 (the review pass removed) one more digest; all other production and test
    # identities and histories remain byte-for-byte data.
    restored = "05019b5d840dc936ea1f6f59f7be2849967f321a975b62bba01dacde16fa1682"
    without_pass = "2b5680643a5f8b8add93dd9f25d545901110dfe4ef1688ee5d3a6fd4a52ce86b"
    # F1.4's package digest, which F1.5a's base workspace moved on from.
    package_f14 = "ed9ae978d163fa3b7d7baf396b8fafab0bebbaf06edfe5028fe4f853d9c99d2c"

    expected =
      Map.update!(@base["subflows"], "pr_review", fn environments ->
        Map.new(environments, fn {environment, entry} ->
          added =
            for d <- [restored, without_pass], do: %{"digest" => d, "states" => entry["states"]}

          history = Enum.sort_by(entry["history"] ++ added, & &1["digest"])
          {environment, %{entry | "digest" => without_pass, "history" => history}}
        end)
      end)

    # F1.4's package is new too: no history before its own digest.
    assert Map.drop(document["subflows"], ["to_do", "package"]) == expected
    # F0's migration from the restored digest, and F1.5a's from F1.4's package digest, are
    # approved against the base that has them (develop's digests.json, model-base); this
    # older base predates both digests. The one from the slice-14 digest straight to F0's
    # is approved here.
    older = Enum.reject(migrations, &(&1.opts[:from] in [restored, package_f14]))
    assert RunIdentity.base_problems(@base, document, older) == []

    assert [package, pr_review] =
             RunIdentity.base_problems(@base, document, migrations) |> Enum.sort()

    assert package =~ "migrate package from ed9ae978"
    assert pr_review =~ "migrate pr_review from 05019b5d"

    for {name, states, before} <- [
          {"to_do", ~w(done open wont_do), []},
          {"package", ~w(authored authoring check_failed stuck waiting), [package_f14]}
        ],
        environment <- ~w(prod test) do
      entry = document["subflows"][name][environment]
      assert entry["states"] == states

      assert entry["history"] ==
               Enum.sort_by(
                 for(d <- [entry["digest"] | before], do: %{"digest" => d, "states" => states}),
                 & &1["digest"]
               )
    end
  end
end
