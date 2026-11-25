defmodule AtlasFlow.Activities.ReviewFixTest do
  @moduledoc """
  F2-E (F2/F3 plan rev 3 §3.1, §5): the review → fix loop on the lease path. A bin's
  author, review, fix and diagnose tasks run as new work, each step a ladder task
  (`AtlasFlow.Ladder`) whose next step the run takes: the original base, the reviewed
  task's change set, read-only for a review or diagnose. Real Dispatch, Delivery, result
  store and Bases on `FakeCode`, `FakeFacts` and a manual clock (`AtlasFlow.Sorts.Loop`).
  Asserted on run fields, fact values, offered work and states, never on wording.
  """
  use ExUnit.Case, async: false
  @moduletag :capture_log

  import AtlasFlow.Sorts.Loop.Bench

  alias AtlasFlow.{Bases, Dispatch, FakeFacts}
  alias AtlasFlow.FakeFacts.Leasing, as: L
  alias AtlasFlow.Activities.Task
  alias AtlasFlow.Runs.Run
  alias AtlasFlow.WorkSource.Translate

  @mini {"mini", "ada"}
  @laptop {"laptop", "bea"}
  @author [{"load.txt", "one\n"}]
  @fixed [{"load.txt", "one\n"}, {"fix.txt", "two\n"}]
  @finding "the load is not strapped"

  setup do
    setup!() |> source!()
  end

  # The run's current intent, its input, and the task fact's values.
  defp intent(run), do: run["pending"]["task"]
  defp input(run), do: intent(run)["work"]["input"]

  defp change_set_of(key) do
    v = task_values(key)
    {v["result_manifest"], v["result_fingerprints"]}
  end

  defp given(run) do
    cs = input(run)["change_set"]
    cs && {cs["manifest"], JSON.encode!(cs["fingerprints"])}
  end

  # Author and two fixes failing their check, a diagnosis (a), a fresh author (b) and its
  # two fixes failing: the run on the stronger rung (c), its author's intent held.
  defp climbed(c) do
    started(c)
    finish(@mini, files: @author, check: 1)

    for _ <- 1..2 do
      assert settle(c)["state"] == "fixing"
      finish(@mini, files: @fixed, check: 1)
    end

    assert settle(c)["state"] == "diagnosing"
    finish(@mini, answer: diagnosis(%{"cause" => "wrong_assumption", "evidence" => "e"}))
    assert settle(c)["state"] == "fresh"
    finish(@mini, files: @fixed, check: 1)

    for _ <- 1..2 do
      assert settle(c)["state"] == "fixing"
      finish(@mini, files: @fixed, check: 1)
    end

    run = settle(c)
    assert {run["state"], run["pending"]["ladder"]["rung"]} == {"stronger", "c"}
    assert intent(run)["work"]["profile"] == "deep_coding_max"
    run
  end

  describe "a review of the author's result" do
    test "is new work: the author's base, its change set, read-only, for the supervisor; then ready",
         c do
      author = intent(started(c))
      %{work: authored} = finish(@mini, files: @author, check: 0)
      a = task_values("TK-B-1-1")
      assert a["result_state"] == "complete"

      run = settle(c)
      assert run["state"] == "reviewing"
      review = intent(run)
      assert review["key"] == "TK-B-1-2"
      assert Translate.intent?(review)

      assert input(run)["base"] == author["work"]["input"]["base"]
      assert review["base_snapshot"] == author["base_snapshot"]
      assert input(run)["permissions"] == "read-only"
      assert given(run) == change_set_of("TK-B-1-1")
      assert review["work"]["profile"] == "independent_review"
      refute Map.has_key?(review["work"], "after_check")
      assert authored.input.base.base_id == input(run)["base"]["base_id"]

      # The review's create: its kind and what it reviews; done for no one else.
      r = task_values("TK-B-1-2")
      assert {r["kind"], r["based_on"]} == {"review", a["result_fingerprints"]}
      assert {:polled, %{leases: []}} = poll(@laptop)

      %{work: offered} = finish(@mini, answer: verdict("approved"))
      assert offered == Translate.offered_work(review)
      assert offered.input.permissions == "read-only"

      ready = settle(c)
      assert {ready["state"], ready["status"]} == {"ready", "completed"}
      assert task_values("TK-B-1-2")["verdict"] == "approved"

      assert [%{"task_kind" => "author"}, %{"task_kind" => "review"} = r] =
               ready["pending"]["tasks"]

      assert {r["verdict"], r["findings"], r["based_on"]} ==
               {"approved", [], a["result_fingerprints"]}
    end

    test "changes required: a fix on the reviewed change set, never the review's; its result is reviewed",
         c do
      author = intent(started(c))
      finish(@mini, files: @author, check: 0)
      assert settle(c)["state"] == "reviewing"
      finish(@mini, answer: verdict("changes_required", [@finding]))

      run = settle(c)
      assert run["state"] == "fixing"
      assert task_values("TK-B-1-2")["verdict"] == "changes_required"
      fix = intent(run)
      assert fix["key"] == "TK-B-1-3"
      assert given(run) == change_set_of("TK-B-1-1")
      assert input(run)["permissions"] == "workspace-write"
      assert input(run)["base"] == author["work"]["input"]["base"]
      assert fix["work"]["after_check"] == %{"command" => ["loop/bin/check"]}
      assert fix["work"]["profile"] == "deep_coding"
      # The finding is in what the fix is told (the review's data, not a wording).
      assert String.contains?(fix["work"]["instructions"], @finding)
      assert run["pending"]["ladder"]["fixes"] == 1

      finish(@mini, files: @fixed, check: 0)
      run = settle(c)
      assert run["state"] == "reviewing"
      assert given(run) == change_set_of("TK-B-1-3")
      assert task_values("TK-B-1-4")["based_on"] == task_values("TK-B-1-3")["result_fingerprints"]

      finish(@mini, answer: verdict("approved"))
      assert settle(c)["state"] == "ready"
    end

    test "a failed check: a fix on that result, told the check's output (#297 case 3)", c do
      started(c)
      finish(@mini, files: @author, check: 1)

      run = settle(c)
      assert run["state"] == "fixing"
      assert given(run) == change_set_of("TK-B-1-1")
      assert intent(run)["loop"]["reviewed"] == "TK-B-1-1"
      # The check's tail (the Runtime's data, not a wording) reaches the fix.
      tail = task_values("TK-B-1-1")["check_output_tail"]
      assert tail == "tail 1"
      assert String.contains?(intent(run)["work"]["instructions"], tail)
    end

    # D-0102: a restart during the after-check leaves a check without an exit status. The
    # ending is result-less: the run stays in its step and the same task runs again.
    test "an unfinished check is no result: the same author task runs again, then its result counts",
         c do
      started = started(c)
      %{lease_id: lease, work: first} = lease!(@mini)
      unfinished = %{exit_status: nil, output_tail: ""}
      change_set = L.change_set(@author, first.input.base.base_id)

      assert {:recorded, _} = report(@mini, lease, 1, %{state: :accepted})
      assert {:recorded, _} = report(@mini, lease, 2, %{state: :started})

      assert {:recorded, %{missing: []}} =
               report(@mini, lease, 3, L.ended(change_set, check: unfinished))

      a = task_values("TK-B-1-1")
      assert {a["check_ending"], a["lease_end_cause"]} == {"no_exit_status", "check_interrupted"}
      assert a["result_manifest"] == nil

      run = settle(c)
      assert {run["state"], intent(run)["key"]} == {started["state"], "TK-B-1-1"}

      %{work: again} = finish(@mini, files: @author, check: 0)
      assert again == first
      assert task_values("TK-B-1-1")["attempt"] == 2

      run = settle(c)
      assert run["state"] == "reviewing"
      assert given(run) == change_set_of("TK-B-1-1")
    end

    test "two fixes per rung, then a diagnosis (a), a fresh author (b) and a stronger one (c), each on the original base",
         c do
      Application.put_env(:atlas_flow, :ladder_profiles, ["deep_coding_max"])
      on_exit(fn -> Application.delete_env(:atlas_flow, :ladder_profiles) end)

      original = input(started(c))["base"]
      finish(@mini, files: @author, check: 1)
      assert settle(c)["state"] == "fixing"
      finish(@mini, files: @fixed, check: 1)
      assert settle(c)["state"] == "fixing"
      finish(@mini, files: @fixed, check: 1)

      run = settle(c)
      assert run["state"] == "diagnosing"
      assert {run["pending"]["ladder"]["rung"], input(run)["permissions"]} == {"a", "read-only"}
      assert given(run) == change_set_of("TK-B-1-3")
      assert task_values("TK-B-1-4")["role"] == "investigator"

      finish(@mini, answer: diagnosis(%{"cause" => "wrong_assumption", "evidence" => "e"}))
      run = settle(c)
      assert {run["state"], run["pending"]["ladder"]["rung"]} == {"fresh", "b"}
      assert intent(run)["work"]["after_check"] == %{"command" => ["loop/bin/check"]}
      assert input(run)["base"] == original
      refute Map.has_key?(input(run), "change_set")
      assert input(run)["permissions"] == "workspace-write"

      for _ <- 1..2 do
        finish(@mini, files: @fixed, check: 1)
        fixing = settle(c)
        assert fixing["state"] == "fixing"
        assert intent(fixing)["work"]["after_check"] == %{"command" => ["loop/bin/check"]}
      end

      finish(@mini, files: @fixed, check: 1)
      run = settle(c)
      assert {run["state"], run["pending"]["ladder"]["rung"]} == {"stronger", "c"}
      assert intent(run)["work"]["profile"] == "deep_coding_max"
      assert intent(run)["work"]["cost_class"] == "high"
      assert intent(run)["work"]["after_check"] == %{"command" => ["loop/bin/check"]}
      assert input(run)["base"] == original
      refute Map.has_key?(input(run), "change_set")
    end

    test "the stronger rung refused by policy is skipped: on to the final diagnosis (d) (#297 case 9)",
         c do
      Application.put_env(:atlas_flow, :ladder_profiles, ["deep_coding_max"])
      on_exit(fn -> Application.delete_env(:atlas_flow, :ladder_profiles) end)

      stronger = climbed(c)
      key = intent(stronger)["key"]
      %{work: offered} = refuse(@mini, :policy_forbids)
      assert offered.work_key == key

      run = settle(c)
      assert {run["state"], run["pending"]["ladder"]["rung"]} == {"diagnosing", "d"}
      assert input(run)["permissions"] == "read-only"

      assert %{"outcome" => "stuck", "reason" => "refused: policy_forbids"} =
               r = Enum.find(run["pending"]["tasks"], &(&1["key"] == key))

      assert {r["task_kind"], r["profile"]} == {"author", "deep_coding_max"}
      assert run["pending"]["ladder"]["awaiting"] == nil
      assert decisions() == []
    end

    test "any other end of a task holds the bin, with a question (#297 case 14)", c do
      started(c)
      finish(@mini, files: @author, check: 0)
      review = intent(settle(c))
      finish(@mini, kind: :failed, reason: "crashed")

      held = settle(c)
      assert {held["state"], held["status"]} == {"held", "active"}
      assert held["pending"]["task"] == nil

      assert %{"on" => "held", "reason" => "stuck", "task" => task, "question" => q} =
               held["pending"]["ladder"]["awaiting"]

      assert task == review["key"]
      # Never a silent hold (ruling 2): the supervisor is offered answers.
      assert [_ | _] = q["answers"]
      assert "abandon" in q["answers"]
      assert List.last(held["pending"]["tasks"])["outcome"] == "stuck"
      assert decisions() == []
    end

    test "an invalid review is reviewed once more, then the bin is held (R1)", c do
      started(c)
      finish(@mini, files: @author, check: 0)
      settle(c)
      finish(@mini, answer: "No verdict here.")

      run = settle(c)
      assert {run["state"], intent(run)["key"]} == {"reviewing", "TK-B-1-3"}
      assert given(run) == change_set_of("TK-B-1-1")

      finish(@mini, answer: "Still none.")
      held = settle(c)
      assert {held["state"], held["status"]} == {"held", "active"}
      assert held["pending"]["task"] == nil

      assert %{"on" => "held", "reason" => "invalid_review:no_verdict"} =
               held["pending"]["ladder"]["awaiting"]

      assert decisions() == []
    end
  end

  describe "the revision a review reviewed" do
    test "is the published revision of the result it was given; none while that one is unpublished",
         c do
      started(c)
      finish(@mini, files: @author, check: 0)
      settle(c)

      # Landing (F3) published the author's result meanwhile.
      FakeFacts.put(
        "task",
        put_in(FakeFacts.get("task", "TK-B-1-1"), ["values", "published_revision"], "rev_a")
      )

      finish(@mini, answer: verdict("changes_required", [@finding]))
      assert settle(c)["state"] == "fixing"
      assert task_values("TK-B-1-2")["reviewed_revision"] == "rev_a"

      finish(@mini, files: @fixed, check: 0)
      assert settle(c)["state"] == "reviewing"

      # The fix is not published yet: the review of it reviewed no revision.
      finish(@mini, answer: verdict("approved"))
      assert settle(c)["state"] == "ready"
      v = task_values("TK-B-1-4")
      assert v["verdict"] == "approved"
      refute Map.has_key?(v, "reviewed_revision")
    end
  end

  describe "the ladder in the run" do
    test "a restart mid-rung keeps it: the fix's base is restored from its snapshot", c do
      started(c)
      finish(@mini, files: @author, check: 1)
      before = settle(c)
      assert before["state"] == "fixing"
      ladder = before["pending"]["ladder"]
      assert %{"fixes" => 1, "repository" => _, "base" => %{}} = ladder

      # Flow restarts: Bases' table is empty; the run is read back from Facts.
      stop_supervised!(Bases)
      start_bases(c)
      fix = intent(before)
      manifest = fix["work"]["input"]["base"]["manifest"]

      after_restart = restored(manifest, fix["base_snapshot"], fn -> reconcile(c) end)
      assert run(c)["pending"]["ladder"] == ladder
      assert intent(after_restart) == fix
      assert Bases.held?(manifest, fix["base_snapshot"])

      finish(@mini, files: @fixed, check: 0)
      assert settle(c)["state"] == "reviewing"
    end

    test "a hand-over cancels the review in flight; no verdict is taken; the next holder's Runtime gets it",
         c do
      started(c)
      finish(@mini, files: @author, check: 0)
      review = intent(settle(c))
      %{lease_id: lease} = lease!(@mini)
      assert {:recorded, _} = report(@mini, lease, 1, %{state: :accepted})
      assert {:recorded, _} = report(@mini, lease, 2, %{state: :started})

      supervise(c, nil)
      :ok = Dispatch.sweep()
      assert {:polled, %{cancel: [^lease]}} = poll(@mini, [lease])

      assert {:recorded, _} =
               report(
                 @mini,
                 lease,
                 3,
                 L.ended(nil, kind: :cancelled, answer: verdict("approved"))
               )

      run = reconcile(c)
      assert {run["state"], intent(run)["key"]} == {"reviewing", review["key"]}
      assert task_values(review["key"])["verdict"] == nil
      assert {:polled, %{leases: []}} = poll(@mini)

      supervise(c, "bea")
      reconcile(c)
      assert %{work: %{work_key: key}} = lease!(@laptop)
      assert key == review["key"]
    end
  end

  describe "the spec" do
    test "only a ladder review, fix or diagnose starts from the latest result, read or written as its kind" do
      {:task, review} = AtlasFlow.Sorts.Reviewed.mechanism("reviewing")
      {:task, fix} = AtlasFlow.Sorts.Reviewed.mechanism("fixing")
      {:task, author} = AtlasFlow.Sorts.Reviewed.mechanism("authoring")
      latest = fn access -> %{"result" => "latest", "access" => access} end

      assert Task.valid?(review) and Task.valid?(fix) and Task.valid?(author)

      assert Task.results(review) ==
               ~w(author review fix diagnose fresh stronger ready held escalate abandon)

      assert Task.results(Map.delete(author, "ladder")) == Task.results()

      refute Task.valid?(Map.put(review, "input", latest.("write")))
      refute Task.valid?(Map.put(fix, "input", latest.("read")))
      refute Task.valid?(Map.put(author, "input", latest.("read")))
      refute Task.valid?(Map.delete(review, "ladder"))
      refute Task.valid?(Map.put(review, "ladder", "yes"))
    end

    test "lesson 7: a ladder fix or author runs bin/check after its work; a review or diagnose none" do
      mechanism = &AtlasFlow.Sorts.Reviewed.mechanism/1
      {:task, fix} = mechanism.("fixing")
      {:task, author} = mechanism.("authoring")
      {:task, review} = mechanism.("reviewing")

      for spec <- [fix, author] do
        assert spec["check"] == ["bin/check"]
        refute Task.valid?(Map.delete(spec, "check"))
        refute Task.valid?(Map.put(spec, "check", nil))
      end

      assert Task.valid?(Map.delete(review, "check"))

      # The loop bench: every fix, fresh and stronger state of the compiled model checks.
      flow = AtlasFlow.Model.load(AtlasFlow.Sorts.Loop, :prod, actors()).flows["work"]

      for state <- ~w(authoring fixing fresh stronger),
          do: assert({:task, %{"check" => ["bin/check"]}} = flow.mechanism(state))
    end

    test "a ladder step that is not the state's kind starts nothing", c do
      started(c)
      finish(@mini, files: @author, check: 0)
      run = settle(c)
      assert run["state"] == "reviewing"
      {:task, review} = c.runner.flows["work"].mechanism("reviewing")
      base = run["pending"]["ladder"]["base"]
      subject = FakeFacts.get("bin", "B-1")

      at = fn step ->
        run
        |> put_in(["pending", "task"], nil)
        |> put_in(["pending", "ladder", "next"], %{"step" => step, "kind" => step, "base" => base})
      end

      ctx = %{
        assignee: {:machinery, "mini"},
        number: fn -> {:ok, 9} end,
        now: ~U[2026-11-17 12:00:00Z]
      }

      assert Task.step(at.("fix"), review, subject, ctx) == :none

      assert {:pending, %{"key" => "TK-B-1-9"}, _, _} =
               Task.step(at.("review"), review, subject, ctx)
    end
  end

  describe "the run machine" do
    @flow AtlasFlow.Sorts.Reviewed
    @now ~U[2026-11-17 12:00:00Z]

    test "a ladder task's outcome is the ladder's step; the ladder is kept across entries" do
      subject = %{"key" => "X-1", "values" => %{}}
      run = Run.new("sort", @flow, subject, [], @now)
      assert run["state"] == "authoring"
      ladder = %{"rung" => nil, "fixes" => 0, "next" => %{"step" => "review"}}
      result = %{"key" => "TK-X-1-1", "outcome" => "completed", "task_kind" => "author"}

      assert {:error, :invalid_task_result} =
               Run.task_result(run, @flow, subject, @now, "completed", result, [], ladder)

      assert {:ok, reviewing} =
               Run.task_result(run, @flow, subject, @now, "review", result, [], ladder)

      assert {reviewing["state"], reviewing["pending"]["ladder"]} == {"reviewing", ladder}

      # Entered again (another step, no new ladder): it stays.
      assert {:ok, ready} =
               Run.task_result(reviewing, @flow, subject, @now, "ready", result, [], nil)

      assert {ready["state"], ready["pending"]["ladder"]} == {"ready", ladder}
      assert length(ready["pending"]["tasks"]) == 2
    end
  end
end
