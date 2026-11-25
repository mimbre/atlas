defmodule Model.IssueRunsTest do
  @moduledoc """
  The issue subflow on Flow's durable runs (slice 6): its author, who reads the issue and
  why it is to be done (its use case and scene), has its result reviewed
  by a second task before Code opens its pull request. The review's base is the author's
  result, which Code serves like a branch (`refs/atlas/results/<task>`); it works in a Git
  checkout of it. A review that asks for changes leads to one fix on that result, with its
  findings; the fix's result is published, with the review and the fix's answer. Run by
  `AtlasFlow.Runs.Store` with `AtlasFlow.FakeFacts`, the work source's processes on
  `AtlasFlow.FakeCode` and a manual clock. Structure, not wording.
  """
  use ExUnit.Case, async: false

  alias AtlasFlow.{Bases, Delivery, Dispatch, FakeCode, FakeFacts, ManualClock, Results}
  alias AtlasFlow.WorkSource
  alias AtlasFlow.FakeFacts.Leasing, as: L
  alias AtlasFlow.Runs.{Run, Store}

  @now ~U[2026-11-19 09:00:00Z]
  @key "IS-Atlas-01"
  @author "TK-IS-Atlas-01-1"
  @review "TK-IS-Atlas-01-2"
  @fix "TK-IS-Atlas-01-3"
  @repository "github.com/mimbre/atlas"
  @actors %{"decider" => "someone"}
  @mini {"mac-mini", "ada"}
  @offer %{"deep_coding" => 1, "independent_review" => 1}

  setup do
    Application.put_env(:atlas_bus, :store, "issue-#{System.unique_integer([:positive])}")
    environment = Application.get_env(:atlas_bus, :environment)
    Application.put_env(:atlas_bus, :environment, "test")

    on_exit(fn ->
      if environment,
        do: Application.put_env(:atlas_bus, :environment, environment),
        else: Application.delete_env(:atlas_bus, :environment)
    end)

    {:ok, _} = Application.ensure_all_started(:atlas_bus)
    dir = Path.join(System.tmp_dir!(), "issue-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)

    start_supervised!(FakeFacts)
    {:ok, clock} = ManualClock.start_link(@now)
    clock = {ManualClock, clock}
    :ok = AtlasBus.attach("flow")

    FakeFacts.put("machinery", %{"key" => "mac-mini", "values" => %{"name" => "mac-mini"}})
    FakeFacts.put("person", %{"key" => "ada"})

    runner = AtlasFlow.Model.load(Model.AtlasEyra, :test, @actors)
    assert runner.refusal == nil

    code = start_supervised!({FakeCode, %{}}, id: :code)
    FakeCode.put(code, @repository, "develop", "rev_1", %{"README.md" => "# Atlas\n"})
    start_supervised!({Results, dir: dir, clock: clock, sweep_ms: 86_400_000, pins: fn -> [] end})
    start_supervised!({Bases, client: FakeCode.client(code), clock: clock})

    start_supervised!(
      {Dispatch,
       model: Model.AtlasEyra,
       actors: @actors,
       clock: clock,
       poll_wait: 0,
       sweep_ms: nil,
       resync_ms: nil}
    )

    start_supervised!(
      {Delivery, model: Model.AtlasEyra, actors: @actors, clock: clock, engine: self()}
    )

    # Flow's effect inbox: the publication's request goes out through it (no Code answers).
    start_supervised!(AtlasFlow.Activities.Effect.Inbox)

    %{runner: runner, clock: clock, code: code}
  end

  test "a review's blocking finding leads to one fix, which is published; its follow-up becomes an issue under the use case",
       c do
    issue()
    assert reconcile(c)["pending"]["task"] == nil
    assert_receive {:reconcile, "issue", @key}, 2_000
    supervise(c, "ada")
    assert %{"key" => @author} = reconcile(c)["pending"]["task"]

    # The author reads the issue, then its use case and scene: why it is to be done.
    {_, work} = leased = lease!()
    assert work.instructions =~ "## description\n\nOne typo."
    assert work.instructions =~ "## use_case UC-Atlas-01: description\n\nPeople read the README."
    assert work.instructions =~ "## scene SC-Atlas-01: title\n\nNewcomers"
    finish(lease: leased, answer: "Done.")

    # The author's Runtime pushed its result to Code: the review's base is that result.
    FakeCode.put(c.code, @repository, "refs/atlas/results/" <> @author, "rev_2", %{
      "README.md" => "# Atlas\n\nChanged.\n"
    })

    assert settle(c)["state"] == "reviewing"
    assert_receive {:reconcile, "issue", @key}, 2_000
    reviewing = settle(c)
    assert %{"key" => @review} = intent = reviewing["pending"]["task"]
    {:ok, base} = Bases.cached(@repository, "refs/atlas/results/" <> @author)
    assert intent["work"]["input"]["base"]["base_id"] == base.base_id
    assert FakeFacts.get("task", @review)["values"]["kind"] == "review"

    # A Git checkout it may build in; what it pushes back is never read. The next round
    # offers it.
    assert reconcile(c)["state"] == "reviewing"
    {_, work} = leased = lease!()
    assert work.profile == "independent_review"
    assert work.input.permissions == "workspace-write"
    assert work.input.result_ref == "refs/atlas/results/" <> @review
    assert work.instructions =~ ~s("verdict")
    assert work.instructions =~ ~s("follow_ups")

    follow_up = %{"title" => "Add a contributing guide", "description" => "Newcomers ask."}
    answer = verdict("changes_required", ["A second typo."], [follow_up])
    finish(lease: leased, answer: answer)
    assert settle(c)["state"] == "fixing"
    assert FakeFacts.get("task", @review)["values"]["verdict"] == "changes_required"
    assert FakeFacts.get("task", @review)["values"]["state"] == "completed"

    # The follow-up is a new issue under the issue's use case, made by Flow for ada, with
    # an issue's create defaults (its stage).
    made = FakeFacts.get("issue", "IS-Atlas-02")
    assert made["values"] == Map.put(follow_up, "stage", "specification")
    assert made["links"] == %{"in_use_case" => ["UC-Atlas-01"]}

    # One fix on the author's result (the base the review had), with the review's findings.
    fixing = settle(c)
    assert %{"key" => @fix} = intent = fixing["pending"]["task"]
    assert intent["work"]["input"]["base"]["base_id"] == base.base_id
    assert reconcile(c)["state"] == "fixing"
    {_, work} = leased = lease!()
    assert work.profile == "deep_coding"
    assert work.input.result_ref == "refs/atlas/results/" <> @fix
    assert work.instructions =~ "A second typo."
    refute work.instructions =~ "contributing guide"

    finish(lease: leased, answer: "Fixed the second typo.")
    publishing = settle(c)
    assert publishing["state"] == "publishing"
    assert Enum.map(publishing["pending"]["tasks"], & &1["task_kind"]) == ~w(author review fix)

    # The publication names the fix's result; the review and the fix go with it.
    input = publishing["pending"]["effect"]["request"]["input"]
    assert input["result"] == "refs/atlas/results/" <> @fix

    assert input["review"] == %{
             "task" => @review,
             "verdict" => "changes_required",
             "findings" => ["A second typo."]
           }

    assert input["fix"] == %{"task" => @fix, "answer" => "Fixed the second typo."}

    # Had Code found no changes against develop, it would open no pull: the issue goes to
    # its supervisor (`unchanged`, owned by the decider), its publication says why.
    r = publishing["pending"]["effect"]["request"]

    reply = %{
      "version" => 1,
      "id" => r["id"],
      "digest" => publishing["pending"]["effect"]["digest"],
      "fingerprint" => r["fingerprint"],
      "status" => "refused",
      "reason" => "no_changes",
      "details" => %{"base" => "develop"}
    }

    flow = c.runner.flows["issue"]
    now = AtlasFlow.Runs.Clock.now(c.clock)

    assert {:ok, unchanged} =
             Run.effect_result(publishing, flow, FakeFacts.get("issue", @key), now, reply)

    assert unchanged["state"] == "unchanged"
    assert flow.owner("unchanged")["default"] == %{"kind" => "person", "config" => "decider"}

    assert Enum.any?(
             unchanged["pending"]["writes"],
             &(&1["content"]["values"]["publication"] == "no_changes")
           )
  end

  @url "https://github.com/mimbre/atlas/pull/9"
  @red "unit: test/readme_test.exs:3\n    Assertion with == failed: the typo is back"

  test "red CI leads to a fix of what failed, pushed onto the same pull request; green is merging",
       c do
    publishing = published(c)
    assert publishing["state"] == "checking"
    assert FakeFacts.get("issue", @key)["values"]["pr_url"] == @url
    assert FakeFacts.get("issue", @key)["values"]["pr_checks"] == "pending"

    # rela's GitHub sync: the checks of its head failed.
    sync(%{"pr_checks" => "failure", "pr_checks_failure" => @red})
    assert intent(c)["state"] == "ci_fixing"

    # The fix works on the latest result with what failed, not the review's findings.
    {_, work} = leased = lease!()
    assert work.instructions =~ "## What to fix\n\n" <> @red
    refute work.instructions =~ "Name it better."
    finish(lease: leased, answer: "Fixed the README test.")

    # Code pushes its result onto the pull request it opened: the same url.
    assert until(c, "checking")["pending"]["tasks"] |> Enum.map(& &1["task_kind"]) ==
             ~w(author review fix)

    assert_received {:published, %{"name" => "push", "input" => input}}
    assert input["pull"] == @url
    assert input["result"] == "refs/atlas/results/TK-IS-Atlas-01-3"

    # Entering it again fences the red of the head before the push.
    assert FakeFacts.get("issue", @key)["values"]["pr_checks"] == "pending"
    assert FakeFacts.get("issue", @key)["values"]["pr_url"] == @url

    # Green, but GitHub has not said yet whether it merges: not its supervisor's yet.
    sync(%{"pr_checks" => "success"})
    assert settle(c)["state"] == "checking"

    sync(%{"pr_checks" => "success", "pr_mergeable" => "clean"})
    assert until(c, "merging")["state"] == "merging"

    # Red at Merge it (a rerun, a push) takes it back to the CI gate.
    sync(%{"pr_checks" => "failure", "pr_checks_failure" => @red})
    assert until(c, "checking")["state"] == "checking"
  end

  test "conflicting with develop: an update resolves develop merged into it, pushed onto the same pull request; once only",
       c do
    published(c)

    # The update's work, ended: its result pushed onto the pull request.
    update = fn task ->
      finish(answer: "Resolved the README.")

      FakeCode.put(c.code, @repository, "refs/atlas/results/" <> task, "rev_#{task}", %{
        "README.md" => "# Atlas!\n"
      })

      assert until(c, "checking")["state"] == "checking"
      assert_received {:published, %{"name" => "update", "input" => input}}
      assert input["pull"] == @url
      assert input["result"] == "refs/atlas/results/" <> task
    end

    # Green but conflicting: never its supervisor's; an update first.
    FakeCode.put(c.code, @repository, "refs/atlas/updates/9/develop", "rev_merge", %{
      "README.md" => "<<<<<<< ours\n# Atlas\n=======\n# Atlas!\n>>>>>>> theirs\n"
    })

    sync(%{"pr_checks" => "success", "pr_mergeable" => "conflicting"})
    assert intent(c)["state"] == "updating"
    update.(@fix)

    values = FakeFacts.get("issue", @key)["values"]
    assert values["pr_mergeable"] == "unknown"
    assert values["pr_updates"] == "one"

    sync(%{"pr_checks" => "success", "pr_mergeable" => "clean"})
    assert until(c, "merging")["state"] == "merging"
    assert FakeFacts.get("issue", @key)["values"]["pr_updates"] == "none"

    # develop moved on: conflicting at Merge it takes it away, for a new update.
    sync(%{"pr_mergeable" => "conflicting"})
    assert until(c, "checking")["state"] == "checking"
    sync(%{"pr_mergeable" => "conflicting"})
    assert intent(c)["state"] == "updating"
    update.("TK-IS-Atlas-01-4")

    # Still conflicting after its update: its supervisor decides.
    sync(%{"pr_mergeable" => "conflicting"})
    failing = until(c, "update_failing")
    assert failing["pending"]["task"] == nil

    assert c.runner.flows["issue"].owner("update_failing")["default"] == %{
             "kind" => "person",
             "config" => "decider"
           }

    # Updated by hand: mergeable and green goes to its supervisor to merge.
    sync(%{"pr_mergeable" => "clean", "pr_checks" => "success"})
    assert until(c, "checking")["state"] == "checking"
    sync(%{"pr_mergeable" => "clean", "pr_checks" => "success"})
    assert until(c, "merging")["state"] == "merging"
  end

  test "still red after two CI fixes: its supervisor decides, with what failed", c do
    published(c)

    for {state, task} <- [ci_fixing: @fix, ci_fixing_again: "TK-IS-Atlas-01-4"] do
      sync(%{"pr_checks" => "failure", "pr_checks_failure" => @red})
      assert intent(c)["state"] == to_string(state)
      finish(answer: "Tried.")

      FakeCode.put(c.code, @repository, "refs/atlas/results/" <> task, "rev_#{task}", %{
        "README.md" => "# Atlas\n"
      })

      assert until(c, "checking")["state"] == "checking"
    end

    sync(%{"pr_checks" => "failure", "pr_checks_failure" => @red})
    failing = until(c, "ci_failing")

    assert c.runner.flows["issue"].owner("ci_failing")["default"] == %{
             "kind" => "person",
             "config" => "decider"
           }

    assert failing["pending"]["task"] == nil

    # Fixed by hand: green goes to its supervisor to merge.
    sync(%{"pr_checks" => "success", "pr_mergeable" => "clean"})
    assert until(c, "merging")["state"] == "merging"
  end

  # No item gets stuck (IS-Atlas-60): an agent task that ends without a result keeps the
  # issue with its supervisor, who is told why and may retry that step.
  test "a failed author goes to its supervisor with why; Retry builds it again on a fresh base and it goes on to Reviewing",
       c do
    started(c)
    {_, first} = leased = lease!()
    finish(lease: leased, kind: :failed, reason: "time_limit")

    stuck = until(c, "stuck")
    assert stuck["status"] == "active"
    assert stuck["supervised_by"] == "ada"
    assert stuck["pending"]["task"] == nil

    # Why, on the issue: which task, where, how it ended and its reason.
    values = FakeFacts.get("issue", @key)["values"]
    assert values["retry_step"] == "author"

    assert values["task_failure"] ==
             "The author task #{@author} (in working) ended stuck: time_limit."

    assert values["gate_result"] == "none"

    # Its supervisor's, with Retry and Close.
    assert owner(c, stuck) == "ada"
    assert answers("stuck") == ["Retry", "Close it"]

    # develop moved meanwhile: Retry leases a new author on a fresh base of it.
    FakeCode.put(c.code, @repository, "develop", "rev_3", %{"README.md" => "# Atlas 3\n"})
    ManualClock.advance(elem(c.clock, 1), 60_000)
    decide("retry")
    working = intent(c)
    assert working["state"] == "working"
    assert %{"key" => @review} = working["pending"]["task"]
    {_, again} = leased = lease!()
    refute again.input.base.base_id == first.input.base.base_id
    finish(lease: leased, answer: "Done.")

    FakeCode.put(c.code, @repository, "refs/atlas/results/" <> @review, "rev_4", %{
      "README.md" => "# Atlas 3\n\nChanged.\n"
    })

    # It goes on to Reviewing, on the new author's result.
    reviewing = intent(c)
    assert reviewing["state"] == "reviewing"
    {:ok, base} = Bases.cached(@repository, "refs/atlas/results/" <> @review)
    assert reviewing["pending"]["task"]["work"]["input"]["base"]["base_id"] == base.base_id
    assert FakeFacts.get("issue", @key)["values"]["task_failure"] == "none"
  end

  # A silent turn is ended (UC-Atlas-03): an agent whose Runtime stops answering loses its
  # lease once it runs out; that ends its attempt. The first silence starts the same task
  # once more on a fresh attempt, with nobody asked; the second in a row goes to its
  # supervisor, with why and Retry.
  test "a silent author is started once more on a fresh attempt; silent again, it goes to its supervisor with why and Retry",
       c do
    started(c)
    {first, _} = lease!()
    run(first)

    # Its Runtime stops answering: the lease runs out and is lost, and its attempt ends.
    silent(c)
    assert %{"state" => "lost", "result_kind" => "expired"} = attempt(1)

    # Started once more on its own: the same task, nobody asked, the count in its run.
    again = settle(c)
    assert {again["state"], again["status"]} == {"working", "active"}
    assert %{"key" => @author, "retried" => [1]} = again["pending"]["task"]
    assert again["pending"]["tasks"] in [nil, []]
    assert FakeFacts.get("issue", @key)["values"]["task_failure"] == "none"

    # On a fresh attempt: a new lease and a new task_attempt, the first one kept as it was.
    {second, _} = lease!()
    refute second == first
    assert FakeFacts.get("task", @author)["values"]["attempt"] == 2
    run(second)
    assert %{"state" => "running"} = attempt(2)
    assert %{"state" => "lost", "result_kind" => "expired"} = attempt(1)

    # Silent again: the task ends abandoned, and its supervisor decides, told why.
    silent(c)
    stuck = until(c, "stuck")
    assert {stuck["status"], stuck["supervised_by"]} == {"active", "ada"}

    assert [%{"key" => @author, "outcome" => "abandoned", "attempt" => 2}] =
             stuck["pending"]["tasks"]

    assert FakeFacts.get("task", @author)["values"]["state"] == "abandoned"

    assert FakeFacts.get("issue", @key)["values"]["task_failure"] ==
             "The author task #{@author} (in working) ended abandoned: its agent went silent twice."

    assert owner(c, stuck) == "ada"
    assert answers("stuck") == ["Retry", "Close it"]

    # No third attempt is offered on its own.
    assert {:polled, %{leases: []}} = WorkSource.poll(@mini, L.poll_input("mac-mini", [], @offer))
    assert FakeFacts.get("task", @author)["values"]["attempt"] == 2

    # Retry builds it again: a fresh task, whose count starts anew.
    decide("retry")
    working = intent(c)
    assert working["state"] == "working"
    assert %{"key" => @review} = working["pending"]["task"]
    refute Map.has_key?(working["pending"]["task"], "retried")
  end

  test "a Flow restart between two silences neither resets nor doubles the count", c do
    started(c)
    {first, _} = lease!()
    run(first)
    silent(c)

    # Flow restarts before it saw the silence, and reconciles more than once after it.
    restart(c)
    settle(c)
    assert %{"retried" => [1]} = reconcile(c)["pending"]["task"]
    assert %{"retried" => [1]} = reconcile(c)["pending"]["task"]

    {second, _} = lease!()
    run(second)

    # Flow restarts again while the second attempt runs: the count is the run's, in Facts.
    restart(c)
    assert %{"key" => @author, "retried" => [1]} = reconcile(c)["pending"]["task"]

    assert {:polled, %{lease_lost: []}} =
             WorkSource.poll(@mini, L.poll_input("mac-mini", [second], %{}))

    # The second silence is the second: its supervisor decides.
    silent(c)
    restart(c)
    assert until(c, "stuck")["pending"]["tasks"] |> Enum.map(& &1["attempt"]) == [2]

    assert FakeFacts.get("issue", @key)["values"]["task_failure"] =~
             "its agent went silent twice"
  end

  test "a silent review is started once more; silent again, it goes to its supervisor with Retry",
       c do
    started(c)
    finish(answer: "Done.")
    author_result(c)
    assert intent(c)["state"] == "reviewing"

    {first, _} = lease!()
    run(first)
    silent(c)
    assert %{"key" => @review, "retried" => [1]} = settle(c)["pending"]["task"]

    {second, _} = lease!()
    run(second)
    silent(c)
    failed = until(c, "review_stuck")
    assert owner(c, failed) == "ada"
    assert answers("review_stuck") == ["Retry", "Publish without review", "Close it"]

    assert FakeFacts.get("issue", @key)["values"]["task_failure"] ==
             "The review task #{@review} (in reviewing) ended abandoned: its agent went silent twice."
  end

  test "a turn that crashes with no answer and no result is empty: started once more, then its supervisor decides",
       c do
    started(c)
    finish(kind: :crashed)
    assert %{"key" => @author, "retried" => [1]} = settle(c)["pending"]["task"]
    assert FakeFacts.get("issue", @key)["values"]["task_failure"] == "none"

    finish(kind: :crashed)
    until(c, "stuck")

    assert FakeFacts.get("issue", @key)["values"]["task_failure"] ==
             "The author task #{@author} (in working) ended abandoned: its agent went silent twice."
  end

  test "a failed review goes to its supervisor; Retry reviews the author's result again", c do
    review_failed(c)
    decide("retry")
    again = intent(c)
    assert again["state"] == "reviewing"
    assert %{"key" => @fix} = again["pending"]["task"]
    {:ok, base} = Bases.cached(@repository, "refs/atlas/results/" <> @author)
    assert again["pending"]["task"]["work"]["input"]["base"]["base_id"] == base.base_id
  end

  test "a failed review: Publish without review opens its pull request from the author's result, with no review",
       c do
    code_answers()
    review_failed(c)
    decide("publish")
    assert until(c, "checking")["state"] == "checking"
    assert_received {:published, %{"name" => "publish", "input" => input}}
    assert input["result"] == "refs/atlas/results/" <> @author
    refute Map.has_key?(input, "review")
    refute Map.has_key?(input, "fix")
  end

  test "a failed fix goes back to Fixing on Retry, on the author's result with the review's findings",
       c do
    started(c)
    finish(answer: "Done.")
    author_result(c)
    assert intent(c)["state"] == "reviewing"
    finish(answer: verdict("changes_required", ["A second typo."], []))
    assert intent(c)["state"] == "fixing"
    finish(kind: :failed, reason: "time_limit")
    until(c, "stuck")
    assert FakeFacts.get("issue", @key)["values"]["retry_step"] == "fix"

    decide("retry")
    fixing = intent(c)
    assert fixing["state"] == "fixing"
    assert %{"key" => "TK-IS-Atlas-01-4"} = task = fixing["pending"]["task"]
    {:ok, base} = Bases.cached(@repository, "refs/atlas/results/" <> @author)
    assert task["work"]["input"]["base"]["base_id"] == base.base_id
    assert task["work"]["instructions"] =~ "A second typo."
  end

  test "a failed CI fix, and a failed second one, each go back to their own state on Retry", c do
    published(c)

    for {state, step, n} <- [{"ci_fixing", "ci_fix", 4}, {"ci_fixing_again", "ci_fix_again", 6}] do
      sync(%{"pr_checks" => "failure", "pr_checks_failure" => @red})
      assert intent(c)["state"] == state
      finish(kind: :failed, reason: "time_limit")
      until(c, "stuck")
      assert FakeFacts.get("issue", @key)["values"]["retry_step"] == step

      decide("retry")
      retried = intent(c)
      assert retried["state"] == state
      assert retried["pending"]["task"]["key"] == "TK-IS-Atlas-01-#{n}"
      assert retried["pending"]["task"]["work"]["instructions"] =~ @red
      finish(answer: "Fixed.")

      FakeCode.put(c.code, @repository, "refs/atlas/results/TK-IS-Atlas-01-#{n}", "rev_#{n}", %{
        "README.md" => "# Atlas\n"
      })

      assert until(c, "checking")["state"] == "checking"
      assert_received {:published, %{"name" => "push", "input" => input}}
      assert input["result"] == "refs/atlas/results/TK-IS-Atlas-01-#{n}"
    end

    # Red a third time after its two fixes: its supervisor decides, as before.
    sync(%{"pr_checks" => "failure", "pr_checks_failure" => @red})
    assert until(c, "ci_failing")["state"] == "ci_failing"
  end

  # Nothing to merge (IS-Atlas-63): its agent changed nothing, so Code opened no pull
  # request. Its supervisor may build it again: a new author on a fresh base of develop.
  test "Nothing to merge: Build it again starts a new author on a fresh base of develop", c do
    first = unchanged(c)
    assert answers("unchanged") == ["Build it again", "Close it"]
    assert owner(c, until(c, "unchanged")) == "ada"

    # develop moved meanwhile: the new author's base is a fresh one of it.
    FakeCode.put(c.code, @repository, "develop", "rev_3", %{"README.md" => "# Atlas 3\n"})
    ManualClock.advance(elem(c.clock, 1), 60_000)
    decide("rebuild")
    working = intent(c)
    assert {working["state"], working["status"]} == {"working", "active"}
    assert working["supervised_by"] == "ada"
    assert %{"key" => @fix} = working["pending"]["task"]
    assert FakeFacts.get("task", @fix)["values"]["kind"] == "author"
    {_, again} = leased = lease!()
    refute again.input.base.base_id == first.input.base.base_id
    assert again.input.result_ref == "refs/atlas/results/" <> @fix

    values = FakeFacts.get("issue", @key)["values"]
    assert {values["retry_step"], values["task_failure"]} == {"author", "none"}

    # Its new author's result goes on to Reviewing, as any author's.
    finish(lease: leased, answer: "Done.")

    FakeCode.put(c.code, @repository, "refs/atlas/results/" <> @fix, "rev_4", %{
      "README.md" => "# Atlas 3\n\nChanged.\n"
    })

    assert intent(c)["state"] == "reviewing"
  end

  test "Nothing to merge: Close it ends it", c do
    unchanged(c)
    decide("close")
    assert until(c, "done")["status"] == "completed"
  end

  test "Close ends a stuck issue", c do
    started(c)
    finish(kind: :failed, reason: "time_limit")
    until(c, "stuck")
    decide("close")
    assert until(c, "done")["status"] == "completed"
  end

  test "Close ends an issue whose review failed", c do
    review_failed(c)
    decide("close")
    assert until(c, "done")["status"] == "completed"
  end

  # Its pull request closed on GitHub without merging (IS-Atlas-11, IS-Atlas-119): its
  # supervisor decides, with Build it again and Close it.
  @waiting ~w(checking ci_fixing ci_fixing_again ci_pushing ci_failing updating update_pushing update_failing merging)

  test "closed while waiting for its CI: its supervisor decides; Build it again opens a new pull request",
       c do
    published(c)
    assert_received {:published, %{"name" => "publish"}}
    sync(%{"pr_state" => "closed", "pr_checks" => "failure", "pr_checks_failure" => @red})
    closed = until(c, "pr_closed")
    assert {closed["status"], closed["supervised_by"]} == {"active", "ada"}
    assert owner(c, closed) == "ada"
    assert closed["pending"]["task"] == nil
    assert answers("pr_closed") == ["Build it again", "Close it"]

    # A fresh author on a fresh base of develop.
    decide("rebuild")
    working = intent(c)
    assert {working["state"], working["supervised_by"]} == {"working", "ada"}
    assert %{"key" => @fix} = working["pending"]["task"]
    assert FakeFacts.get("task", @fix)["values"]["kind"] == "author"
    finish(answer: "Done again.")

    FakeCode.put(c.code, @repository, "refs/atlas/results/" <> @fix, "rev_5", %{
      "README.md" => "# Atlas\n\nChanged again.\n"
    })

    assert intent(c)["state"] == "reviewing"
    finish(answer: verdict("approved", [], []))

    # Its new pull request: the old one's closed is not taken for it, and its counts start
    # again.
    assert until(c, "checking")["state"] == "checking"
    assert_received {:published, %{"name" => "publish", "input" => %{"result" => result}}}
    assert result == "refs/atlas/results/" <> @fix
    values = FakeFacts.get("issue", @key)["values"]

    assert {values["pr_state"], values["ci_fixes"], values["pr_updates"]} ==
             {"open", "none", "none"}

    assert settle(c)["state"] == "checking"
  end

  test "closed while its CI fix runs: the fix is cancelled and its supervisor decides; Close it ends it",
       c do
    published(c)
    sync(%{"pr_checks" => "failure", "pr_checks_failure" => @red})
    assert %{"key" => @fix} = intent(c)["pending"]["task"]
    {lease, _} = lease!()
    run(lease)

    sync(%{"pr_state" => "closed"})
    closed = until(c, "pr_closed")
    assert closed["pending"]["task"] == nil
    assert FakeFacts.get("task", @fix)["values"]["state"] == "cancelled"

    # Its Runtime is told on its next poll; its late result is never taken.
    Dispatch.sweep()
    assert FakeFacts.get("task", @fix)["values"]["lease_state"] == "cancel_requested"

    decide("close")
    assert until(c, "done")["status"] == "completed"
  end

  test "closed at Merge it: its supervisor decides; reopened on GitHub, it waits for its CI again",
       c do
    published(c)
    sync(%{"pr_checks" => "success", "pr_mergeable" => "clean"})
    assert until(c, "merging")["state"] == "merging"

    sync(%{"pr_state" => "closed"})
    assert until(c, "pr_closed")["state"] == "pr_closed"

    sync(%{"pr_state" => "open"})
    assert until(c, "checking")["state"] == "checking"
  end

  # Every state that waits on its pull request, as Flow moves it: a task's state by its
  # plain branches (its task cancelled), an effect's before Code is asked, any other by its
  # branches. Closed outranks what would move it on otherwise (green and mergeable, red).
  test "closed in every state that waits on its pull request leads to its supervisor", c do
    flow = c.runner.flows["issue"]

    subject = %{
      "key" => @key,
      "version" => 9,
      "values" => %{
        "pr_state" => "closed",
        "pr_checks" => "success",
        "pr_mergeable" => "clean",
        "ci_fixes" => "one"
      }
    }

    task = %{"key" => "TK-IS-Atlas-01-9"}

    for state <- @waiting do
      moved =
        case flow.mechanism(state) do
          {:task, _} ->
            assert {:ok, run, ^task} =
                     Run.unheld(
                       put_in(waiting(state), ["pending", "task"], task),
                       flow,
                       subject,
                       @now
                     )

            run

          {:effect, _} ->
            assert {:ok, run} = Run.unfrozen(waiting(state), flow, subject, @now)
            run

          nil ->
            assert {:ok, run} = Run.step(waiting(state), flow, subject, @now)
            run
        end

      assert {state, moved["state"], moved["status"]} == {state, "pr_closed", "active"}
      assert moved["pending"]["task"] == nil
    end

    # Open, nothing moves a task's state by a plain branch.
    open = put_in(subject, ["values", "pr_state"], "open")
    assert Run.unheld(waiting("ci_fixing"), flow, open, @now) == :stay
  end

  # A change merged elsewhere (IS-Atlas-34): a merged pull request linked to the issue by
  # hand (`in_issue`), or one that also did it (`done_in`), completes it as Facts derives
  # it, and its run goes to Done.
  test "a merged pull request linked to it while its author runs: Done, its author cancelled",
       c do
    started(c)
    {lease, _} = lease!()
    run(lease)

    url = "https://github.com/mimbre/atlas/pull/436"
    pr = "PR-mimbre-atlas-436"

    FakeFacts.put("pull_request", %{
      "key" => pr,
      "values" => %{"url" => url, "state" => "merged"},
      "links" => %{"in_issue" => [@key]}
    })

    # Facts wires the issue completed on a read with its progress, never on a plain one.
    completed(%{"over" => "in_issue", "key" => pr, "field" => "state", "value" => "merged"})
    done = until(c, "done")
    assert done["status"] == "completed"
    assert FakeFacts.get("task", @author)["values"]["state"] == "cancelled"
  end

  test "a merged pull request that also did it ends a stuck issue", c do
    started(c)
    finish(kind: :failed, reason: "time_limit")
    assert until(c, "stuck")["state"] == "stuck"

    completed(%{
      "through" => "done_in",
      "key" => "PR-mimbre-atlas-437",
      "field" => "state",
      "value" => "merged"
    })

    assert until(c, "done")["status"] == "completed"
  end

  test "a completed issue's run goes to Done from every open state", c do
    flow = c.runner.flows["issue"]
    assert c.runner.config["selection"]["issue"]["completed"] == "done"

    subject = %{
      "key" => @key,
      "version" => 9,
      "values" => %{},
      "completion" => %{"done" => true, "over" => "in_issue", "key" => "PR-x"}
    }

    task = %{"key" => "TK-IS-Atlas-01-9"}

    for state <- flow.states(), not flow.final?(state) do
      run = put_in(waiting(state), ["pending", "task"], task)
      assert {:ok, done, ^task} = Run.completed(run, flow, subject, "done", @now)
      assert {state, done["state"], done["status"]} == {state, "done", "completed"}
    end

    # Not completed, nothing ends it; a push Code was asked for is answered first.
    assert Run.completed(
             waiting("working"),
             flow,
             Map.delete(subject, "completion"),
             "done",
             @now
           ) ==
             :stay

    asked = put_in(waiting("ci_pushing"), ["pending", "effect"], %{"id" => "e"})
    assert Run.completed(asked, flow, subject, "done", @now) == :stay
  end

  # A run of the issue active in `state`, its entry's writes acknowledged.
  defp waiting(state),
    do: %{
      "key" => Run.key("issue", "issue", @key, 1),
      "flow" => "issue",
      "subject_kind" => "issue",
      "subject_key" => @key,
      "generation" => 1,
      "entry" => 4,
      "state" => state,
      "status" => "active",
      "entered_at" => DateTime.to_iso8601(@now),
      "input_cursor" => 0,
      "last_input" => %{"version" => 1},
      "blocked_reason" => "",
      "pending" => %{"version" => 1, "writes" => []},
      "deadlines" => %{"version" => 1, "timers" => []}
    }

  # The issue completed, as Facts derives it (`why`, the way that holds).
  defp completed(why) do
    fact = FakeFacts.get("issue", @key)

    FakeFacts.put(
      "issue",
      Map.merge(fact, %{
        "completion" => Map.put(why, "done", true),
        "version" => (fact["version"] || 1) + 1
      })
    )
  end

  # The issue picked up by ada, its author task made.
  defp started(c) do
    issue()
    reconcile(c)
    assert_receive {:reconcile, "issue", @key}, 2_000
    supervise(c, "ada")
    assert %{"key" => @author} = reconcile(c)["pending"]["task"]
  end

  defp author_result(c) do
    FakeCode.put(c.code, @repository, "refs/atlas/results/" <> @author, "rev_2", %{
      "README.md" => "# Atlas\n\nChanged.\n"
    })
  end

  # Its author done, its review ended without a result: with its supervisor, who is told.
  defp review_failed(c) do
    started(c)
    finish(answer: "Done.")
    author_result(c)
    assert intent(c)["state"] == "reviewing"
    finish(kind: :failed, reason: "time_limit")
    failed = until(c, "review_stuck")
    assert failed["supervised_by"] == "ada"
    assert owner(c, failed) == "ada"
    assert answers("review_stuck") == ["Retry", "Publish without review", "Close it"]

    assert FakeFacts.get("issue", @key)["values"]["task_failure"] ==
             "The review task #{@review} (in reviewing) ended stuck: time_limit."
  end

  # Its author and review done, Code refused its publication `no_changes`: with its
  # supervisor in Nothing to merge. The author's lease's work, as it was leased.
  defp unchanged(c) do
    refuse_no_changes()
    started(c)
    {_, work} = leased = lease!()
    finish(lease: leased, answer: "Done.")
    author_result(c)
    assert intent(c)["state"] == "reviewing"
    finish(answer: verdict("approved", [], []))
    unchanged = until(c, "unchanged")
    assert {unchanged["status"], unchanged["supervised_by"]} == {"active", "ada"}
    assert unchanged["pending"]["task"] == nil
    assert FakeFacts.get("issue", @key)["values"]["publication"] == "no_changes"
    work
  end

  # Code's effect receiver on the Bus, refusing every publication `no_changes`.
  defp refuse_no_changes do
    test = self()

    spawn_link(fn ->
      :ok = AtlasBus.attach("code/effects")
      send(test, :attached)
      refuse(test)
    end)

    assert_receive :attached
  end

  defp refuse(test) do
    receive do
      {:atlas_bus, %AtlasBus.Envelope{class: "request"} = e, %{"request" => r} = body} ->
        send(test, {:published, r})

        AtlasBus.send(AtlasBus.Envelope.reply(e, "answer"), %{
          "version" => 1,
          "id" => r["id"],
          "digest" => body["digest"],
          "fingerprint" => r["fingerprint"],
          "status" => "refused",
          "reason" => "no_changes",
          "details" => %{"base" => "develop"}
        })
    end

    refuse(test)
  end

  # The lease accepted and started on the mac-mini: its attempt runs.
  defp run(lease) do
    report = &WorkSource.report(@mini, %{lease_id: lease, revision: &1, report: &2})
    assert {:recorded, _} = report.(1, %{state: :accepted})
    assert {:recorded, _} = report.(2, %{state: :started})
  end

  # Its Runtime answers no more: past its lease (900 s) Dispatch's sweep fences it expired,
  # and past the grace (120 s) lost; Delivery ends its running attempt.
  defp silent(c) do
    ManualClock.advance(elem(c.clock, 1), 900_000)
    Dispatch.sweep()
    ManualClock.advance(elem(c.clock, 1), 120_000)
    Dispatch.sweep()
    :sys.get_state(Delivery)
    task = FakeFacts.get("task", @author)["values"]["lease_state"]
    review = (FakeFacts.get("task", @review) || %{"values" => %{}})["values"]["lease_state"]
    assert "lost" in [task, review]
  end

  defp attempt(n), do: FakeFacts.get("task_attempt", "TA-#{@author}-#{n}")["values"]

  # Every process of Flow's work source stops and starts again: what they knew is in
  # Facts only.
  defp restart(c) do
    for id <- [Delivery, Dispatch, Bases], do: stop_supervised!(id)
    start_supervised!({Bases, client: FakeCode.client(c.code), clock: c.clock})

    start_supervised!(
      {Dispatch,
       model: Model.AtlasEyra,
       actors: @actors,
       clock: c.clock,
       poll_wait: 0,
       sweep_ms: nil,
       resync_ms: nil}
    )

    start_supervised!(
      {Delivery, model: Model.AtlasEyra, actors: @actors, clock: c.clock, engine: self()}
    )

    :ok
  end

  # Its supervisor's answer, as the Console writes it.
  defp decide(value), do: sync(%{"gate_result" => value})

  # Who owns the run in its state, as the projection resolves it: the configured decider,
  # which inside the span is the run's supervisor (a holder of the supervision relation).
  defp owner(c, run) do
    supervision = c.runner.config["supervision"]
    [holder] = supervision["holders"]
    default = c.runner.flows["issue"].owner(run["state"])["default"]
    supervisor = Map.new([{"kind", holder}, {"key", run["supervised_by"]}])

    owner =
      AtlasFlow.Model.owner(default, %{"decider" => %{"key" => "someone"}}, %{
        "state" => run["state"],
        "spans" => supervision["spans"]["issue"],
        "supervised_by" => supervisor
      })

    assert owner["kind"] == holder
    owner["key"]
  end

  # The labels of the answers `state` offers its owner, as the test environment's flows.json has them.
  defp answers(state) do
    gates = Model.AtlasEyra.__rela__(:gates)
    flow = RelaDSL.Flow.Subflow.definitions(Model.AtlasEyra.__flows__(), gates, :test)["issue"]
    for a <- flow["states"][state]["present"]["todo"]["answers"] || [], do: a["label"]
  end

  # The issue built, its review approving it, and Code's pull request opened (Code
  # answering every publication done, on @url): the run as it waits for CI.
  defp published(c) do
    code_answers()
    FakeFacts.put("person", %{"key" => "someone"})
    issue()
    reconcile(c)
    assert_receive {:reconcile, "issue", @key}, 2_000
    supervise(c, "ada")
    assert %{"key" => @author} = reconcile(c)["pending"]["task"]
    finish(answer: "Done.")

    FakeCode.put(c.code, @repository, "refs/atlas/results/" <> @author, "rev_2", %{
      "README.md" => "# Atlas\n\nChanged.\n"
    })

    assert intent(c)["state"] == "reviewing"
    finish(answer: verdict("approved", ["Name it better."], []))
    until(c, "checking")
  end

  # rela's GitHub sync writing the issue's pull request fields.
  defp sync(values) do
    fact = FakeFacts.get("issue", @key)

    FakeFacts.put(
      "issue",
      Map.merge(fact, %{
        "values" => Map.merge(fact["values"], values),
        "version" => (fact["version"] || 1) + 1
      })
    )
  end

  # Code's effect receiver on the Bus: every request done, on @url; each one sent to the test.
  defp code_answers do
    test = self()

    spawn_link(fn ->
      :ok = AtlasBus.attach("code/effects")
      send(test, :attached)
      answer(test)
    end)

    assert_receive :attached
  end

  defp answer(test) do
    receive do
      {:atlas_bus, %AtlasBus.Envelope{class: "request"} = e, %{"request" => r} = body} ->
        send(test, {:published, r})

        AtlasBus.send(AtlasBus.Envelope.reply(e, "answer"), %{
          "version" => 1,
          "id" => r["id"],
          "digest" => body["digest"],
          "fingerprint" => r["fingerprint"],
          "status" => "done",
          "reference" => @url,
          "outputs" => %{"url" => @url}
        })
    end

    answer(test)
  end

  # Reconciles until the run holds a task's intent, and returns it; between tries it waits
  # for Flow's next reconcile request, as Code's answers and Facts' writes arrive.
  defp intent(c, rounds \\ 50) do
    run = reconcile(c)

    cond do
      run["pending"]["task"] != nil -> run
      rounds == 0 -> flunk("no task in #{run["state"]}")
      true -> next_reconcile() && intent(c, rounds - 1)
    end
  end

  # Reconciles until the run is in `state`, as Code's answers and Facts' writes arrive.
  defp until(c, state, rounds \\ 50) do
    run = reconcile(c)

    cond do
      run["state"] == state and run["pending"]["writes"] == [] -> run
      rounds == 0 -> flunk("run in #{run["state"]}, not #{state}")
      true -> next_reconcile() && until(c, state, rounds - 1)
    end
  end

  defp next_reconcile do
    receive do
      {:reconcile, "issue", @key} -> true
      {:"$gen_cast", {:reconcile, "issue", @key}} -> true
    after
      30_000 -> flunk("no reconcile of #{@key}")
    end
  end

  defp issue do
    FakeFacts.put("scene", %{"key" => "SC-Atlas-01", "values" => %{"title" => "Newcomers"}})

    FakeFacts.put("use_case", %{
      "key" => "UC-Atlas-01",
      "values" => %{"title" => "Read the README", "description" => "People read the README."},
      "links" => %{"in_scene" => ["SC-Atlas-01"]}
    })

    FakeFacts.put("issue", %{
      "key" => @key,
      "values" => %{"title" => "Fix the README", "description" => "One typo."},
      "links" => %{"assignment" => ["AS-" <> @key], "in_use_case" => ["UC-Atlas-01"]}
    })

    FakeFacts.put("assignment", %{
      "key" => "AS-" <> @key,
      "values" => %{"of" => @key},
      "links" => %{"assigned_to" => ["mac-mini"]},
      "origins" => %{"assigned_to" => %{"by" => "ada", "position" => 1}}
    })
  end

  # The issue's run supervised by `supervisor`, as a pickup writes it.
  defp supervise(c, supervisor) do
    kind = c.runner.config["kind"]
    fact = FakeFacts.get(kind, Run.key("issue", "issue", @key, 1))
    relation = c.runner.config["supervision"]["relation"]
    links = Map.put(fact["links"] || %{}, relation, [supervisor])
    FakeFacts.put(kind, Map.merge(fact, %{"links" => links, "version" => fact["version"] + 1}))
  end

  # The mac-mini's one lease of the issue.
  defp lease! do
    assert {:polled, %{leases: [%{lease_id: lease, work: work}]}} =
             WorkSource.poll(@mini, L.poll_input("mac-mini", [], @offer))

    {lease, work}
  end

  # The issue's lease worked to its end with `answer`, no change set (its result went over Git).
  defp finish(opts) do
    {lease, _work} = Keyword.get_lazy(opts, :lease, &lease!/0)
    report = &WorkSource.report(@mini, %{lease_id: lease, revision: &1, report: &2})
    assert {:recorded, _} = report.(1, %{state: :accepted})
    assert {:recorded, _} = report.(2, %{state: :started})

    assert {:recorded, _} =
             report.(3, L.ended(nil, Keyword.take(opts, [:answer, :kind, :reason])))

    assert_receive {:"$gen_cast", {:reconcile, "issue", @key}}, 2_000
  end

  defp verdict(verdict, findings, follow_ups),
    do:
      "I looked at it.\n\n```json\n" <>
        JSON.encode!(%{"verdict" => verdict, "findings" => findings, "follow_ups" => follow_ups}) <>
        "\n```\n"

  # Reconciles until the run holds an intent or rests.
  defp settle(c, rounds \\ 4) do
    run = reconcile(c)

    cond do
      run["pending"]["task"] != nil or rounds == 0 -> run
      run == reconcile(c) -> run
      true -> settle(c, rounds - 1)
    end
  end

  defp reconcile(c) do
    config = c.runner.config
    flows = c.runner.flows
    {:ok, %{runs: known}} = Store.plan(config, flows)
    now = AtlasFlow.Runs.Clock.now(c.clock)
    {:ok, runs} = Store.reconcile_subjects(config, flows, now, known, [{"issue", @key}])
    assert [run] = Enum.filter(runs, &(&1["subject_key"] == @key and &1["flow"] == "issue"))
    run
  end
end
