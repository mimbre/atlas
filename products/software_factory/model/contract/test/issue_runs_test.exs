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

  test "a review that asks for changes leads to one fix on the result, which is published",
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

    finish(lease: leased, answer: verdict("changes_required", ["A second typo."]))
    assert settle(c)["state"] == "fixing"
    assert FakeFacts.get("task", @review)["values"]["verdict"] == "changes_required"
    assert FakeFacts.get("task", @review)["values"]["state"] == "completed"

    # One fix on the author's result (the base the review had), with the review's findings.
    fixing = settle(c)
    assert %{"key" => @fix} = intent = fixing["pending"]["task"]
    assert intent["work"]["input"]["base"]["base_id"] == base.base_id
    assert reconcile(c)["state"] == "fixing"
    {_, work} = leased = lease!()
    assert work.profile == "deep_coding"
    assert work.input.result_ref == "refs/atlas/results/" <> @fix
    assert work.instructions =~ "A second typo."

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
    assert {:recorded, _} = report.(3, L.ended(nil, Keyword.take(opts, [:answer])))
    assert_receive {:"$gen_cast", {:reconcile, "issue", @key}}, 2_000
  end

  defp verdict(verdict, findings),
    do:
      "I looked at it.\n\n```json\n" <>
        JSON.encode!(%{"verdict" => verdict, "findings" => findings}) <> "\n```\n"

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
