defmodule Model.ClarifyingRunsTest do
  @moduledoc """
  Design asks the scene's producer instead of guessing (UC-Atlas-24). Its agent, given a
  scene too vague to design use cases from, writes only its questions (`questions.md`):
  Flow, the only writer, puts them in the scene's `questions`, makes no use cases, and the
  task ends `asked`. "Answer its questions" (`clarifying`) goes to its producer (the
  configured decider, until a scene records who produced it), showing the questions; its
  one answer, Answered, writes the producer's note to `answers` and takes the run back to
  its break-down, whose new task reads the questions, the answers and the description as
  it is now. The run keeps its supervisor. Run by `AtlasFlow.Runs.Store` with
  `AtlasFlow.FakeFacts`, the work source's processes on `AtlasFlow.FakeCode` and a manual
  clock, as `Model.SentBackRunsTest` is.
  """
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias AtlasFlow.{Bases, Delivery, Dispatch, FakeCode, FakeFacts, ManualClock, Results}
  alias AtlasFlow.WorkSource
  alias AtlasFlow.FakeFacts.Leasing, as: L
  alias AtlasFlow.Runs.{Run, Store}

  @now ~U[2026-11-25 09:00:00Z]
  @repository "github.com/mimbre/atlas"
  @actors %{"decider" => "ada"}
  @mini {"mac-mini", "ada"}
  @offer %{"deep_coding" => 1, "independent_review" => 1}

  @p %{
    flow: "break_down_scene",
    kind: "scene",
    key: "SC-Atlas-90",
    child: "use_case",
    under: "in_scene"
  }

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

  test "a Design run whose task asks is its producer's, showing the questions; Answered continues it",
       c do
    p = @p
    subject(p, "Make it better.")
    assert reconcile(c, p)["state"] == "break_down"
    supervise(c, p)

    # Its agent is told where its questions go, and to write nothing else then.
    first = "TK-#{p.key}-1"
    run = intent(c, p)
    assert %{"key" => ^first} = run["pending"]["task"]
    assert run["pending"]["task"]["work"]["instructions"] =~ "questions.md"

    questions = "1. Who is the actor?\n2. What does better mean here?"
    work(c, first, %{"questions.md" => questions <> "\n"})
    clarifying = until(c, p, "clarifying")

    # The task ended asked; it made nothing, and Flow wrote the questions, for ada.
    assert [%{"key" => ^first, "outcome" => "completed"} = result] =
             clarifying["pending"]["tasks"]

    refute Map.has_key?(result, "made")
    assert clarifying["last_input"]["outcome"] == "asked"
    assert clarifying["supervised_by"] == "ada"
    scene = FakeFacts.get("scene", p.key)
    assert scene["values"]["questions"] == questions

    assert %{"by" => "flow", "cause" => "For ada: asked by " <> ^first} =
             Enum.find(
               FakeFacts.stored_from_flow(),
               &(&1["key"] == p.key and Map.has_key?(&1["values"] || %{}, "questions"))
             )

    refute Enum.any?(
             FakeFacts.stored_from_flow(),
             &(&1["op"] == "create" and String.starts_with?(&1["key"], "UC-"))
           )

    # It is the producer's, the configured decider until a scene records its producer.
    {:ok, actors} = AtlasBus.Actors.resolve(Model.AtlasEyra.actors(), @actors)

    for env <- [:prod, :test] do
      f = flow(env)
      assert AtlasFlow.Model.owner(f.owner("clarifying")["default"], actors)["key"] == "ada"
    end

    # Its To-Do: Answer its questions, the questions as its section, one answer with a note.
    todo = todo(p, Map.put(scene["values"], "verdict", "none"), "clarifying")
    assert todo.expected == "Answer its questions"
    assert todo.section.text == questions
    assert [%{label: "Answered", note: true, change: true}] = todo.answers

    {:ok, flows} = JSON.decode(File.read!("../targets/atlas/flows.json"))
    [answered] = flows["flows"][p.flow]["states"]["clarifying"]["present"]["todo"]["answers"]
    assert answered["change"]["values"] == %{"verdict" => "answered", "answers" => "$note"}

    # Its producer rewrites the description and answers: a new task, with all three.
    description = "A newcomer reads the README and runs Atlas on the test environment."
    answers = "1. A newcomer.\n2. Running it in five minutes."
    change(p, %{"description" => description, "verdict" => "answered", "answers" => answers})

    second = "TK-#{p.key}-2"
    again = intent(c, p)
    assert {again["state"], again["supervised_by"]} == {"break_down", "ada"}
    assert %{"key" => ^second} = again["pending"]["task"]
    instructions = again["pending"]["task"]["work"]["instructions"]
    assert instructions =~ "## description\n\n#{description}"
    assert instructions =~ "## questions\n\n#{questions}"
    assert instructions =~ "## answers\n\n#{answers}"
    refute instructions =~ "Make it better."

    # Its fresh agent, on ada's Runtime, reads them and proposes use cases: Flow makes
    # them, and Accept it follows as before.
    proposal = [%{"title" => "Read the README", "description" => "A newcomer reads it."}]
    leased = work(c, second, %{"use_cases.json" => JSON.encode!(proposal)})
    assert leased.instructions =~ answers
    accepting = until(c, p, "accepting")
    assert [_, %{"key" => ^second, "made" => [["use_case", key]]}] = accepting["pending"]["tasks"]
    assert FakeFacts.get("use_case", key)["links"][p.under] == [p.key]
  end

  test "a Design task that completes with use_cases.json goes to Accept it, as before", c do
    p = %{@p | key: "SC-Atlas-91"}
    subject(p, "A newcomer reads the README.")
    assert reconcile(c, p)["state"] == "break_down"
    supervise(c, p)

    first = "TK-#{p.key}-1"
    intent(c, p)
    work(c, first, %{"use_cases.json" => JSON.encode!([%{"title" => "Read it"}])})
    accepting = until(c, p, "accepting")
    assert [%{"key" => ^first, "made" => [["use_case", _]]}] = accepting["pending"]["tasks"]
    assert accepting["last_input"]["outcome"] == "completed"
    assert FakeFacts.get("scene", p.key)["values"]["questions"] == nil
  end

  test "Answered goes back to the break-down; the span keeps its supervisor throughout" do
    for env <- [:prod, :test] do
      f = flow(env)
      assert f.next("clarifying", %{"verdict" => "answered"}, nil) == {:to, "break_down"}
      assert f.next("break_down", %{"task_result" => "asked"}, :result) == {:to, "clarifying"}

      {:task, spec} = f.mechanism("break_down")
      assert spec["asks"] == %{"field" => "questions", "file" => "questions.md"}
      assert spec["fields"] == ~w(title description questions answers)
    end

    [span] = Model.AtlasEyra.supervision()["spans"]["break_down_scene"]
    assert "clarifying" in span["states"]
  end

  defp flow(env), do: Enum.find(Model.AtlasEyra.subflows(env), &(&1.name() == @p.flow))

  # Control's to-do, as the owner of `state` sees it.
  defp todo(p, values, state) do
    fact = %{"key" => p.key, "values" => values, "links" => %{"assignment" => ["AS-" <> p.key]}}

    assignment = %{
      "key" => "AS-" <> p.key,
      "values" => %{"flow_state" => state, "expected" => "Answer its questions"},
      "links" => %{"assigned_to" => ["ada"]}
    }

    run = %{
      "key" => "R-1",
      "flow" => p.flow,
      "generation" => 1,
      "status" => "active",
      "state" => state
    }

    presenter = Enum.find(Model.AtlasEyra.presentation(), &(&1["subject"] == p.kind))
    shown = AtlasFacts.Presentation.view(presenter, assignment, fact, [run], fn -> false end)
    parts = %{"assignment" => Map.put(assignment, "presentation", shown)}
    Model.AtlasEyra.todo(p.kind, fact, parts, %{key: "ada", kind: "person"})
  end

  defp subject(p, description) do
    FakeFacts.put("scene", %{
      "key" => p.key,
      "values" => %{"title" => "Newcomers", "description" => description, "phase" => "break_down"},
      "links" => %{"assignment" => ["AS-" <> p.key]}
    })

    assignment(p)
  end

  defp assignment(p) do
    FakeFacts.put("assignment", %{
      "key" => "AS-" <> p.key,
      "values" => %{"of" => p.key},
      "links" => %{"assigned_to" => ["mac-mini"]},
      "origins" => %{"assigned_to" => %{"by" => "ada", "position" => 1}}
    })
  end

  # Its supervisor's answer, as Control writes its values on the subject.
  defp change(p, values) do
    fact = FakeFacts.get(p.kind, p.key)

    FakeFacts.put(
      p.kind,
      Map.merge(fact, %{
        "values" => Map.merge(fact["values"], values),
        "version" => (fact["version"] || 1) + 1
      })
    )
  end

  # The run supervised by ada, as a pickup writes it.
  defp supervise(c, p) do
    kind = c.runner.config["kind"]
    fact = FakeFacts.get(kind, Run.key(p.flow, p.kind, p.key, 1))
    relation = c.runner.config["supervision"]["relation"]
    links = Map.put(fact["links"] || %{}, relation, ["ada"])
    FakeFacts.put(kind, Map.merge(fact, %{"links" => links, "version" => fact["version"] + 1}))
  end

  defp lease! do
    assert {:polled, %{leases: [%{lease_id: lease, work: work}]}} =
             WorkSource.poll(@mini, L.poll_input("mac-mini", [], @offer))

    {lease, work}
  end

  # The task's lease worked to its end, its result commit holding `files`.
  defp work(c, task, files) do
    {lease, work} = lease!()

    FakeCode.put(
      c.code,
      @repository,
      "refs/atlas/results/" <> task,
      "rev_#{task}",
      Map.put(files, "README.md", "# Atlas\n")
    )

    report = &WorkSource.report(@mini, %{lease_id: lease, revision: &1, report: &2})
    assert {:recorded, _} = report.(1, %{state: :accepted})
    assert {:recorded, _} = report.(2, %{state: :started})
    assert {:recorded, _} = report.(3, L.ended(nil))
    work
  end

  defp intent(c, p, rounds \\ 50) do
    run = reconcile(c, p)

    cond do
      run["pending"]["task"] != nil and run["pending"]["writes"] == [] -> run
      rounds == 0 -> flunk("no task in #{run["state"]}")
      true -> next_reconcile(p) && intent(c, p, rounds - 1)
    end
  end

  defp until(c, p, state, rounds \\ 50) do
    run = reconcile(c, p)

    cond do
      run["state"] == state and run["pending"]["writes"] == [] -> run
      rounds == 0 -> flunk("run in #{run["state"]}, not #{state}")
      true -> next_reconcile(p) && until(c, p, state, rounds - 1)
    end
  end

  defp next_reconcile(%{kind: kind, key: key}) do
    receive do
      {:reconcile, ^kind, ^key} -> true
      {:"$gen_cast", {:reconcile, ^kind, ^key}} -> true
    after
      30_000 -> flunk("no reconcile of #{key}")
    end
  end

  defp reconcile(c, p) do
    config = c.runner.config
    flows = c.runner.flows
    {:ok, %{runs: known}} = Store.plan(config, flows)
    now = AtlasFlow.Runs.Clock.now(c.clock)
    {:ok, runs} = Store.reconcile_subjects(config, flows, now, known, [{p.kind, p.key}])
    assert [run] = Enum.filter(runs, &(&1["subject_key"] == p.key and &1["flow"] == p.flow))
    run
  end
end
