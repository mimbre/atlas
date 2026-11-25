defmodule Model.SentBackRunsTest do
  @moduledoc """
  Plan's and Design's proposals can be sent back with a note (IS-Atlas-94). In "Accept it"
  its supervisor answers Not accepted, with a note (a use case's `supervisor_note`, a
  scene's `note`): Flow deletes what its agent's proposal made, leaves what was added by
  hand, and takes the run back to its break-down, whose new task reads the note under its
  own heading. A scene too vague to design use cases from goes back the other way first
  (UC-Atlas-24): its agent asks, Flow puts the questions on the scene, "Answer its
  questions" goes to its producer, whose answer starts a fresh pass that reads them. So does
  a use case too vague to break down: Plan asks its producer, the person who supervised the
  Design run that made it (`produced_by`, which Flow links on what a proposal makes), or the
  configured decider for one that records none. Run by `AtlasFlow.Runs.Store` with `AtlasFlow.FakeFacts`, the work source's
  processes on `AtlasFlow.FakeCode` and a manual clock, as `Model.IssueRunsTest` is.
  """
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias AtlasFlow.{Bases, Delivery, Dispatch, FakeCode, FakeFacts, ManualClock}
  alias AtlasFlow.WorkSource
  alias AtlasFlow.FakeFacts.Leasing, as: L
  alias AtlasFlow.Runs.{Run, Store}

  @now ~U[2026-11-25 09:00:00Z]
  @repository "github.com/mimbre/atlas"
  @actors %{"decider" => "ada"}
  @mini {"mac-mini", "ada"}
  @offer %{"deep_coding" => 1, "independent_review" => 1}

  setup do
    Application.put_env(:atlas_bus, :store, "sent-back-#{System.unique_integer([:positive])}")
    environment = Application.get_env(:atlas_bus, :environment)
    Application.put_env(:atlas_bus, :environment, "test")

    on_exit(fn ->
      if environment,
        do: Application.put_env(:atlas_bus, :environment, environment),
        else: Application.delete_env(:atlas_bus, :environment)
    end)

    {:ok, _} = Application.ensure_all_started(:atlas_bus)
    dir = Path.join(System.tmp_dir!(), "sent-back-#{System.unique_integer([:positive])}")
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

  # Plan: a use case under a scene; its proposal is issues, its note `supervisor_note`.
  @plan %{
    flow: "break_down_use_case",
    kind: "use_case",
    key: "UC-Atlas-07",
    child: "issue",
    under: "in_use_case",
    file: "issues.json",
    note: "supervisor_note",
    heading: "Its supervisor's note"
  }

  # Design: a scene; its proposal is use cases, its note the scene's `note`.
  @design %{
    flow: "break_down_scene",
    kind: "scene",
    key: "SC-Atlas-07",
    child: "use_case",
    under: "in_scene",
    file: "use_cases.json",
    note: "note",
    heading: "Its producer's or supervisor's note"
  }

  test "Plan: Not accepted, with a note, discards its issues and Plan runs again with the note",
       c do
    sent_back(c, @plan)
  end

  test "Design: Not accepted, with a note, discards its use cases and Design runs again with the note",
       c do
    sent_back(c, @design)
  end

  # IS-Atlas-72: a new round sees what is already under its subject, and is asked to
  # propose only what is missing.
  test "Design's task carries the use cases already under its scene, Plan's the issues under its use case",
       c do
    for {p, under} <- [
          {@design,
           [
             {"UC-Atlas-01", "Read the README", "Newcomers read the README first."},
             {"UC-Atlas-02", "Find the guides", "Newcomers find the guides from it."}
           ]},
          {@plan,
           [
             {"IS-Atlas-01", "Show the README", "The README is shown on the home page."},
             {"IS-Atlas-02", "Link the guides", "The README links each guide."}
           ]}
        ] do
      subject(p)

      for {key, title, description} <- under,
          do:
            FakeFacts.put(p.child, %{
              "key" => key,
              "values" => %{"title" => title, "description" => description},
              "links" => %{p.under => [p.key]}
            })

      # Another subject's: not under this one.
      FakeFacts.put(p.child, %{
        "key" => p.child <> "-ELSEWHERE",
        "values" => %{"title" => "Somewhere else"},
        "links" => %{p.under => ["OTHER"]}
      })

      assert reconcile(c, p)["state"] == "break_down"
      supervise(c, p)
      instructions = intent(c, p)["pending"]["task"]["work"]["instructions"]

      assert instructions =~ "## Already under it\n\n"
      assert instructions =~ "propose only what is missing"

      for {key, title, description} <- under do
        assert instructions =~ "### #{p.child} #{key}: title\n\n#{title}"
        assert instructions =~ "### #{p.child} #{key}: description\n\n#{description}"
      end

      refute instructions =~ "Somewhere else"

      # Its spec says so too: those under it stay; propose only what is missing.
      {:task, spec} = flow(:test, p.flow).mechanism("break_down")
      assert spec["children"] == ["title", "description"]
      assert spec["instructions"] =~ ~s("Already under it")
      assert spec["instructions"] =~ "propose only the"
    end
  end

  # Control's to-do, as the owner of "Accept it" sees it: both answers, and Not accepted
  # asks for a note, which it writes with the verdict the run goes back on.
  test "both to-dos offer Accept and Not accepted, which asks for a note" do
    for p <- [@plan, @design] do
      fact = %{
        "key" => p.key,
        "values" => %{"phase" => "break_down", "verdict" => "none"},
        "links" => %{"assignment" => ["AS-" <> p.key]}
      }

      assignment = %{
        "key" => "AS-" <> p.key,
        "values" => %{"flow_state" => "accepting", "expected" => "Accept it"},
        "links" => %{"assigned_to" => ["ada"]}
      }

      run = %{
        "key" => "R-1",
        "flow" => p.flow,
        "generation" => 1,
        "status" => "active",
        "state" => "accepting"
      }

      presenter = Enum.find(Model.AtlasEyra.presentation(), &(&1["subject"] == p.kind))
      shown = AtlasFacts.Presentation.view(presenter, assignment, fact, [run], fn -> false end)
      parts = %{"assignment" => Map.put(assignment, "presentation", shown)}

      assert %{answers: [accept, not_accepted]} =
               Model.AtlasEyra.todo(p.kind, fact, parts, %{key: "ada", kind: "person"})

      assert %{label: "Accept", note: false, change: true} = accept
      assert %{label: "Not accepted", note: true, change: true} = not_accepted

      # What it writes: the verdict the run goes back on, and the note.
      gates = Model.AtlasEyra.__rela__(:gates)
      flows = RelaDSL.Flow.Subflow.definitions(Model.AtlasEyra.__flows__(), gates, :prod)
      answers = flows[p.flow]["states"]["accepting"]["present"]["todo"]["answers"]
      written = Enum.find(answers, &(&1["key"] == not_accepted.key))["change"]["values"]
      assert written == %{"verdict" => "reject", p.note => "$note"}

      for env <- [:prod, :test] do
        flow = Enum.find(Model.AtlasEyra.subflows(env), &(&1.name() == p.flow))
        assert flow.next("accepting", %{"verdict" => "reject"}, nil) == {:to, "break_down"}
      end
    end
  end

  test "Design asks its producer instead of guessing, and continues once they answer", c do
    p = @design
    subject(p)
    assert reconcile(c, p)["state"] == "break_down"
    supervise(c, p)

    first = "TK-#{p.key}-1"
    run = intent(c, p)
    assert run["pending"]["task"]["work"]["instructions"] =~ "`questions.md`"
    assert {:ok, _} = AtlasFlow.Runs.Projection.project(c.runner, p.kind, p.key)

    # Its agent writes questions, and no proposal.
    questions = "1. Who are the newcomers?\n2. What do they read first?"
    work(c, p, first, %{"questions.md" => questions <> "\n"})
    clarifying = until(c, p, "clarifying")
    assert [%{"key" => ^first, "outcome" => "completed"} = task] = clarifying["pending"]["tasks"]
    refute Map.has_key?(task, "made")
    assert clarifying["supervised_by"] == "ada"

    # Flow wrote them on the scene, for its supervisor; nothing was made under it.
    scene = FakeFacts.get("scene", p.key)
    assert scene["values"]["questions"] == questions
    assert [write] = for(w <- FakeFacts.stored_from_flow(), w["values"]["questions"], do: w)
    assert {write["by"], write["cause"]} == {"flow", "For ada: asked by #{first}"}
    assert FakeFacts.get("use_case", "UC-Atlas-01") == nil

    # Its producer (the configured decider, here bo), not its supervisor ada, has the
    # to-do, with the questions and Answered, once the Engine projects it.
    FakeFacts.put("person", %{"key" => "bo"})
    producer = AtlasFlow.Model.load(Model.AtlasEyra, :test, %{"decider" => "bo"})
    assert {:ok, %{waits: nil}} = AtlasFlow.Runs.Projection.project(producer, p.kind, p.key)
    assignment = FakeFacts.get("assignment", "AS-" <> p.key)
    assert assignment["links"]["assigned_to"] == ["bo"]
    assert assignment["values"]["flow_state"] == "clarifying"

    presenter = Enum.find(Model.AtlasEyra.presentation(), &(&1["subject"] == p.kind))

    shown =
      AtlasFacts.Presentation.view(presenter, assignment, scene, [clarifying], fn -> false end)

    parts = %{"assignment" => Map.put(assignment, "presentation", shown)}

    assert %{expected: "Answer its questions", section: section, answers: [answered]} =
             Model.AtlasEyra.todo(p.kind, scene, parts, %{key: "bo", kind: "person"})

    assert section == %{heading: "Its agent's questions", text: questions}
    assert %{label: "Answered", note: true, change: true} = answered

    # It rewrites the description, then answers with a note (as Control writes the answer).
    description = "Newcomers to the team read the README first, then the guides."
    answers = "New developers. The README."
    change(p, %{"description" => description, "verdict" => "answered", "answers" => answers})

    # A fresh pass of its agent, in the same run, reads the questions, the answers and the
    # description as it is now.
    second = "TK-#{p.key}-2"
    again = intent(c, p)
    assert {again["state"], again["generation"]} == {"break_down", clarifying["generation"]}
    assert again["supervised_by"] == "ada"
    assert %{"key" => ^second} = again["pending"]["task"]
    instructions = again["pending"]["task"]["work"]["instructions"]
    assert instructions =~ "## description\n\n#{description}"
    assert instructions =~ "## questions\n\n#{questions}"
    assert instructions =~ "## answers\n\n#{answers}"

    # It proposes this time, and Flow makes the use cases as before; Accept it is next.
    work(c, p, second, %{p.file => JSON.encode!([%{"title" => "Read the README"}])})
    accepting = until(c, p, "accepting")
    assert [_, %{"key" => ^second, "made" => [[_, made]]}] = accepting["pending"]["tasks"]
    assert FakeFacts.get(p.child, made)["links"][p.under] == [p.key]
  end

  # UC-Atlas-24, for Plan: cy supervised the Design run that made the use case, so cy is
  # its producer; ada picks up its Plan; bo is the configured decider. The questions go
  # to cy, not to ada or bo; cy answers and ada's Plan continues and proposes issues.
  test "Plan asks the use case's producer, and continues once they answer", c do
    p = @plan
    subject(p, produced_by: "cy")
    FakeFacts.put("person", %{"key" => "bo"})
    FakeFacts.put("person", %{"key" => "cy"})
    decider = AtlasFlow.Model.load(Model.AtlasEyra, :test, %{"decider" => "bo"})

    assert reconcile(c, p)["state"] == "break_down"
    supervise(c, p)

    first = "TK-#{p.key}-1"
    run = intent(c, p)
    assert run["pending"]["task"]["work"]["instructions"] =~ "`questions.md`"
    assert {:ok, _} = AtlasFlow.Runs.Projection.project(c.runner, p.kind, p.key)

    # Its agent writes questions, and no proposal.
    questions = "1. Which README: the repository's or the product's?\n2. Who reads it?"
    work(c, p, first, %{"questions.md" => questions <> "\n"})
    clarifying = until(c, p, "clarifying")
    assert [%{"key" => ^first, "outcome" => "completed"} = task] = clarifying["pending"]["tasks"]
    refute Map.has_key?(task, "made")
    assert clarifying["supervised_by"] == "ada"

    use_case = FakeFacts.get("use_case", p.key)
    assert use_case["values"]["questions"] == questions
    assert [write] = for(w <- FakeFacts.stored_from_flow(), w["values"]["questions"], do: w)
    assert {write["by"], write["cause"]} == {"flow", "For ada: asked by #{first}"}
    assert FakeFacts.get("issue", "IS-Atlas-01") == nil

    # Its producer cy has the to-do: not its supervisor ada, nor the decider bo.
    for runner <- [c.runner, decider] do
      assert {:ok, %{waits: nil}} = AtlasFlow.Runs.Projection.project(runner, p.kind, p.key)
      assignment = FakeFacts.get("assignment", "AS-" <> p.key)
      assert assignment["links"]["assigned_to"] == ["cy"]
      assert assignment["values"]["flow_state"] == "clarifying"
    end

    assignment = FakeFacts.get("assignment", "AS-" <> p.key)
    presenter = Enum.find(Model.AtlasEyra.presentation(), &(&1["subject"] == p.kind))

    shown =
      AtlasFacts.Presentation.view(presenter, assignment, use_case, [clarifying], fn -> false end)

    parts = %{"assignment" => Map.put(assignment, "presentation", shown)}

    assert %{expected: "Answer its questions", section: section, answers: [answered]} =
             Model.AtlasEyra.todo(p.kind, use_case, parts, %{key: "cy", kind: "person"})

    assert section == %{heading: "Its agent's questions", text: questions}
    assert %{label: "Answered", note: true, change: true} = answered

    # Neither ada nor bo is offered it.
    for other <- ["ada", "bo"],
        do:
          assert(
            Model.AtlasEyra.todo(p.kind, use_case, parts, %{key: other, kind: "person"}) == nil
          )

    # cy rewrites the description, then answers with a note (as Control writes the answer).
    description = "Newcomers read the repository's README before anything else."
    answers = "The repository's README. New developers."
    change(p, %{"description" => description, "verdict" => "answered", "answers" => answers})

    # A fresh pass of ada's Plan, in the same run, reads the questions, the answers and
    # the use case as it is now.
    second = "TK-#{p.key}-2"
    again = intent(c, p)
    assert {again["state"], again["generation"]} == {"break_down", clarifying["generation"]}
    assert again["supervised_by"] == "ada"
    assert %{"key" => ^second} = again["pending"]["task"]
    instructions = again["pending"]["task"]["work"]["instructions"]
    assert instructions =~ "## description\n\n#{description}"
    assert instructions =~ "## questions\n\n#{questions}"
    assert instructions =~ "## answers\n\n#{answers}"

    # It proposes issues this time, as before: made under it, numbered, produced by ada,
    # and Accept it is next, for its supervisor ada.
    work(c, p, second, [%{"title" => "Show the README"}, %{"title" => "Link the guides"}])
    accepting = until(c, p, "accepting")

    assert [_, %{"key" => ^second, "made" => [[_, one], [_, two]]}] =
             accepting["pending"]["tasks"]

    for {key, order} <- [{one, 1}, {two, 2}] do
      issue = FakeFacts.get(p.child, key)
      assert issue["links"][p.under] == [p.key]
      assert issue["links"]["produced_by"] == ["ada"]
      assert issue["values"]["order"] == order
    end

    assert {:ok, _} = AtlasFlow.Runs.Projection.project(c.runner, p.kind, p.key)
    assert FakeFacts.get("assignment", "AS-" <> p.key)["links"]["assigned_to"] == ["ada"]
  end

  # A use case that records no producer (made by hand, or before producers were recorded)
  # asks the configured decider.
  test "Plan asks the decider when the use case records no producer", c do
    p = @plan
    subject(p)
    FakeFacts.put("person", %{"key" => "bo"})
    decider = AtlasFlow.Model.load(Model.AtlasEyra, :test, %{"decider" => "bo"})

    assert reconcile(c, p)["state"] == "break_down"
    supervise(c, p)
    intent(c, p)
    assert {:ok, _} = AtlasFlow.Runs.Projection.project(c.runner, p.kind, p.key)

    work(c, p, "TK-#{p.key}-1", %{"questions.md" => "Which README?"})
    assert until(c, p, "clarifying")["supervised_by"] == "ada"

    assert {:ok, %{waits: nil}} = AtlasFlow.Runs.Projection.project(decider, p.kind, p.key)
    assert FakeFacts.get("assignment", "AS-" <> p.key)["links"]["assigned_to"] == ["bo"]
  end

  defp sent_back(c, p) do
    subject(p)
    assert reconcile(c, p)["state"] == "break_down"
    supervise(c, p)

    # Its agent proposes two; Flow makes them under it, and Accept it goes to ada.
    first = "TK-#{p.key}-1"
    run = intent(c, p)
    assert %{"key" => ^first} = run["pending"]["task"]
    refute run["pending"]["task"]["work"]["instructions"] =~ p.heading
    # Nothing is under it yet: no such section.
    refute run["pending"]["task"]["work"]["instructions"] =~ "## Already under it"

    proposal = [%{"title" => "One", "description" => "First."}, %{"title" => "Two"}]
    work(c, p, first, proposal)
    accepting = until(c, p, "accepting")
    assert [%{"key" => ^first, "made" => made}] = accepting["pending"]["tasks"]
    assert [[kind, _], [kind, _]] = made
    assert kind == p.child
    proposed = for [_, key] <- made, do: key
    for key <- proposed, do: assert(FakeFacts.get(p.child, key)["links"][p.under] == [p.key])

    # Each is linked to its producer, the run's supervisor ada (SC-Atlas-09).
    for key <- proposed,
        do: assert(FakeFacts.get(p.child, key)["links"]["produced_by"] == ["ada"])

    # Its supervisor adds one by hand, then sends the proposal back with a note.
    FakeFacts.put(p.child, %{
      "key" => "BY-HAND",
      "values" => %{"title" => "Added by hand"},
      "links" => %{p.under => [p.key]}
    })

    note = "Split it by actor, not by layer."
    change(p, %{"verdict" => "reject", p.note => note})

    # The proposal is gone, the one added by hand stays, and a new task runs with the note.
    second = "TK-#{p.key}-2"
    again = intent(c, p)
    assert again["state"] == "break_down"
    assert %{"key" => ^second} = again["pending"]["task"]
    for key <- proposed, do: assert(FakeFacts.get(p.child, key) == nil)
    assert FakeFacts.get(p.child, "BY-HAND")
    assert again["pending"]["task"]["work"]["instructions"] =~ "## #{p.heading}\n\n#{note}"

    # The new round sees the one added by hand, which stays, and not the discarded ones.
    instructions = again["pending"]["task"]["work"]["instructions"]
    assert instructions =~ "## Already under it"
    assert instructions =~ "### #{p.child} BY-HAND: title\n\nAdded by hand"
    for key <- proposed, do: refute(instructions =~ "### #{p.child} #{key}:")

    {_lease, work} = lease!()
    assert work.instructions =~ note
  end

  defp subject(p, opts \\ [])

  defp subject(%{kind: "use_case"} = p, opts) do
    FakeFacts.put("scene", %{"key" => "SC-Atlas-01", "values" => %{"title" => "Newcomers"}})
    links = %{"in_scene" => ["SC-Atlas-01"], "assignment" => ["AS-" <> p.key]}

    links =
      if opts[:produced_by], do: Map.put(links, "produced_by", [opts[:produced_by]]), else: links

    FakeFacts.put("use_case", %{
      "key" => p.key,
      "values" => %{
        "title" => "Read the README",
        "description" => "People read the README.",
        "phase" => "break_down"
      },
      "links" => links
    })

    assignment(p)
  end

  defp subject(%{kind: "scene"} = p, _opts) do
    FakeFacts.put("scene", %{
      "key" => p.key,
      "values" => %{
        "title" => "Newcomers",
        "description" => "They read.",
        "phase" => "break_down"
      },
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

  # The task's lease worked to its end, its result commit holding its proposal (or the
  # files given).
  defp work(c, _p, task, files) when is_map(files) do
    {lease, _work} = lease!()

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
  end

  defp work(c, p, task, proposal), do: work(c, p, task, %{p.file => JSON.encode!(proposal)})

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

  defp flow(env, name), do: Enum.find(Model.AtlasEyra.subflows(env), &(&1.name() == name))

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
