defmodule AtlasFlow.LadderCiTest do
  @moduledoc """
  F3-L (F2/F3 plan rev 3 §3.2 item 4): red CI on a published result is a fix step of the
  ladder (`AtlasFlow.Ladder`). Pure; asserted on steps, change sets, findings' data and
  counters, never on wording.
  """
  use ExUnit.Case, async: true

  alias AtlasFlow.Ladder

  @base %{"base_id" => "base-a", "manifest" => "man-a", "base_snapshot" => "snap-a"}
  @profiles ["deep_coding", "independent_review"]

  defp key(n), do: "TK-PK-1-#{n}"

  defp authored(n, ci, kind \\ "author"),
    do:
      %{
        "key" => key(n),
        "kind" => kind,
        "outcome" => "completed",
        "base" => @base,
        "result_state" => "complete",
        "result_manifest" => "rm-#{n}",
        "result_fingerprints" => "csf-#{n}",
        "turn_id" => "turn-#{n}"
      }
      |> Map.merge(
        if ci,
          do: %{
            "review_ci" => ci,
            "published_revision" => "rev-#{n}",
            "review_url" => "https://example.org/pr/#{n}"
          },
          else: %{}
      )

  defp reviewed(n, of, verdict, findings \\ []),
    do: %{
      "key" => key(n),
      "kind" => "review",
      "outcome" => "completed",
      "base" => @base,
      "based_on" => "csf-#{of}",
      "turn_id" => "review-turn-#{n}",
      "answer" =>
        "notes\n```json\n" <>
          JSON.encode!(%{"verdict" => verdict, "findings" => findings}) <> "\n```\n"
    }

  defp ended(tasks, n, ladder \\ nil), do: Ladder.next(ladder, {:ended, key(n)}, tasks, @profiles)

  defp ci_failed(tasks, n, ladder \\ nil),
    do: Ladder.next(ladder, {:ci_failed, key(n)}, tasks, @profiles)

  defp mentions_ci?(findings, n),
    do:
      Enum.any?(
        findings,
        &(String.contains?(&1, "rev-#{n}") and String.contains?(&1, "/pr/#{n}"))
      )

  describe "a review ends on red CI" do
    test "approved: a fix of the reviewed result, not ready; it counts toward the budget" do
      tasks = [authored(1, "failure"), reviewed(2, 1, "approved")]
      {{:task, fix}, ladder} = ended(tasks, 2)

      assert {fix["step"], fix["kind"], fix["permissions"], fix["check"]} ==
               {"fix", "fix", "workspace-write", true}

      assert fix["change_set"] == %{"manifest" => "rm-1", "fingerprints" => "csf-1"}
      assert fix["reviewed"] == key(1)
      assert mentions_ci?(fix["findings"], 1)
      assert ladder["fixes"] == 1
    end

    test "changes required: one fix that carries the findings and the CI failure" do
      tasks = [authored(1, "failure"), reviewed(2, 1, "changes_required", ["f1"])]
      {{:task, fix}, _} = ended(tasks, 2)
      assert [f1, ci] = fix["findings"]
      assert f1 == "f1"
      assert mentions_ci?([ci], 1)

      # The fix is told both (sections read the review and the task's CI record).
      [section] = Ladder.sections("fix", %{}, tasks)
      assert String.contains?(section, "f1") and mentions_ci?([section], 1)
    end

    test "changes required without findings on red CI is a fix, not an invalid review" do
      tasks = [authored(1, "failure"), reviewed(2, 1, "changes_required", [])]
      assert {{:task, %{"step" => "fix"}}, %{"rereviews" => rr}} = ended(tasks, 2)
      assert rr == %{}
    end

    test "CI not red (none, pending, success, unrecorded): as before" do
      for ci <- ["none", "pending", "success", nil] do
        tasks = [authored(1, ci), reviewed(2, 1, "approved")]
        assert {{:ready, %{"task" => k}}, _} = ended(tasks, 2), inspect(ci)
        assert k == key(1)
      end
    end

    test "only the latest result's CI counts: an earlier result's red CI is moot" do
      tasks = [
        authored(1, "failure"),
        reviewed(2, 1, "changes_required", ["f1"]),
        authored(3, nil, "fix"),
        reviewed(4, 3, "approved")
      ]

      assert {{:ready, %{"task" => k}}, _} = ended(tasks, 4)
      assert k == key(3)
    end

    test "the budget holds: red CI after two fixes climbs the ladder" do
      tasks = [authored(1, "failure"), reviewed(2, 1, "approved")]

      assert {{:task, %{"step" => "diagnose"}}, %{"rung" => "a"}} =
               ended(tasks, 2, %{"fixes" => 2, "base" => @base})
    end
  end

  describe "{:ci_failed, key}: no review in flight" do
    test "after the result's approval: a fix of it" do
      tasks = [authored(1, "failure"), reviewed(2, 1, "approved")]
      {{:task, fix}, ladder} = ci_failed(tasks, 1)
      assert {fix["step"], fix["change_set"]["manifest"]} == {"fix", "rm-1"}
      assert mentions_ci?(fix["findings"], 1)
      assert ladder["fixes"] == 1

      # Its instructions name the CI failure, with no review finding.
      [section] = Ladder.sections("fix", ladder, tasks)
      assert mentions_ci?([section], 1)
    end

    test "with nothing since its publication: a fix of it" do
      assert {{:task, %{"step" => "fix"}}, _} = ci_failed([authored(1, "failure")], 1)
    end

    test "it counts toward the budget: prior fixes + 1, and at the budget it climbs" do
      tasks = [authored(1, "failure"), reviewed(2, 1, "approved")]

      assert {{:task, %{"step" => "fix"}}, %{"fixes" => 2}} =
               ci_failed(tasks, 1, %{"fixes" => 1, "base" => @base})

      assert {{:task, %{"step" => "diagnose"}}, %{"rung" => "a"}} =
               ci_failed(tasks, 1, %{"fixes" => 2, "base" => @base})
    end

    test "nothing otherwise" do
      cases = [
        # not red
        {[authored(1, "success"), reviewed(2, 1, "approved")], 1, nil},
        {[authored(1, nil), reviewed(2, 1, "approved")], 1, nil},
        # not the latest result
        {[
           authored(1, "failure"),
           reviewed(2, 1, "changes_required", ["f"]),
           authored(3, nil, "fix")
         ], 1, nil},
        # a review since that did not approve it (its fix is the ladder's already)
        {[authored(1, "failure"), reviewed(2, 1, "changes_required", ["f"])], 1, nil},
        # the ladder waits for the supervisor
        {[authored(1, "failure"), reviewed(2, 1, "approved")], 1,
         %{"awaiting" => %{"on" => "held", "question" => %{"answers" => ["fresh"]}}}}
      ]

      for {tasks, n, ladder} <- cases do
        assert {:none, _} = ci_failed(tasks, n, ladder), inspect({tasks, ladder})
      end
    end
  end
end
