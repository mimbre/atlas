defmodule Model.SentBackRunsTest do
  @moduledoc """
  Plan's and Design's proposals can be sent back with a note (IS-Atlas-94). In "Accept it"
  its supervisor answers Not accepted, with a note (a use case's `supervisor_note`, a
  scene's `note`): Flow deletes what its agent's proposal made, leaves what was added by
  hand, and takes the run back to its break-down, whose new task reads the note under its
  own heading. Run by `AtlasFlow.Runs.Store` with `AtlasFlow.FakeFacts`, the work source's
  processes on `AtlasFlow.FakeCode` and a manual clock, as `Model.IssueRunsTest` is.
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
      {:ok, flows} = JSON.decode(File.read!("../targets/atlas/flows.json"))
      answers = flows["flows"][p.flow]["states"]["accepting"]["present"]["todo"]["answers"]
      written = Enum.find(answers, &(&1["key"] == not_accepted.key))["change"]["values"]
      assert written == %{"verdict" => "reject", p.note => "$note"}

      for env <- [:prod, :test] do
        flow = Enum.find(Model.AtlasEyra.subflows(env), &(&1.name() == p.flow))
        assert flow.next("accepting", %{"verdict" => "reject"}, nil) == {:to, "break_down"}
      end
    end
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

    proposal = [%{"title" => "One", "description" => "First."}, %{"title" => "Two"}]
    work(c, p, first, proposal)
    accepting = until(c, p, "accepting")
    assert [%{"key" => ^first, "made" => made}] = accepting["pending"]["tasks"]
    assert [[kind, _], [kind, _]] = made
    assert kind == p.child
    proposed = for [_, key] <- made, do: key
    for key <- proposed, do: assert(FakeFacts.get(p.child, key)["links"][p.under] == [p.key])

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

    {_lease, work} = lease!()
    assert work.instructions =~ note
  end

  defp subject(%{kind: "use_case"} = p) do
    FakeFacts.put("scene", %{"key" => "SC-Atlas-01", "values" => %{"title" => "Newcomers"}})

    FakeFacts.put("use_case", %{
      "key" => p.key,
      "values" => %{
        "title" => "Read the README",
        "description" => "People read the README.",
        "phase" => "break_down"
      },
      "links" => %{"in_scene" => ["SC-Atlas-01"], "assignment" => ["AS-" <> p.key]}
    })

    assignment(p)
  end

  defp subject(%{kind: "scene"} = p) do
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

  # The task's lease worked to its end, its result commit holding its proposal.
  defp work(c, p, task, proposal) do
    {lease, _work} = lease!()

    FakeCode.put(c.code, @repository, "refs/atlas/results/" <> task, "rev_#{task}", %{
      "README.md" => "# Atlas\n",
      p.file => JSON.encode!(proposal)
    })

    report = &WorkSource.report(@mini, %{lease_id: lease, revision: &1, report: &2})
    assert {:recorded, _} = report.(1, %{state: :accepted})
    assert {:recorded, _} = report.(2, %{state: :started})
    assert {:recorded, _} = report.(3, L.ended(nil))
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
