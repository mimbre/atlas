defmodule AtlasFlow.Activities.ReviewFixTest do
  @moduledoc """
  F2 (plan 2026-11-17 §4, §4.1, §5 F2): the review and fix loop and its strategy ladder,
  through the run store, with `FakeFacts` and a fake `AtlasFlow.Runtime.Client`
  (`AtlasFlow.FakeRuntime`), on the test subflow `AtlasFlow.Sorts.Reviewed`, which runs
  the loop as a package's subflow would.

  Review and fix: approved; changes_required → a fix on the author's result → approved; a
  failing check → a fix; an unfinished check; an unparseable verdict → one new review,
  then the ladder; a review in an author's conversation → a new review; the review's
  input is exactly the author's result, and a review whose `based_on` is not it is
  superseded. The ladder: two failed fixes → diagnose → a fresh author from the original
  base in a new work → `deep_coding_max`, skipped when the policy refuses it. Decisions:
  a safe default → recorded and work continues; an authority decision →
  `awaiting_decision`. Restarts: the ladder's state is the run's, rebuilt from Facts.
  """
  use ExUnit.Case, async: false

  alias AtlasFlow.{Engine, FakeFacts, FakeRuntime, Ladder, ManualClock, Sorts, TestModel}
  alias AtlasFlow.Runs.{Run, Store}

  @now ~U[2026-11-17 09:00:00Z]

  defmodule Looped do
    @moduledoc false
    use AtlasFlow.TestModel,
      subflows: [AtlasFlow.Sorts.Reviewed],
      selection: %{"sort" => Map.put(AtlasFlow.Depot.selection("sort"), "imports", [])}
  end

  setup do
    Application.put_env(:atlas_bus, :store, "state-#{System.unique_integer([:positive])}")
    machinery = Application.get_env(:atlas_flow, :machinery)
    client = Application.get_env(:atlas_flow, :runtime_client)

    Application.put_env(:atlas_flow, :machinery, %{
      "mac-mini" => %{url: "http://127.0.0.1:9", token_env: "ATLAS_FLOW_REVIEW_TEST_TOKEN"}
    })

    Application.put_env(:atlas_flow, :runtime_client, FakeRuntime)

    on_exit(fn ->
      restore(:machinery, machinery)
      restore(:runtime_client, client)
    end)

    start_supervised!(FakeFacts)
    start_supervised!(FakeRuntime)
    clock = start_supervised!({ManualClock, @now})
    FakeFacts.put("machinery", %{"key" => "mac-mini", "values" => %{"name" => "mac-mini"}})
    FakeFacts.put("clerk", %{"key" => "ada"})
    :ok = AtlasBus.attach("flow")
    c = put_in(TestModel.config(), ["selection", "sort", "imports"], [])
    assert :ok = Run.validate(Sorts.Reviewed)
    box("B-1", "mac-mini")
    %{c: c, flows: %{"sort" => Sorts.Reviewed}, clock: clock}
  end

  defp restore(key, nil), do: Application.delete_env(:atlas_flow, key)
  defp restore(key, value), do: Application.put_env(:atlas_flow, key, value)

  defp box(key, owner) do
    FakeFacts.put("box", %{
      "key" => key,
      "values" => %{"phase" => "first", "step" => "Pack {#{key}} first."},
      "links" => %{"owned_by" => List.wrap(owner)},
      "origins" => %{"owned_by" => %{"by" => "melle", "position" => 1}}
    })
  end

  # -- The Runtime's answers ------------------------------------------------------------

  # An author or fix work completed in conversation `conv`: its result frozen as `csf`
  # (relative to the base `sha`), its check ending as `check` says.
  defp authored(key, csf, conv, check \\ %{"exit_status" => 0}, based_on \\ nil) do
    FakeRuntime.attempt!(key, %{"provenance" => %{"conversation_id" => conv}})

    product =
      %{
        "workspace" => %{"changed" => true, "base_sha" => "sha-base-1"},
        "frozen" => %{"base" => "develop", "fingerprints" => [root(csf)]},
        "check" =>
          Map.merge(
            %{"command" => ["bin/check"], "output" => %{"tail" => "check output of #{key}"}},
            check
          )
      }
      |> then(&if(based_on, do: Map.put(&1, "based_on", based_on(based_on)), else: &1))

    FakeRuntime.finish(key, "completed", %{"answer" => "Packed.", "work_product" => product})
  end

  # A review or diagnosis work completed in conversation `conv` on the result `csf`.
  defp answered(key, csf, conv, answer) do
    FakeRuntime.attempt!(key, %{"provenance" => %{"conversation_id" => conv}})

    FakeRuntime.finish(key, "completed", %{
      "answer" => answer,
      "work_product" => %{"workspace" => %{"changed" => false}, "based_on" => based_on(csf)}
    })
  end

  defp root(csf), do: %{"root" => "atlas", "fingerprint" => csf}
  defp based_on(csf), do: %{"work_id" => "w-x", "attempt" => 1, "fingerprints" => [root(csf)]}

  defp verdict(verdict, findings \\ []),
    do:
      "Reviewed it.\n\n```json\n" <>
        JSON.encode!(%{"verdict" => verdict, "findings" => findings}) <> "\n```\n"

  defp diagnosis(map), do: "Looked into it.\n\n" <> JSON.encode!(map)

  # -- The run --------------------------------------------------------------------------

  defp run(key \\ "B-1") do
    case FakeFacts.get("cursor", Run.key("sort", "box", key, 1)) do
      nil -> nil
      fact -> with {:ok, run} <- Store.decode(TestModel.config(), fact), do: run
    end
  end

  defp reconcile(c, key \\ "B-1") do
    {:ok, %{runs: known}} = Store.plan(c.c, c.flows)
    now = ManualClock.now(c.clock)
    {:ok, runs} = Store.reconcile_subjects(c.c, c.flows, now, known, [{"box", key}])
    assert [run] = Enum.filter(runs, &(&1["subject_key"] == key))
    run
  end

  defp request(key), do: FakeRuntime.work(key)["request"]
  defp record(key), do: FakeFacts.get("task", key)["values"]

  # Author TK-B-1-1 completed with its check passed, and its review submitted: the state.
  defp to_review(c, csf \\ "csf_author", conv \\ "conv-author") do
    assert reconcile(c)["pending"]["task"]["key"] == "TK-B-1-1"
    authored("TK-B-1-1", csf, conv)
    reviewing = reconcile(c)
    assert reviewing["state"] == "reviewing"
    reviewing
  end

  # -- Review and fix -------------------------------------------------------------------

  test "approved: the author's result is reviewed read-only, and the box is ready", c do
    reviewing = to_review(c)
    assert reviewing["pending"]["task"]["key"] == "TK-B-1-2"

    # Exactly the author's frozen result, read-only, in a new work: never resume_from.
    review = request("TK-B-1-2")

    assert review["workspace"] == %{
             "kind" => "from_work",
             "work_id" => "w-1",
             "attempt" => 1,
             "permissions" => "read-only"
           }

    assert review["profile"] == "independent_review" and review["after_check"] == nil
    refute Map.has_key?(review, "resume_from")
    assert review["instructions"] =~ "Review the packed box."
    assert review["instructions"] =~ ~s({"verdict": "approved" | "changes_required")
    assert record("TK-B-1-2")["kind"] == "review"

    assert JSON.decode!(record("TK-B-1-2")["input"]) == %{
             "result" => "TK-B-1-1",
             "work_id" => "w-1",
             "attempt" => 1,
             "access" => "read"
           }

    answered("TK-B-1-2", "csf_author", "conv-reviewer", verdict("approved"))
    ready = reconcile(c)
    assert {ready["state"], ready["status"]} == {"ready", "completed"}

    assert [
             %{"key" => "TK-B-1-1", "task_kind" => "author", "step" => "review"},
             %{"key" => "TK-B-1-2", "task_kind" => "review", "verdict" => "approved"} = rev
           ] = ready["pending"]["tasks"]

    assert rev["based_on"] == "csf_author" and rev["step"] == "ready"
    assert record("TK-B-1-2")["verdict"] == "approved"
    assert record("TK-B-1-2")["based_on"] == "csf_author"
    assert record("TK-B-1-1")["result_fingerprints"] == JSON.encode!([root("csf_author")])
  end

  test "changes_required: a fix on the author's result, with the findings; then approved", c do
    to_review(c)
    answered("TK-B-1-2", "csf_author", "conv-reviewer", verdict("changes_required", ["Seal it."]))
    fixing = reconcile(c)
    assert fixing["state"] == "fixing"

    # On the reviewed author's result (never the review's), to change, with bin/check.
    fix = request("TK-B-1-3")

    assert fix["workspace"] == %{
             "kind" => "from_work",
             "work_id" => "w-1",
             "attempt" => 1,
             "permissions" => "workspace-write"
           }

    assert fix["after_check"] == %{"command" => ["bin/check"]}
    assert fix["instructions"] =~ "Fix the packed box."
    assert fix["instructions"] =~ "The review found:\n\n- Seal it."
    assert record("TK-B-1-3")["kind"] == "fix"
    assert fixing["pending"]["ladder"]["fixes"] == 1

    # The fix passes its check: its own result is reviewed next.
    authored("TK-B-1-3", "csf_fix", "conv-fixer", %{"exit_status" => 0}, "csf_author")
    assert reconcile(c)["state"] == "reviewing"
    assert request("TK-B-1-4")["workspace"]["work_id"] == "w-3"
    assert request("TK-B-1-4")["workspace"]["permissions"] == "read-only"

    answered("TK-B-1-4", "csf_fix", "conv-reviewer-2", verdict("approved"))
    assert reconcile(c)["state"] == "ready"
  end

  test "a failing check: a fix on that result, with the check's output", c do
    reconcile(c)
    authored("TK-B-1-1", "csf_author", "conv-author", %{"exit_status" => 1})
    fixing = reconcile(c)
    assert fixing["state"] == "fixing"
    fix = request("TK-B-1-2")

    assert fix["workspace"]["work_id"] == "w-1" and
             fix["workspace"]["permissions"] == "workspace-write"

    assert fix["instructions"] =~ "The check failed (exit 1)."
    assert fix["instructions"] =~ "check output of TK-B-1-1"

    authored("TK-B-1-2", "csf_fix", "conv-fixer")
    assert reconcile(c)["state"] == "reviewing"
    assert request("TK-B-1-3")["workspace"]["work_id"] == "w-2"
  end

  test "an unfinished check is a failed one: the fix is told to run bin/check", c do
    reconcile(c)

    authored("TK-B-1-1", "csf_author", "conv-author", %{
      "exit_status" => nil,
      "interrupted" => true
    })

    assert reconcile(c)["state"] == "fixing"
    assert request("TK-B-1-2")["instructions"] =~ "The check did not finish; run bin/check."
  end

  test "an unparseable verdict: one new review; a second one climbs the ladder", c do
    to_review(c)
    answered("TK-B-1-2", "csf_author", "conv-reviewer", "Looks fine to me.")
    again = reconcile(c)
    assert again["state"] == "reviewing" and again["pending"]["task"]["key"] == "TK-B-1-3"
    assert request("TK-B-1-3")["workspace"]["work_id"] == "w-1"

    answered("TK-B-1-3", "csf_author", "conv-reviewer-2", ~s(Done. {"verdict": "maybe"}))
    diagnosing = reconcile(c)
    assert diagnosing["state"] == "diagnosing"
    assert diagnosing["pending"]["ladder"]["rung"] == "a"
  end

  test "a review in an author's conversation is invalid: a new review is asked", c do
    to_review(c)
    # The reviewer ran in the author's own conversation (lesson 8).
    answered("TK-B-1-2", "csf_author", "conv-author", verdict("approved"))
    again = reconcile(c)
    assert again["state"] == "reviewing" and again["pending"]["task"]["key"] == "TK-B-1-3"

    answered("TK-B-1-3", "csf_author", "conv-reviewer", verdict("approved"))
    assert reconcile(c)["state"] == "ready"
  end

  test "the review's input is exactly the author's result: another based_on is superseded", c do
    to_review(c)

    assert request("TK-B-1-2")["workspace"] |> Map.take(["work_id", "attempt"]) ==
             %{"work_id" => "w-1", "attempt" => 1}

    # A verdict on another result than the author's is discarded, never taken.
    answered("TK-B-1-2", "csf_other", "conv-reviewer", verdict("approved"))
    again = reconcile(c)
    assert again["state"] == "reviewing" and again["pending"]["task"]["key"] == "TK-B-1-3"
    assert request("TK-B-1-3")["workspace"]["work_id"] == "w-1"

    answered("TK-B-1-3", "csf_author", "conv-reviewer", verdict("approved"))
    ready = reconcile(c)
    assert ready["state"] == "ready"
    assert List.last(ready["pending"]["tasks"])["based_on"] == "csf_author"
  end

  # -- The ladder -----------------------------------------------------------------------

  # The author and two fixes fail their check: two fixes at no rung did not resolve it.
  defp two_failed_fixes(c) do
    reconcile(c)
    authored("TK-B-1-1", "csf_1", "conv-1", %{"exit_status" => 1})
    assert reconcile(c)["state"] == "fixing"
    authored("TK-B-1-2", "csf_2", "conv-2", %{"exit_status" => 1})
    assert reconcile(c)["state"] == "fixing"
    authored("TK-B-1-3", "csf_3", "conv-3", %{"exit_status" => 1})
    reconcile(c)
  end

  test "round limit: two failed fixes → diagnose → a fresh author → deep_coding_max", c do
    diagnosing = two_failed_fixes(c)
    assert diagnosing["state"] == "diagnosing"

    assert diagnosing["pending"]["ladder"] |> Map.take(["rung", "fixes"]) == %{
             "rung" => "a",
             "fixes" => 0
           }

    # (a) The latest result, read-only, as an investigator, with the history.
    diagnose = request("TK-B-1-4")

    assert diagnose["workspace"]["work_id"] == "w-3" and
             diagnose["workspace"]["permissions"] == "read-only"

    assert record("TK-B-1-4") |> Map.take(["kind", "role"]) == %{
             "kind" => "diagnose",
             "role" => "investigator"
           }

    assert diagnose["instructions"] =~ "## What happened"
    assert diagnose["instructions"] =~ "TK-B-1-3 (fix): check_failed"
    assert diagnose["instructions"] =~ ~s("cause": "wrong_assumption")

    answered(
      "TK-B-1-4",
      "csf_3",
      "conv-4",
      diagnosis(%{
        "cause" => "wrong_assumption",
        "evidence" => "It packs the lid first.",
        "advice" => "Pack the base first."
      })
    )

    fresh = reconcile(c)
    assert fresh["state"] == "fresh" and fresh["pending"]["ladder"]["rung"] == "b"

    # (b) A new work from the original base (the first author's), never from_work of a
    # failed attempt; the diagnosis and what failed before in its instructions.
    author = request("TK-B-1-5")

    assert author["workspace"] == %{
             "kind" => "repository",
             "url" => "https://example.invalid/depot.git",
             "branch" => "flow/TK-B-1-5",
             "base" => "sha-base-1"
           }

    assert author["profile"] == "deep_coding"
    assert author["instructions"] =~ "## Diagnosis\n\nCause: wrong_assumption."
    assert author["instructions"] =~ "Advice: Pack the base first."
    assert author["instructions"] =~ "## What failed before"

    # It fails its check, and its two fixes too: (c) the strongest profile.
    authored("TK-B-1-5", "csf_5", "conv-5", %{"exit_status" => 1})
    assert reconcile(c)["state"] == "fixing"
    assert request("TK-B-1-6")["instructions"] =~ "## Diagnosis"
    authored("TK-B-1-6", "csf_6", "conv-6", %{"exit_status" => 1})
    assert reconcile(c)["state"] == "fixing"
    authored("TK-B-1-7", "csf_7", "conv-7", %{"exit_status" => 1})
    stronger = reconcile(c)
    assert stronger["state"] == "stronger" and stronger["pending"]["ladder"]["rung"] == "c"

    assert request("TK-B-1-8") |> Map.take(["profile", "cost_class"]) == %{
             "profile" => "deep_coding_max",
             "cost_class" => "high"
           }

    assert request("TK-B-1-8")["workspace"]["base"] == "sha-base-1"

    # The stronger author passes, and its review approves.
    authored("TK-B-1-8", "csf_8", "conv-8")
    assert reconcile(c)["state"] == "reviewing"
    answered("TK-B-1-9", "csf_8", "conv-9", verdict("approved"))
    assert reconcile(c)["state"] == "ready"
  end

  test "deep_coding_max is skipped when the policy refuses it: on to the final diagnosis", c do
    # The policy offers no deep_coding_max: the Runtime refuses its submit.
    refuse = fn _key, request ->
      if request["profile"] == "deep_coding_max", do: {:refused, :policy_forbids}, else: :default
    end

    FakeRuntime.script(:submit, List.duplicate(refuse, 20))

    two_failed_fixes(c)
    answered("TK-B-1-4", "csf_3", "conv-4", diagnosis(%{"cause" => "other"}))
    assert reconcile(c)["state"] == "fresh"
    authored("TK-B-1-5", "csf_5", "conv-5", %{"exit_status" => 1})
    reconcile(c)
    authored("TK-B-1-6", "csf_6", "conv-6", %{"exit_status" => 1})
    reconcile(c)
    authored("TK-B-1-7", "csf_7", "conv-7", %{"exit_status" => 1})

    # The submit of TK-B-1-8 (stronger) is refused: the rung is skipped, at once, and (d)
    # is the final diagnosis.
    final = reconcile(c)
    assert final["state"] == "diagnosing" and final["pending"]["ladder"]["rung"] == "d"

    assert %{"task_kind" => "author", "outcome" => "stuck", "rung" => "c", "step" => "diagnose"} =
             Enum.find(final["pending"]["tasks"], &(&1["key"] == "TK-B-1-8"))

    assert [["TK-B-1-8", %{"profile" => "deep_coding_max"}]] =
             Enum.filter(FakeRuntime.calls(:submit), &(hd(&1) == "TK-B-1-8"))

    assert record("TK-B-1-8")["reason"] == "refused: policy_forbids"
    assert request("TK-B-1-9")["instructions"] =~ "## The scope choice"
  end

  test "a flaky test gives one fix that stabilises it; failing again, a fresh author", c do
    two_failed_fixes(c)

    answered(
      "TK-B-1-4",
      "csf_3",
      "conv-4",
      diagnosis(%{"cause" => "flaky_test", "evidence" => "Timing."})
    )

    assert reconcile(c)["state"] == "fixing"
    assert request("TK-B-1-5")["instructions"] =~ "stabilise it"
    assert request("TK-B-1-5")["workspace"]["work_id"] == "w-3"
    authored("TK-B-1-5", "csf_5", "conv-5", %{"exit_status" => 1})
    assert reconcile(c)["state"] == "fresh"
  end

  # -- Decisions (rung e) ---------------------------------------------------------------

  @decision %{
    "question" => "Which lid does the box get?",
    "rationale" => "The flat lid fits every box.",
    "options" => [
      %{
        "id" => "flat",
        "text" => "A flat lid",
        "details" => "Use the flat lid.",
        "rule" => "Boxes get a flat lid.",
        "consequences" => "The packing step uses the flat lid."
      },
      %{
        "id" => "domed",
        "text" => "A domed lid",
        "details" => "Use the domed lid.",
        "rule" => "Boxes get a domed lid.",
        "consequences" => "The packing step uses the domed lid."
      }
    ]
  }

  defp to_final_diagnosis(c) do
    two_failed_fixes(c)
    answered("TK-B-1-4", "csf_3", "conv-4", diagnosis(%{"cause" => "unclear_spec"}))
    final = reconcile(c)
    assert final["state"] == "diagnosing" and final["pending"]["ladder"]["rung"] == "d"
    assert request("TK-B-1-5")["instructions"] =~ "## The scope choice"
  end

  test "a decision with a safe default is recorded, and work continues on the default", c do
    to_final_diagnosis(c)
    decision = Map.put(@decision, "safe_to_continue", true)

    answered(
      "TK-B-1-5",
      "csf_3",
      "conv-5",
      diagnosis(%{"cause" => "unclear_spec", "decision" => decision})
    )

    going = reconcile(c)
    assert going["state"] == "fresh" and going["pending"]["ladder"]["rung"] == "e"

    # Proposed, the recommended option first and a decline last.
    fact = FakeFacts.get("decision", "D-TK-B-1-5")
    assert fact["values"]["status"] == "proposed"
    assert fact["values"]["decision"] == "Boxes get a flat lid."
    options = JSON.decode!(fact["values"]["options"])
    assert options["recommended"] == "flat"

    assert Enum.map(options["options"], &{&1["id"], &1["effect"]}) == [
             {"flat", "adopt"},
             {"domed", "adopt"},
             {"hold", "decline"}
           ]

    assert fact["values"]["context"] =~ "work continues on the recommended option"

    assert request("TK-B-1-6")["instructions"] =~ "## Decision"

    assert request("TK-B-1-6")["instructions"] =~
             "continue on the recommended option: A flat lid."
  end

  test "an authority decision waits for the person: awaiting_decision", c do
    to_final_diagnosis(c)
    decision = Map.merge(@decision, %{"safe_to_continue" => true, "touches" => ["credentials"]})

    answered(
      "TK-B-1-5",
      "csf_3",
      "conv-5",
      diagnosis(%{"cause" => "unclear_spec", "decision" => decision})
    )

    waiting = reconcile(c)
    assert {waiting["state"], waiting["status"]} == {"awaiting_decision", "completed"}

    assert FakeFacts.get("decision", "D-TK-B-1-5")["values"]["context"] =~
             "waits for this decision"

    assert FakeRuntime.work("TK-B-1-6") == nil
  end

  test "an environment cause that needs access goes straight to the decision", c do
    two_failed_fixes(c)

    answered(
      "TK-B-1-4",
      "csf_3",
      "conv-4",
      diagnosis(%{"cause" => "environment", "needs" => "access", "decision" => @decision})
    )

    assert reconcile(c)["state"] == "awaiting_decision"
    assert FakeFacts.get("decision", "D-TK-B-1-4")["values"]["status"] == "proposed"
  end

  test "before F5, any other end of a task holds the box", c do
    to_review(c)
    FakeRuntime.finish("TK-B-1-2", "crashed")
    held = reconcile(c)
    assert held["state"] == "held"
    assert held["pending"]["ladder"]["held"] =~ "stuck"
  end

  # -- Restarts -------------------------------------------------------------------------

  test "the ladder's state survives a Flow restart: it is the run's, in Facts", c do
    diagnosing = two_failed_fixes(c)
    assert diagnosing["pending"]["ladder"]["rung"] == "a"

    answered(
      "TK-B-1-4",
      "csf_3",
      "conv-4",
      diagnosis(%{"cause" => "other", "advice" => "Start over."})
    )

    # Flow restarts: the engine boots from Facts alone and takes the diagnosis on.
    restart(c)
    stored = run()
    assert stored["state"] == "fresh"
    assert stored["pending"]["ladder"]["rung"] == "b"
    assert stored["pending"]["ladder"]["diagnosis"]["advice"] == "Start over."

    # And again, mid-rung: the fixes it spent at (b) are kept, so the climb is to (c).
    authored("TK-B-1-5", "csf_5", "conv-5", %{"exit_status" => 1})
    restart(c)

    assert run()["pending"]["ladder"] |> Map.take(["rung", "fixes"]) == %{
             "rung" => "b",
             "fixes" => 1
           }

    authored("TK-B-1-6", "csf_6", "conv-6", %{"exit_status" => 1})
    reconcile(c)

    assert run()["pending"]["ladder"] |> Map.take(["rung", "fixes"]) == %{
             "rung" => "b",
             "fixes" => 2
           }

    authored("TK-B-1-7", "csf_7", "conv-7", %{"exit_status" => 1})
    assert reconcile(c)["state"] == "stronger"
  end

  # A Flow that starts, runs its boot round from Facts alone, and stops again.
  defp restart(c) do
    Registry.unregister(AtlasBus.Endpoints, "flow")
    opts = [every: 3_600_000, clock: {ManualClock, c.clock}, model: Looped]
    Engine.idle(start_supervised!({Engine, opts}, id: Engine))
    stop_supervised!(Engine)
    :ok = AtlasBus.attach("flow")
  end

  # -- The answers ----------------------------------------------------------------------

  describe "parsing" do
    test "a verdict is the JSON block the answer ends with, capped" do
      long = String.duplicate("x", 400)
      findings = for i <- 1..25, do: "#{i} #{long}"

      assert {:ok, "changes_required", parsed} =
               Ladder.verdict(verdict("changes_required", findings))

      assert length(parsed) == 20 and Enum.all?(parsed, &(String.length(&1) == 300))
      assert {:ok, "approved", []} = Ladder.verdict(~s(All good. {"verdict": "approved"}))
      assert :error = Ladder.verdict(~s({"verdict": "approved"} and more text))
      assert :error = Ladder.verdict(~s({"verdict": "changes_required", "findings": []}))
      assert :error = Ladder.verdict(nil)
    end

    test "a diagnosis keeps a complete decision only" do
      assert %{"cause" => "other"} =
               d = Ladder.diagnosis(~s({"cause": "other", "decision": {"question": "Q?"}}))

      refute Map.has_key?(d, "decision")
      assert Ladder.diagnosis(~s({"cause": "bad luck"})) == nil
    end
  end
end
