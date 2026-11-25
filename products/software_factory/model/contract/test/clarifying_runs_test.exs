defmodule Model.ClarifyingRunsTest do
  @moduledoc """
  Design asks the scene's producer instead of guessing (UC-Atlas-24, SC-Atlas-09). Its
  agent, given a scene too vague to design use cases from, writes its questions to
  `questions.md` and nothing else; Flow, the only writer, puts them in the scene's
  `questions`, makes no use case, and the run goes to "Answer its questions"
  (`clarifying`), assigned to the scene's producer (the configured decider, `bea`, while a
  scene records no producer), who sees the questions. Their Answered, with a note (the
  scene's `answers`), takes the run back to its break-down, whose new task reads the
  questions, the answers and the description as the producer left it; that task's use
  cases are made as before. The run keeps its supervisor, `ada`, throughout. Run by
  `AtlasFlow.Runs.Store` with `AtlasFlow.FakeFacts`, the work source's processes on
  `AtlasFlow.FakeCode` and a manual clock, as `Model.SentBackRunsTest` is.
  """
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias AtlasFlow.{Bases, Delivery, Dispatch, FakeCode, FakeFacts, ManualClock, Results}
  alias AtlasFlow.WorkSource
  alias AtlasFlow.FakeFacts.Leasing, as: L
  alias AtlasFlow.Runs.{Run, Store}

  @now ~U[2026-11-25 09:00:00Z]
  @repository "github.com/mimbre/atlas"
  # Its producer (the configured decider) is not its supervisor, whose Runtime is the mini.
  @actors %{"decider" => "bea"}
  @mini {"mac-mini", "ada"}
  @offer %{"deep_coding" => 1, "independent_review" => 1}
  @flow "break_down_scene"
  @key "SC-Atlas-41"
  @questions "1. Which reports are meant: the run history, or the cost per scene?\n2. Who reads them?"

  setup do
    Application.put_env(:atlas_bus, :store, "clarifying-#{System.unique_integer([:positive])}")
    environment = Application.get_env(:atlas_bus, :environment)
    Application.put_env(:atlas_bus, :environment, "test")

    on_exit(fn ->
      if environment,
        do: Application.put_env(:atlas_bus, :environment, environment),
        else: Application.delete_env(:atlas_bus, :environment)
    end)

    {:ok, _} = Application.ensure_all_started(:atlas_bus)
    dir = Path.join(System.tmp_dir!(), "clarifying-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)

    start_supervised!(FakeFacts)
    {:ok, clock} = ManualClock.start_link(@now)
    clock = {ManualClock, clock}
    :ok = AtlasBus.attach("flow")

    FakeFacts.put("machinery", %{"key" => "mac-mini", "values" => %{"name" => "mac-mini"}})
    FakeFacts.put("person", %{"key" => "ada"})
    FakeFacts.put("person", %{"key" => "bea"})

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

    %{runner: runner, clock: clock, code: code}
  end

  test "asked: the producer answers its agent's questions, and Design continues", c do
    scene("Something with reports.")
    assert reconcile(c)["state"] == "break_down"
    supervise(c)

    # Its agent is told it may ask instead, and what it reads: no questions yet.
    first = "TK-#{@key}-1"
    run = intent(c)
    assert %{"key" => ^first} = run["pending"]["task"]
    instructions = run["pending"]["task"]["work"]["instructions"]
    assert instructions =~ "questions.md"
    refute instructions =~ @questions
    assert projected(c)["values"]["flow_state"] == "break_down"

    # It writes its questions and nothing else: Flow puts them on the scene, makes no use
    # case, and the run asks the producer.
    work(c, first, %{"questions.md" => "\n" <> @questions <> "\n"})
    asking = until(c, "clarifying")
    assert [%{"key" => ^first, "outcome" => "completed"} = result] = asking["pending"]["tasks"]
    refute Map.has_key?(result, "made")
    assert FakeFacts.get("scene", @key)["values"]["questions"] == @questions
    refute Enum.any?(FakeFacts.sent(), &(get_in(&1, ["links", "in_scene"]) == [@key]))

    # Flow wrote the questions, for its supervisor, naming the task; never the answers.
    flows = for w <- FakeFacts.sent(), w["key"] == @key, w["op"] == "change", do: w
    assert [asked] = Enum.filter(flows, &Map.has_key?(&1["values"], "questions"))
    assert asked["by"] == "flow"
    assert asked["cause"] == "For ada: asked by #{first}"
    refute Enum.any?(flows, &Map.has_key?(&1["values"], "answers"))

    # It is its producer's: assigned to bea, never its supervisor in her stead, though it
    # lies in Design's span; its supervisor is still ada.
    assignment = projected(c)
    assert assignment["links"]["assigned_to"] == ["bea"]
    assert assignment["values"]["flow_state"] == "clarifying"
    assert supervisor(c) == ["ada"]

    # bea's to-do shows the questions and offers Answered, with a note; ada has none.
    item = item(c, asking)
    bea = %{key: "bea", kind: "person"}

    assert %{expected: "Answer its questions", section: section, answers: [answered]} =
             Model.AtlasEyra.todo("scene", item["fact"], item["parts"], bea)

    assert section == %{heading: "Its agent's questions", text: @questions}
    assert %{label: "Answered", note: true, change: true} = answered

    assert nil ==
             Model.AtlasEyra.todo("scene", item["fact"], item["parts"], %{
               key: "ada",
               kind: "person"
             })

    assert {:write, %{"values" => values, "note" => true}} =
             Model.AtlasEyra.answer("scene", answered.key, item, bea)

    assert values == %{"verdict" => "answered", "answers" => "$note"}

    assert {:refuse, _} =
             Model.AtlasEyra.answer("scene", answered.key, item, %{key: "ada", kind: "person"})

    # bea rewrites the description by hand, then answers: the answer is hers, written by
    # Control as her, never by Flow.
    rewritten = "A supervisor sees what each scene's agent work cost."
    answers = "The cost per scene, read by its supervisor."
    change(%{"description" => rewritten, "verdict" => "answered", "answers" => answers})

    # Back to its break-down: a new task, on ada's Runtime, reading the questions, the
    # answers and the description as bea left it.
    second = "TK-#{@key}-2"
    again = intent(c)
    assert again["state"] == "break_down"
    assert %{"key" => ^second} = again["pending"]["task"]
    instructions = again["pending"]["task"]["work"]["instructions"]
    assert instructions =~ @questions
    assert instructions =~ answers
    assert instructions =~ rewritten
    refute instructions =~ "Something with reports."
    assert supervisor(c) == ["ada"]
    assert projected(c)["values"]["flow_state"] == "break_down"

    {lease, work} = lease!()
    assert work.instructions =~ answers

    # This time it proposes use cases: made as before, and Accept it goes to its owner.
    proposal = [
      %{"title" => "See the cost per scene", "description" => "Its supervisor sees it."}
    ]

    finish(c, second, %{"use_cases.json" => JSON.encode!(proposal)}, lease)
    accepting = until(c, "accepting")

    assert [_, %{"key" => ^second, "made" => [["use_case", made]]}] =
             accepting["pending"]["tasks"]

    assert FakeFacts.get("use_case", made)["links"]["in_scene"] == [@key]
    assert FakeFacts.get("use_case", made)["values"]["title"] == "See the cost per scene"
  end

  test "a task that completes with use cases, and no questions, goes to Accept it as before",
       c do
    scene("Newcomers read the README and start the Console.")
    assert reconcile(c)["state"] == "break_down"
    supervise(c)

    first = "TK-#{@key}-1"
    assert %{"key" => ^first} = intent(c)["pending"]["task"]
    proposal = [%{"title" => "Read the README"}, %{"title" => "Start the Console"}]
    work(c, first, %{"use_cases.json" => JSON.encode!(proposal)})
    accepting = until(c, "accepting")
    assert [%{"key" => ^first, "made" => [_, _]}] = accepting["pending"]["tasks"]
    assert FakeFacts.get("scene", @key)["values"]["questions"] == nil
  end

  # Whichever environment: the state, its owner, its answer and where it leads.
  test "Answer its questions is the producer's, inside Design's span, and leads back" do
    for env <- [:prod, :test] do
      flow = Enum.find(Model.AtlasEyra.subflows(env), &(&1.name() == @flow))
      {:task, spec} = flow.mechanism("break_down")
      assert spec["asks"] == %{"field" => "questions", "file" => "questions.md"}
      assert ~w(questions answers) -- spec["fields"] == []
      assert flow.next("break_down", %{"task_result" => "asked"}, :result) == {:to, "clarifying"}
      assert flow.next("clarifying", %{"verdict" => "answered"}, nil) == {:to, "break_down"}
    end

    [span] = Model.AtlasEyra.supervision()["spans"][@flow]
    assert "clarifying" in span["states"]
  end

  defp scene(description) do
    FakeFacts.put("scene", %{
      "key" => @key,
      "values" => %{"title" => "Reports", "description" => description, "phase" => "break_down"},
      "links" => %{"assignment" => ["AS-" <> @key]}
    })

    FakeFacts.put("assignment", %{
      "key" => "AS-" <> @key,
      "values" => %{"of" => @key},
      "links" => %{"assigned_to" => ["mac-mini"]},
      "origins" => %{"assigned_to" => %{"by" => "ada", "position" => 1}}
    })
  end

  # Its assignment, once Flow projected the run on it, as the Engine does after a reconcile.
  defp projected(c) do
    assert {:ok, _} = AtlasFlow.Runs.Projection.project(c.runner, "scene", @key)
    FakeFacts.get("assignment", "AS-" <> @key)
  end

  # The scene and its parts, as Control reads them for a to-do: its assignment presented.
  defp item(c, run) do
    fact = FakeFacts.get("scene", @key)
    assignment = FakeFacts.get("assignment", "AS-" <> @key)
    presenter = Enum.find(Model.AtlasEyra.presentation(), &(&1["subject"] == "scene"))

    shown =
      AtlasFacts.Presentation.view(presenter, assignment, fact, [run_fact(c, run)], fn ->
        false
      end)

    %{"fact" => fact, "parts" => %{"assignment" => Map.put(assignment, "presentation", shown)}}
  end

  defp run_fact(_c, run),
    do: Map.take(run, ~w(key flow generation status state))

  # A person's change on the scene, as Control writes it.
  defp change(values) do
    fact = FakeFacts.get("scene", @key)

    FakeFacts.put(
      "scene",
      Map.merge(fact, %{
        "values" => Map.merge(fact["values"], values),
        "version" => (fact["version"] || 1) + 1
      })
    )
  end

  # The run supervised by ada, as a pickup writes it.
  defp supervise(c) do
    kind = c.runner.config["kind"]
    fact = FakeFacts.get(kind, Run.key(@flow, "scene", @key, 1))
    relation = c.runner.config["supervision"]["relation"]
    links = Map.put(fact["links"] || %{}, relation, ["ada"])
    FakeFacts.put(kind, Map.merge(fact, %{"links" => links, "version" => fact["version"] + 1}))
  end

  defp supervisor(c) do
    fact = FakeFacts.get(c.runner.config["kind"], Run.key(@flow, "scene", @key, 1))
    fact["links"][c.runner.config["supervision"]["relation"]]
  end

  defp lease! do
    assert {:polled, %{leases: [%{lease_id: lease, work: work}]}} =
             WorkSource.poll(@mini, L.poll_input("mac-mini", [], @offer))

    {lease, work}
  end

  # The task's lease worked to its end, its result commit holding `files`.
  defp work(c, task, files) do
    {lease, _work} = lease!()
    finish(c, task, files, lease)
  end

  defp finish(c, task, files, lease) do
    FakeCode.put(
      c.code,
      @repository,
      "refs/atlas/results/" <> task,
      "rev_#{task}",
      Map.merge(%{"README.md" => "# Atlas\n"}, files)
    )

    report = &WorkSource.report(@mini, %{lease_id: lease, revision: &1, report: &2})
    assert {:recorded, _} = report.(1, %{state: :accepted})
    assert {:recorded, _} = report.(2, %{state: :started})
    assert {:recorded, _} = report.(3, L.ended(nil))
  end

  defp intent(c, rounds \\ 50) do
    run = reconcile(c)

    cond do
      run["pending"]["task"] != nil and run["pending"]["writes"] == [] -> run
      rounds == 0 -> flunk("no task in #{run["state"]}")
      true -> next_reconcile() && intent(c, rounds - 1)
    end
  end

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
      {:reconcile, "scene", @key} -> true
      {:"$gen_cast", {:reconcile, "scene", @key}} -> true
    after
      30_000 -> flunk("no reconcile of #{@key}")
    end
  end

  defp reconcile(c) do
    config = c.runner.config
    flows = c.runner.flows
    {:ok, %{runs: known}} = Store.plan(config, flows)
    now = AtlasFlow.Runs.Clock.now(c.clock)
    {:ok, runs} = Store.reconcile_subjects(config, flows, now, known, [{"scene", @key}])
    assert [run] = Enum.filter(runs, &(&1["subject_key"] == @key and &1["flow"] == @flow))
    run
  end
end
