defmodule Model.AcceptanceRunsTest do
  @moduledoc """
  Slices 10 and 11: a use case runs on Flow's durable runs, its design on
  `design_and_accept` and its building, testing and acceptance on
  `test_and_accept_use_case`, both taking the use case from the old flow
  `design_and_accept` (gone since slice 14). Their selections; the disjoint admission
  that gives each use case one writer at any moment, and never none; the import tables
  mapped onto the use cases on test and prod; slice 9's agent design and its
  supervisor's acceptance, and its restart before the accepted output is acknowledged;
  the build run's start from the accepted design, once; its counts; the decider's
  verdict; reopening, which starts a new generation only on an explicit restart; and
  the migrations from the base's digests, on the compiled subflows of both environments.
  """
  use ExUnit.Case, async: true

  alias AtlasFlow.Runs.{Run, Store}

  @now ~U[2026-11-13 00:00:00Z]
  @envs [:prod, :test]
  @name "design_and_accept"
  @build "test_and_accept_use_case"
  @kind "use_case"
  # The digests the base recorded before slices 10 and 11 (the same in prod and test, the
  # only one each had).
  @base "25f57fda40fa0e12d9322c7eb41a9d1829bee934777abe157f5c6a93685e377e"
  # The design's digest from slice 10 until slice 9's agent design.
  @slice10 "57752d31e8065f37845ac886a1e93b6a24dc18d4a5aaeac20707c3c76e0ce571"
  @build_base "439466529c0f51d0f91d8ace07c9f5fa6ca2cfb04bfcc4557b6ba57342b2e0f1"
  @admitted ~w(writing in_review changes_requested)

  # The model as composed, with the selections the calling test puts in its process
  # (`%{name => fun}`) changed: what Flow's runner would be given.
  defmodule Altered do
    @moduledoc false
    defdelegate runs(), to: Model.AtlasEyra
    defdelegate composition(), to: Model.AtlasEyra
    defdelegate relations(), to: Model.AtlasEyra

    def selection(name) do
      s = Model.AtlasEyra.selection(name)
      alter = Map.get(Process.get(:alter, %{}), name, & &1)
      alter.(s)
    end
  end

  defp flow(env, name \\ @name),
    do: Enum.find(Model.AtlasEyra.subflows(env), &(&1.name() == name))

  defp flows(env), do: Map.new(Model.AtlasEyra.subflows(env), &{&1.name(), &1})
  defp selection(name \\ @name), do: Model.AtlasEyra.selection(name)

  defp config(env),
    do: AtlasFlow.Model.load(Model.AtlasEyra, env, %{"decider" => "someone"}).config

  defp actors, do: elem(AtlasBus.Actors.resolve(Model.AtlasEyra.actors(), decider()), 1)
  defp decider, do: %{"decider" => "someone"}

  defp use_case(values, extra \\ %{}),
    do:
      Map.merge(
        %{"key" => "UC-Atlas-01", "version" => "v1", "position" => 11, "values" => values},
        extra
      )

  defp new(env, values),
    do: Run.new(@name, flow(env), use_case(values), selection()["imports"], @now)

  # A build run as Flow makes it for a use case its selection admits, on a full read of
  # it (`extra`: what Facts derives, its `completion`).
  defp build(env, values, extra \\ %{}),
    do:
      Run.new(
        @build,
        flow(env, @build),
        use_case(values, extra),
        selection(@build)["imports"],
        @now
      )

  # A run whose entry writes Facts acknowledged.
  defp sent(run), do: put_in(run, ["pending", "writes"], [])

  defp at(run), do: {run["state"], run["status"], run["entry"]}

  # The count of the use case's issues as the composition gives it to a run on it: the
  # changed aggregate, offered once per entry (`AtlasFlow.Runs.Store`).
  defp counted(run, env, values, children, open) do
    counts = %{"children" => children, "open_children" => open}

    offered =
      put_in(run, ["pending", "synthetic"], %{"id" => "S", "values" => counts, "sources" => []})

    {:ok, moved} =
      Run.synthetic(offered, flow(env, @build), use_case(Map.merge(values, counts)), @now)

    moved
  end

  # A step of the build run on what the use case says now, as Flow's store takes it: with
  # the selection's reopen policy.
  defp step(env, run, values, extra \\ %{}),
    do:
      Run.step(run, flow(env, @build), use_case(values, extra), @now, [],
        reopen: selection(@build)["reopen"]
      )

  # Its break-down as slice 7 runs it, from the build run's start: its agent's task
  # completed (Flow made the issues it proposed), its supervisor accepted them; built from
  # then on, with what the use case says (`values`, with its count once it has one).
  defp broken_down(env, values) do
    b = flow(env, @build)
    proposed = %{"key" => "TK-UC-Atlas-01-1", "outcome" => "completed"}

    {:ok, accepting} =
      Run.task_result(build(env, values), b, use_case(values), @now, "completed", proposed, [])

    assert at(accepting) == {"accepting", "active", 2}
    {:ok, building} = step(env, sent(accepting), Map.put(values, "verdict", "accept"))
    assert at(building) == {"building", "active", 3}
    sent(building)
  end

  # As the use cases on test and prod are today (status refine), with `issues` under it.
  defp live(design_status, issues \\ 0) do
    values = %{"title" => "A use case", "description" => "What it is", "status" => "refine"}
    values = if design_status, do: Map.put(values, "design_status", design_status), else: values
    {values, for(n <- List.duplicate(nil, issues) |> Enum.with_index(), do: issue(elem(n, 1)))}
  end

  defp issue(n), do: %{"key" => "IS-Atlas-#{n}", "links" => %{"in_use_case" => ["UC-Atlas-01"]}}

  # What the run presents in its state: {expected, owner}, as Flow's projection reads it.
  defp run_presents(env, name \\ @name, state, values) do
    f = flow(env, name)

    {f.present(state, values)["expected"],
     AtlasFlow.Model.owner(f.owner(state)["default"], actors())}
  end

  # Which writer presents the use case, as Flow's projection chooses it: the run of the
  # selected subflow that admits it (`{:run, name}`), `:done` when that run is completed
  # (it presents nothing), `:none` while it has no run yet; `:nobody` when no selection
  # admits it.
  defp writer(env, values, runs) do
    case Store.selected(config(env), @kind, %{"values" => values}) do
      nil ->
        :nobody

      {name, _s} ->
        run = runs[name]

        cond do
          run == nil -> :none
          run["status"] == "active" -> {:run, name}
          true -> :done
        end
    end
  end

  @architect %{"kind" => "agent", "key" => "architect"}
  @coordinator %{"kind" => "agent", "key" => "coordinator"}
  # The configured decider, as the environment's settings resolve it (`decider/0`).
  defp tester, do: actors()["decider"]

  test "both selected in both environments, runnable, and together the one writer of a use case" do
    for env <- @envs do
      runner = AtlasFlow.Model.load(Model.AtlasEyra, env, decider())
      assert runner.refusal == nil
      assert Map.has_key?(runner.config["selection"], @name)
      assert Map.has_key?(runner.config["selection"], @build)

      f = flow(env)
      assert Run.validate(f) == :ok
      assert f.states() == ~w(accepted accepting designing)
      assert AtlasFlow.Model.owner(f.owner("accepting")["default"], actors()) == tester()

      b = flow(env, @build)
      assert Run.validate(b) == :ok
      assert b.states() == ~w(accepted accepting break_down building rework to_test)
      assert b.start?(:predicate, %{"design_status" => "accepted"})
      refute b.start?(:predicate, %{"design_status" => "approved"})
      refute b.start?(:create, %{})

      for f <- [f, b] do
        # No pass, gate or effect, no create and no timer: nothing is dispatched or made for
        # a use case but its design's and its break-down's task (slices 9 and 7), and
        # nothing is due.
        assert for(s <- f.states(), f.mechanism(s) != nil, do: s) ==
                 if(f == b, do: ["break_down"], else: ["designing"])

        assert for(s <- f.states(), {:create, _} <- f.enter(s, %{}), do: s) == []
        assert Enum.all?(f.states(), &(f.timers(&1) == []))
        # No typed choice: nothing waits for a role's input.
        assert Enum.all?(f.states(), &(f.waiting_for(&1) == []))
      end

      # Its test and the acceptance of its issues are the configured decider's (its
      # supervisor's, once picked up); every other state the coordinator's.
      for s <- ~w(to_test accepting),
          do: assert(AtlasFlow.Model.owner(b.owner(s)["default"], actors()) == tester())

      for s <- ~w(break_down building rework),
          do: assert(b.owner(s)["default"] == @coordinator)
    end

    for name <- [@name, @build] do
      s = selection(name)
      assert {s["subject"], s["reopen"]} == {@kind, "explicit"}
      assert {s["choices"], s["choice_states"]} == {[], []}
    end

    # One projection: one presenter presents a use case, through both.
    assert selection()["projection"] == selection(@build)["projection"]

    assert selection()["admission"] == %{"design_status" => @admitted}
    assert selection(@build)["admission"] == %{"design_status" => ["approved", "accepted", nil]}
  end

  test "disjoint phase admission: every use case is one run's, the design's or the build's, never none" do
    for env <- @envs do
      c = config(env)

      for status <- @admitted,
          do:
            assert(
              {@name, _} = Store.selected(c, @kind, %{"values" => %{"design_status" => status}})
            )

      # From its acceptance on, and without a design phase, the build run presents it.
      for values <- [
            %{"design_status" => "approved"},
            %{"design_status" => "accepted"},
            %{"design_status" => ""},
            %{"design_status" => nil},
            %{}
          ],
          do: assert({@build, _} = Store.selected(c, @kind, %{"values" => values}))

      # Every value the field can have, and none: exactly one selection admits it.
      %{"values" => values} = get_in(Model.AtlasEyra.rela_schema(), ["types", "design_status"])

      for v <- [nil | values] do
        admits =
          for {name, s} <- c["selection"],
              s["subject"] == @kind,
              Run.holds?(s["admission"], %{"design_status" => v}),
              do: name

        assert length(admits) == 1, inspect(v)
      end
    end
  end

  test "a selection that would give a use case two writers is refused" do
    # The build run may admit none the design admits: overlapping, every run is refused;
    # disjoint (as selected), none is.
    for env <- @envs do
      for overlapping <- [
            [],
            %{"design_status" => ["accepted", "writing"]},
            %{"design_status" => [nil, "in_review"]}
          ] do
        Process.put(:alter, %{@build => &Map.put(&1, "admission", overlapping)})
        assert {_config, {:two_writers, _}} = Store.activate(Altered, flows(env))
      end

      Process.put(:alter, %{})
      assert {_config, nil} = Store.activate(Altered, flows(env))
    end
  end

  test "every import row of the design, mapped onto the use cases on test and prod" do
    assert selection()["imports"] == [
             %{"when" => %{"design_status" => ["in_review"]}, "state" => "accepting"}
           ]

    # No row leads to the accepted end: no acceptance is made for a use case whose design
    # was approved before; it is never admitted, so it never has a design run.
    refute Enum.any?(selection()["imports"], &(&1["state"] == "accepted"))

    for env <- @envs do
      # Writing, or sent back by its review: no row. It starts in designing, as a new one
      # does, writing nothing, for the architect until a person picks it up.
      for status <- ["writing", "changes_requested"] do
        {values, _} = live(status)
        run = new(env, values)
        assert at(run) == {"designing", "active", 1}
        refute Map.has_key?(run["last_input"], "import")
        assert run["pending"] == %{"version" => 1, "writes" => []}
        assert run["deadlines"]["timers"] == []
        assert run_presents(env, "designing", values) == {"Write its Design part", @architect}
        assert writer(env, values, %{@name => run}) == {:run, @name}
      end

      # In review (its design written by hand): the row joins its acceptance, writing
      # nothing, for the decider until a person picks it up.
      {values, _} = live("in_review")
      run = new(env, values)
      assert at(run) == {"accepting", "active", 1}
      assert run["last_input"] == %{"version" => 1, "import" => true}
      assert run["pending"] == %{"version" => 1, "writes" => []}
      assert run_presents(env, "accepting", values) == {"Accept its design", tester()}
      assert writer(env, values, %{@name => run}) == {:run, @name}
      # Imported where it is, it stays there: nothing moves it until it is accepted.
      assert {:ok, ^run} = Run.step(run, flow(env), use_case(values), @now)
    end
  end

  test "every import row of the build, mapped onto the use cases on test and prod" do
    assert selection(@build)["imports"] == [
             %{"completed" => true, "state" => "accepted"},
             %{"when" => %{"design_status" => ["approved"]}, "state" => "building"},
             %{"when" => %{"design_status" => [nil]}, "state" => "building"}
           ]

    for env <- @envs do
      # prod 5, approved, issues under it not all completed: "Build it", the coordinator's.
      # prod 3, approved, nothing under it: "Break it down into issues". test 2, no design
      # phase: "Build it", with or without issues (only an accepted design is broken down
      # when nothing is under it). Each imports into building, writing nothing, and its
      # count of issues, on its first entry, gives it the state it was presented in, to
      # the same owner.
      for {status, issues, open, state} <- [
            {"approved", 2, 2, "building"},
            {"approved", 3, 1, "building"},
            {"approved", 0, 0, "break_down"},
            {nil, 0, 0, "building"},
            {nil, 2, 1, "building"}
          ] do
        {values, children} = row = live(status, issues)
        run = build(env, values)
        assert at(run) == {"building", "active", 1}, inspect(row)
        assert run["last_input"] == %{"version" => 1, "import" => true}
        assert run["pending"] == %{"version" => 1, "writes" => []}
        assert run["deadlines"]["timers"] == []
        assert writer(env, values, %{@build => run}) == {:run, @build}

        settled = counted(run, env, values, length(children), open)
        assert settled["state"] == state, inspect(row)
        assert settled["pending"]["writes"] == []
        assert {expected, @coordinator} = run_presents(env, @build, state, values)
        assert expected != ""
      end

      # One whose issues are all completed is the decider's to test, in both.
      {values, children} = live("approved", 2)
      tested = counted(build(env, values), env, values, length(children), 0)
      assert tested["state"] == "to_test"
      {_expected, owner} = run_presents(env, @build, "to_test", values)
      assert owner == tester() and owner["kind"] == "person"

      # An accepted use case (Facts derives its completion from accepted_by) is completed
      # history, whatever its design status: nothing written, nothing rerun, nothing
      # presented.
      for status <- ["approved", "accepted", nil] do
        {values, _} = live(status, 1)
        done = build(env, values, %{"completion" => %{"by" => "accepted_by"}})
        assert at(done) == {"accepted", "completed", 1}
        assert done["last_input"] == %{"version" => 1, "import" => true}
        assert done["pending"]["writes"] == []
        assert writer(env, values, %{@build => done}) == :done
      end

      # One whose design run accepted it matches no row: it starts on its predicate.
      started = build(env, %{"design_status" => "accepted"})
      assert at(started) == {"break_down", "active", 1}
      refute Map.has_key?(started["last_input"], "import")
    end
  end

  test "the design's acceptance: its supervisor's Accept ends its run, which writes accepted once" do
    for env <- @envs, status <- ["approved", "accepted"] do
      f = flow(env)
      designed = %{"key" => "TK-UC-Atlas-01-1", "outcome" => "completed"}

      {:ok, accepting} =
        Run.task_result(
          new(env, %{"design_status" => "writing"}),
          f,
          use_case(%{}),
          @now,
          "completed",
          designed,
          []
        )

      for from <- [sent(new(env, %{"design_status" => "in_review"})), sent(accepting)] do
        assert {:ok, accepted} = Run.step(from, f, use_case(%{"design_status" => status}), @now)
        assert at(accepted) == {"accepted", "completed", from["entry"] + 1}
        assert accepted["deadlines"]["timers"] == []

        assert [%{"id" => id, "kind" => @kind, "content" => content}] =
                 accepted["pending"]["writes"]

        assert content == %{
                 "op" => "change",
                 "key" => "UC-Atlas-01",
                 "values" => %{"design_status" => "accepted"},
                 "by" => "flow"
               }

        # The same entry gives the same id: a replay is the same write, stored once.
        assert {:ok, %{"pending" => %{"writes" => [%{"id" => ^id}]}}} =
                 Run.step(from, f, use_case(%{"design_status" => status}), @now)

        # Completed: nothing moves it again, whatever the use case says later.
        done = sent(accepted)

        for later <- ["writing", "in_review", "approved"],
            do:
              assert(
                {:ok, ^done} = Run.step(done, f, use_case(%{"design_status" => later}), @now)
              )
      end
    end
  end

  test "the agent's design: however its task ends, Accept its design is next; nothing by hand moves it" do
    for env <- @envs do
      f = flow(env)
      writing = new(env, %{"design_status" => "writing"})
      assert f.mechanism("designing") != nil

      for outcome <- ["completed", "check_failed", "stuck", "abandoned"] do
        ended = %{"key" => "TK-UC-Atlas-01-1", "outcome" => outcome}

        assert {:ok, accepting} =
                 Run.task_result(writing, f, use_case(%{}), @now, outcome, ended, [])

        assert at(accepting) == {"accepting", "active", 2}
      end

      # A design status written by hand moves nothing while the agent designs it.
      for status <- ["in_review", "changes_requested", "approved"],
          do:
            assert(
              {:ok, ^writing} = Run.step(writing, f, use_case(%{"design_status" => status}), @now)
            )

      # Its acceptance is the supervisor's (the decider's until one picked it up): Accept
      # approves the design.
      {expected, owner} = run_presents(env, "accepting", %{})
      assert {expected, owner} == {"Accept its design", tester()}

      assert [%{"label" => "Accept", "change" => %{"values" => %{"design_status" => "approved"}}}] =
               get_in(f.present("accepting", %{}), ["todo", "answers"])
    end
  end

  test "restarted before the design's accepted output is acknowledged: replayed, never redone" do
    for env <- @envs do
      c = config(env)
      f = flow(env)
      review = sent(new(env, %{"design_status" => "in_review"}))
      {:ok, accepted} = Run.step(review, f, use_case(%{"design_status" => "approved"}), @now)
      [write] = accepted["pending"]["writes"]

      # What Facts keeps, read back by a new Flow with a freshly compiled subflow: the
      # same completed run, its write still owed under the same id.
      stored = %{"key" => accepted["key"], "values" => Store.encode(c, accepted)}
      assert {:ok, ^accepted} = Store.decode(c, stored)
      assert {:ok, ^accepted} = Run.migrate(accepted, flow(env), selection()["migrations"], @now)

      assert {:ok, ^accepted} =
               Run.step(accepted, flow(env), use_case(%{"design_status" => "approved"}), @now)

      assert accepted["pending"]["writes"] == [write]

      # Meanwhile, and after, the build run presents it, never the design run: the
      # review's approved is the design's acceptance, as is the accepted it writes. Before
      # its write lands the approved use case imports into building; after, it starts on
      # its predicate in break_down; its count gives either the same state.
      for status <- ["approved", "accepted"] do
        values = %{"design_status" => status}
        run = counted(build(env, values), env, values, 0, 0)
        assert writer(env, values, %{@name => accepted, @build => run}) == {:run, @build}
        assert run["state"] == "break_down"

        assert run_presents(env, @build, "break_down", values) ==
                 {"Break it down into issues", @coordinator}
      end
    end
  end

  test "the build run starts from the accepted design once, on its own cursor" do
    for env <- @envs do
      b = flow(env, @build)
      accepted = %{"design_status" => "accepted"}

      # The same use case gives the same run: the same key and the same entry, however
      # often it is made (a restart between the design's acceptance and the build run's
      # creation makes it again; Facts keeps the first, its key is stable).
      first = build(env, accepted)
      assert build(env, accepted) == first
      assert first["key"] == Run.key(@build, @kind, "UC-Atlas-01", 1)
      assert at(first) == {"break_down", "active", 1}
      assert first["pending"]["writes"] == []

      # The design run is another run, with its own key and cursor: they share nothing.
      design = new(env, %{"design_status" => "in_review"})
      assert design["key"] != first["key"]
      assert design["flow"] == @name and first["flow"] == @build

      # Started, the predicate starts nothing again, whether it holds or not.
      for later <- ["accepted", "writing", "approved"] do
        {:ok, again} = step(env, first, %{"design_status" => later})
        assert at(again) == at(first)
        assert again["generation"] == 1
      end

      # A build run made while the use case was not yet accepted waits idle, and starts on
      # the predicate's edge, once.
      idle = Run.new(@build, b, use_case(%{"design_status" => "in_review"}), [], @now)
      assert idle["status"] == "idle"
      {:ok, started} = step(env, idle, accepted)
      assert at(started) == {"break_down", "active", 1}
      assert {:ok, ^started} = step(env, started, accepted)
    end
  end

  test "the count of its issues moves the build run, and never the design run" do
    count = Enum.find(Model.AtlasEyra.composition()["counts"], &(&1["parent_subject"] == @kind))
    assert {count["child"], count["all"], count["open"]} == {"issue", "children", "open_children"}

    for env <- @envs do
      # Offered to the design run, at its entry, the count is dropped: no state of it reads one.
      for status <- @admitted do
        run = new(env, %{"design_status" => status})

        offered =
          put_in(run, ["pending", "synthetic"], %{
            "id" => "S-1",
            "values" => %{"children" => 2, "open_children" => 1},
            "sources" => []
          })

        assert {:ok, ^run} =
                 Run.synthetic(offered, flow(env), use_case(%{"design_status" => status}), @now)
      end

      # An accepted design: a count alone never ends its break-down, its agent's proposal
      # does; once accepted, its issues are built, all are completed; a new one opens; all
      # are completed again.
      values = %{"design_status" => "accepted"}
      assert counted(build(env, values), env, values, 1, 1)["state"] == "break_down"

      steps = [
        {1, 1, "building"},
        {2, 2, "building"},
        {2, 1, "building"},
        {2, 0, "to_test"},
        {3, 1, "building"},
        {3, 0, "to_test"}
      ]

      Enum.reduce(steps, broken_down(env, values), fn {children, open, state}, run ->
        moved = sent(counted(run, env, values, children, open))
        assert moved["state"] == state, inspect({children, open})
        moved
      end)

      # Its issues removed while it is built: back to break down, when its design was
      # accepted; without a design phase it stays built, as before.
      building = counted(broken_down(env, values), env, values, 2, 1)
      assert counted(building, env, values, 0, 0)["state"] == "break_down"
      phaseless = counted(build(env, %{}), env, %{}, 2, 1)
      assert counted(phaseless, env, %{}, 0, 0)["state"] == "building"
    end
  end

  test "the decider's verdict ends the test: accepted, or reworked until a new issue opens" do
    for env <- @envs do
      # Each entry is offered the count once: broken down, built, then tested.
      values = %{"design_status" => "accepted", "children" => 2, "open_children" => 0}
      tested = counted(broken_down(env, values), env, values, 2, 0)
      assert at(tested) == {"to_test", "active", 4}

      # Its entry resets the verdict, so an older one moves nothing: until Facts has it,
      # the run waits; then only a new verdict moves it.
      assert [%{"content" => %{"values" => %{"verdict" => "none"}}}] = tested["pending"]["writes"]
      assert {:ok, ^tested} = step(env, tested, Map.put(values, "verdict", "accept"))
      tested = sent(tested)
      assert {:ok, ^tested} = step(env, tested, Map.put(values, "verdict", "none"))

      # Accept: completed, nothing written; the use case is completed by its accepted_by.
      assert {:ok, done} = step(env, tested, Map.put(values, "verdict", "accept"))
      assert at(done) == {"accepted", "completed", 5}
      assert done["pending"]["writes"] == []

      # Reject: reworked, by the coordinator; a new open issue sends it to building, and
      # its completion back to the decider, whose verdict is reset again.
      assert {:ok, rework} = step(env, tested, Map.put(values, "verdict", "reject"))
      assert at(rework) == {"rework", "active", 5}
      assert run_presents(env, @build, "rework", %{}) == {"Rework", @coordinator}
      rejected = Map.put(values, "verdict", "reject")
      assert {:ok, ^rework} = step(env, rework, rejected)
      again = counted(rework, env, rejected, 3, 1)
      assert at(again) == {"building", "active", 6}
      retest = counted(sent(again), env, rejected, 3, 0)
      assert at(retest) == {"to_test", "active", 7}
      assert [%{"content" => %{"values" => %{"verdict" => "none"}}}] = retest["pending"]["writes"]

      # A new open issue while it is tested sends it back to building.
      assert at(counted(tested, env, values, 3, 1)) == {"building", "active", 5}
    end
  end

  # The assignment as Facts answers it to Control: the work on the subject presented
  # (`AtlasFacts.Presentation`) from its active run of `flow` in the state it wrote.
  defp presented(assignment, fact, flow) do
    p = Enum.find(Model.AtlasEyra.presentation(), &(&1["subject"] == @kind))
    state = assignment["values"]["flow_state"]

    run = %{
      "key" => "R-1",
      "flow" => flow,
      "generation" => 1,
      "status" => "active",
      "state" => state
    }

    shown = AtlasFacts.Presentation.view(p, assignment, fact, [run], fn -> false end)
    Map.put(assignment, "presentation", shown)
  end

  test "the decider's answers write the verdict, Accept with accepted_by, Reject with a note" do
    fact = %{
      "key" => "UC-Atlas-01",
      "values" => %{"design_status" => "accepted"},
      "links" => %{"assignment" => ["AS-UC-Atlas-01"]}
    }

    assignment =
      %{
        "key" => "AS-UC-Atlas-01",
        "values" => %{"flow_state" => "to_test", "expected" => "Test it"},
        "links" => %{"assigned_to" => ["someone"]}
      }
      |> presented(fact, @build)

    item = %{"fact" => fact, "parts" => %{"assignment" => assignment}}
    viewer = %{key: "someone", kind: "person"}

    assert %{answers: answers} =
             Model.AtlasEyra.todo(@kind, fact, %{"assignment" => assignment}, viewer)

    assert Enum.map(answers, &{&1.key, &1.label, &1.change}) == [
             {"a", "Accept", true},
             {"f", "Reject", true}
           ]

    assert {:write,
            %{"values" => %{"verdict" => "accept"}, "self" => "accepted_by", "note" => false}} =
             Model.AtlasEyra.answer(@kind, "a", item, viewer)

    assert {:write, %{"values" => %{"verdict" => "reject"}, "self" => nil, "note" => true}} =
             Model.AtlasEyra.answer(@kind, "f", item, viewer)

    # As Control sends them: one change each, Accept naming the one who answers.
    {:write, accept} = Model.AtlasEyra.answer(@kind, "a", item, viewer)
    {:write, reject} = Model.AtlasEyra.answer(@kind, "f", item, viewer)

    assert {:ok,
            %{"values" => %{"verdict" => "accept"}, "links" => %{"accepted_by" => ["someone"]}},
            _} =
             AtlasControl.Answers.change(accept, "UC-Atlas-01", "someone", "", @now)

    assert {:ok, %{"values" => %{"verdict" => "reject"}, "links" => links}, "Not yet"} =
             AtlasControl.Answers.change(reject, "UC-Atlas-01", "someone", "Not yet", @now)

    assert links == %{}

    # Each state of either run on the use case shows its own presentation in Control.
    for {flow, state, expected} <- [
          {"design_and_accept", "designing", "Write its Design part"},
          {"design_and_accept", "accepting", "Accept its design"},
          {@build, "break_down", "Break it down into issues"},
          {@build, "building", "Build it"}
        ] do
      a =
        presented(
          %{assignment | "values" => %{"flow_state" => state, "expected" => expected}},
          fact,
          flow
        )

      assert %{expected: ^expected} =
               Model.AtlasEyra.todo(@kind, fact, %{"assignment" => a}, viewer)
    end
  end

  test "reopened work starts a new generation only on an explicit restart" do
    for env <- @envs do
      b = flow(env, @build)
      values = %{"design_status" => "accepted", "verdict" => "accept"}
      done = sent(counted(broken_down(env, values), env, values, 1, 0))
      {:ok, done} = step(env, done, values)
      assert at(done) == {"accepted", "completed", 5}

      # Reopened: accepted_by removed (Facts no longer completes it), its issues reopened,
      # its design put back and accepted again (the predicate false, then true). The
      # completed run stays as it is, generation 1, and nothing else is made.
      reopened = [
        {%{"design_status" => "accepted", "verdict" => "accept"}, %{"completion" => nil}},
        {%{"design_status" => "accepted", "open_children" => 1}, %{}},
        {%{"design_status" => "writing"}, %{}},
        {%{"design_status" => "accepted"}, %{}}
      ]

      for {values, extra} <- reopened do
        assert {:ok, ^done} = step(env, done, values, extra)
      end

      # The explicit restart is the only way to a new generation: a new run, its own key,
      # started on the accepted design; never one that is not completed.
      assert {:ok, second} =
               Run.restart(done, b, use_case(%{"design_status" => "accepted"}), @now)

      assert {second["generation"], at(second)} == {2, {"break_down", "active", 1}}
      assert second["key"] == Run.key(@build, @kind, "UC-Atlas-01", 2)
      assert second["key"] != done["key"]
      assert {:error, :not_completed} = Run.restart(second, b, use_case(values), @now)

      # The policy decides: had the selection declared reopening a new generation, the
      # predicate's edge would have started one by itself.
      {:ok, unedged} =
        Run.step(done, b, use_case(%{"design_status" => "writing"}), @now, [],
          reopen: "new_generation"
        )

      {:ok, restarted} =
        Run.step(unedged, b, use_case(%{"design_status" => "accepted"}), @now, [],
          reopen: "new_generation"
        )

      assert restarted["generation"] == 2
    end
  end

  test "the changes from the base's digests are declared state migrations, never re-keys" do
    for env <- @envs do
      f = flow(env)
      ms = selection()["migrations"]

      assert Enum.sort(Enum.map(ms, &{&1["from"], &1["to"]})) ==
               Enum.sort([{@base, @slice10}, {@slice10, f.digest()}])

      refute Enum.any?(ms, &(Map.has_key?(&1, "rekey") or Map.has_key?(&1, "preserve_entry")))
      [m] = for m <- ms, m["from"] == @base, do: m

      assert Enum.sort(Map.keys(m["states"])) ==
               ~w(accepted design_gate design_review designing dropped needs_person redesign to_accept)

      old = fn digest, state, status, pending ->
        new(env, %{"design_status" => "writing"})
        |> Map.merge(%{"definition_sha256" => digest, "state" => state, "status" => status})
        |> update_in(["pending"], &Map.merge(&1, pending))
      end

      # Every design run on prod and test is at slice 10's digest. A quiescent open one
      # re-enters its new state, in a new entry: slice 9's agent designs one that was
      # designed or reworked by hand; one whose design waited for review is its
      # supervisor's to accept.
      for {state, to} <- [
            {"designing", "designing"},
            {"redesign", "designing"},
            {"design_review", "accepting"}
          ] do
        assert {:ok, moved} = Run.migrate(old.(@slice10, state, "active", %{}), f, ms, @now)
        assert at(moved) == {to, "active", 2}
        assert moved["definition_sha256"] == f.digest()
        assert [%{"from" => @slice10, "state" => ^state}] = moved["pending"]["migrations"]
      end

      # One with a frozen pass is not quiescent: it blocks, nothing is redone.
      assert {:error, :definition_changed} =
               Run.migrate(
                 old.(@slice10, "designing", "active", %{"pass" => %{"request" => %{}}}),
                 f,
                 ms,
                 @now
               )

      # An accepted run stays accepted.
      assert {:ok, done} = Run.migrate(old.(@slice10, "accepted", "completed", %{}), f, ms, @now)
      assert {done["state"], done["status"]} == {"accepted", "completed"}

      # The build run's (slice 11, then slice 7's break-down; every run on prod and test
      # is at slice 11's): its states kept, each re-entered; a frozen pass blocks.
      b = flow(env, @build)
      bm = selection(@build)["migrations"]
      slice11 = "d4222657ad88e5d0310136893bd47f89e9a447874ede4d0c21067622728d1b04"

      assert Enum.sort(Enum.map(bm, &{&1["from"], &1["to"]})) ==
               Enum.sort([{@build_base, slice11}, {slice11, b.digest()}])

      refute Enum.any?(bm, &(Map.has_key?(&1, "rekey") or Map.has_key?(&1, "preserve_entry")))
      old_states = b.states() -- ["accepting"]
      assert Enum.all?(bm, &(&1["states"] == Map.new(old_states, fn s -> {s, s} end)))

      built = fn state, status, pending ->
        build(env, %{"design_status" => "accepted"})
        |> Map.merge(%{"definition_sha256" => slice11, "state" => state, "status" => status})
        |> update_in(["pending"], &Map.merge(&1, pending))
      end

      for state <- ~w(break_down building rework) do
        assert {:ok, moved} = Run.migrate(built.(state, "active", %{}), b, bm, @now)
        assert at(moved) == {state, "active", 2}
      end

      # Its test re-entered resets the verdict, as a new entry does.
      assert {:ok, moved} = Run.migrate(built.("to_test", "active", %{}), b, bm, @now)
      assert [%{"content" => %{"values" => %{"verdict" => "none"}}}] = moved["pending"]["writes"]

      assert {:error, :definition_changed} =
               Run.migrate(
                 built.("rework", "active", %{"pass" => %{"request" => %{}}}),
                 b,
                 bm,
                 @now
               )

      assert {:ok, accepted} = Run.migrate(built.("accepted", "completed", %{}), b, bm, @now)
      assert {accepted["state"], accepted["status"]} == {"accepted", "completed"}
    end
  end
end
