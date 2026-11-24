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

    sync(%{"pr_checks" => "success"})
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
    sync(%{"pr_checks" => "success"})
    assert until(c, "merging")["state"] == "merging"
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

  # Reconciles until the run holds a task's intent, and returns it.
  defp intent(c, rounds \\ 50) do
    run = reconcile(c)

    cond do
      run["pending"]["task"] != nil -> run
      rounds == 0 -> flunk("no task in #{run["state"]}")
      true -> Process.sleep(10) && intent(c, rounds - 1)
    end
  end

  # Reconciles until the run is in `state`, as Code's answers and Facts' writes arrive.
  defp until(c, state, rounds \\ 50) do
    run = reconcile(c)

    cond do
      run["state"] == state and run["pending"]["writes"] == [] -> run
      rounds == 0 -> flunk("run in #{run["state"]}, not #{state}")
      true -> Process.sleep(10) && until(c, state, rounds - 1)
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
    assert {:recorded, _} = report.(3, L.ended(nil, Keyword.take(opts, [:answer])))
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
