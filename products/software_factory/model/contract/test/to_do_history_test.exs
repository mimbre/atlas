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
    # M3 S3 (#325 B2) owns a To-Do by its assignee: one approved migration from To-Do's
    # first digest, which this older base predates as well.
    to_do_first = "8e387a008256b3c65947e0063dd48fbd4ab70417021cd1bc6cb54d947d59156b"
    # M3 A4: the package's author task input names a Code repository; one approved
    # migration from package's first digest, which this older base predates too.
    package_first = "ed9ae978d163fa3b7d7baf396b8fafab0bebbaf06edfe5028fe4f853d9c99d2c"
    # F2-P: the package runs the review → fix loop; one approved migration from A4's
    # digest, which this older base predates as well.
    package_a4 = "457c90fddd78d1aa85729dee951b6acd6beccdbd9fb109b6adfb89f7686d8747"

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
    # F0's migration from the restored digest is approved against the base that has it
    # (develop's digests.json, model-base); this older base predates that digest. The one
    # from the slice-14 digest straight to F0's is approved here.
    older =
      Enum.reject(
        migrations,
        &(&1.opts[:from] in [restored, to_do_first, package_first, package_a4])
      )

    assert RunIdentity.base_problems(@base, document, older) == []

    assert [_, _, _, _] = problems = RunIdentity.base_problems(@base, document, migrations)
    assert Enum.any?(problems, &(&1 =~ "migrate pr_review from 05019b5d"))
    assert Enum.any?(problems, &(&1 =~ "migrate to_do from 8e387a00"))
    assert Enum.any?(problems, &(&1 =~ "migrate package from ed9ae978"))
    assert Enum.any?(problems, &(&1 =~ "migrate package from 457c90fd"))

    # Each history entry keeps the states it had: the package's two before the loop,
    # with authored and check_failed, and its current one.
    f1 = ~w(authored authoring check_failed stuck waiting)

    loop =
      ~w(authoring awaiting_decision diagnosing fixing fresh held ready reviewing stronger stuck waiting)

    for {name, states, before} <- [
          {"to_do", ~w(done open wont_do), [{to_do_first, ~w(done open wont_do)}]},
          {"package", loop, [{package_first, f1}, {package_a4, f1}]}
        ],
        environment <- ~w(prod test) do
      entry = document["subflows"][name][environment]
      assert entry["states"] == states

      assert entry["history"] ==
               Enum.sort_by(
                 for(
                   {d, s} <- [{entry["digest"], states} | before],
                   do: %{"digest" => d, "states" => s}
                 ),
                 & &1["digest"]
               )
    end
  end
end
