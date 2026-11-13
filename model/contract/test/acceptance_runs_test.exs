defmodule Model.AcceptanceRunsTest do
  @moduledoc """
  Slices 10 and 11: a use case runs on Flow's durable runs, its design on
  `design_and_accept` and its building, testing and acceptance on
  `test_and_accept_use_case`, both taking the use case from the legacy flow
  `design_and_accept`, which then drives none. Their selections; the disjoint admission
  that gives each use case one writer at any moment, and never none; the import tables
  mapped onto the use cases on test and prod; the design's acceptance and rejection, and
  its restart before the accepted output is acknowledged; the build run's start from the
  accepted design, once; its counts; the decider's verdict; reopening, which starts a new
  generation only on an explicit restart; and the migrations from the base's digests, on
  the compiled subflows of both environments.
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
  @build_base "439466529c0f51d0f91d8ace07c9f5fa6ca2cfb04bfcc4557b6ba57342b2e0f1"
  @admitted ~w(writing in_review changes_requested)

  # The model as composed, with the selections the calling test puts in its process
  # (`%{name => fun}`) changed: what Flow's runner would be given.
  defmodule Altered do
    @moduledoc false
    defdelegate runs(), to: Model.AtlasEyra
    defdelegate composition(), to: Model.AtlasEyra
    defdelegate legacy(), to: Model.AtlasEyra

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
  defp legacy, do: Enum.find(Model.AtlasEyra.legacy(), &(&1.name() == @name))

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

  # As the use cases on test and prod are today (status refine), with `issues` under it.
  defp live(design_status, issues \\ 0) do
    values = %{"title" => "A use case", "description" => "What it is", "status" => "refine"}
    values = if design_status, do: Map.put(values, "design_status", design_status), else: values
    {values, for(n <- List.duplicate(nil, issues) |> Enum.with_index(), do: issue(elem(n, 1)))}
  end

  defp issue(n), do: %{"key" => "IS-Atlas-#{n}", "links" => %{"in_use_case" => ["UC-Atlas-01"]}}

  # What the legacy flow presents for a use case: {state, expected, owner}; `extra` is what
  # Facts derives for it (`progress`, `completion`).
  defp legacy_presents({values, children}, extra \\ %{}) do
    fact = Map.merge(%{"key" => "UC-Atlas-01", "values" => values, "links" => %{}}, extra)
    {state, vars} = legacy().state(fact, children, ["in_use_case"], [])
    owner = legacy().owner(state)
    owner = owner && AtlasFlow.Model.owner(owner, actors())
    {state, legacy().expected(state, vars), owner}
  end

  # What the run presents in its state: {expected, owner}, as Flow's projection reads it.
  defp run_presents(env, name \\ @name, state, values) do
    f = flow(env, name)

    {f.present(state, values)["expected"],
     AtlasFlow.Model.owner(f.owner(state)["default"], actors())}
  end

  # Which writer presents the use case, as Flow's projection chooses it: the run of the
  # selected subflow that admits it (`{:run, name}`), `:done` when that run is completed
  # (it presents nothing, and no legacy flow takes it back), `:none` while it has no run
  # yet; `:legacy` only when no selection admits it.
  defp writer(env, values, runs) do
    case Store.selected(config(env), @kind, %{"values" => values}) do
      nil ->
        :legacy

      {name, s} ->
        run = runs[name]
        follow = s["follow_through"]

        cond do
          run == nil ->
            :none

          run["status"] == "active" ->
            {:run, name}

          follow != nil and run["state"] == follow["state"] and Run.holds?(follow["when"], values) ->
            :legacy

          true ->
            :done
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
      assert f.states() == ~w(accepted design_review designing redesign)

      b = flow(env, @build)
      assert Run.validate(b) == :ok
      assert b.states() == ~w(accepted break_down building rework to_test)
      assert b.start?(:predicate, %{"design_status" => "accepted"})
      refute b.start?(:predicate, %{"design_status" => "approved"})
      refute b.start?(:create, %{})

      for f <- [f, b] do
        # No pass, gate or effect, no create and no timer: nothing is dispatched or made for
        # a use case, and nothing is due.
        assert Enum.all?(f.states(), &(f.mechanism(&1) == nil))
        assert for(s <- f.states(), {:create, _} <- f.enter(s, %{}), do: s) == []
        assert Enum.all?(f.states(), &(f.timers(&1) == []))
        # No typed choice: nothing waits for a role's input.
        assert Enum.all?(f.states(), &(f.waiting_for(&1) == []))
      end

      # Its test is the configured decider's, as the legacy flow's is; every other state the
      # coordinator's, as there.
      assert AtlasFlow.Model.owner(b.owner("to_test")["default"], actors()) == tester()

      for s <- ~w(break_down building rework),
          do: assert(b.owner(s)["default"] == @coordinator)
    end

    for name <- [@name, @build] do
      s = selection(name)
      assert {s["subject"], s["legacy"], s["reopen"]} == {@kind, @name, "explicit"}
      assert {s["choices"], s["choice_states"]} == {[], []}
      # It presents where the legacy flow did, the only legacy flow on the kind.
      assert Map.take(legacy().writes(), Map.keys(s["projection"])) == s["projection"]
    end

    assert selection()["admission"] == %{"design_status" => @admitted}
    assert selection(@build)["admission"] == %{"design_status" => ["approved", "accepted", nil]}
    # The design's follow-through to the legacy flow is gone: no legacy flow takes a use
    # case back.
    refute Map.has_key?(selection(), "follow_through")
    refute Map.has_key?(selection(@build), "follow_through")
    assert for(l <- Model.AtlasEyra.legacy(), @kind in l.kinds(), do: l.name()) == [@name]
  end

  test "disjoint phase admission: every use case is one run's, the design's or the build's, never the legacy flow's" do
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
    for env <- @envs,
        name <- [@name, @build],
        alter <- [
          &Map.delete(&1, "legacy"),
          &Map.delete(&1, "projection"),
          &Map.put(&1, "legacy", "test_and_accept")
        ] do
      Process.put(:alter, %{name => alter})
      assert {_config, {:two_writers, _}} = Store.activate(Altered, flows(env))
    end

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
             %{"when" => %{"design_status" => ["in_review"]}, "state" => "design_review"},
             %{"when" => %{"design_status" => ["changes_requested"]}, "state" => "redesign"}
           ]

    # No row leads to the accepted end: no acceptance is made for a use case whose design
    # was approved before; it is never admitted, so it never has a design run.
    refute Enum.any?(selection()["imports"], &(&1["state"] == "accepted"))

    for env <- @envs do
      # prod 11 and test 1: writing, "Write its Design part" for the architect. No row: it
      # starts in designing, as a new one does, writing nothing; what it shows and its
      # owner stay.
      {values, _} = live("writing")
      run = new(env, values)
      assert at(run) == {"designing", "active", 1}
      refute Map.has_key?(run["last_input"], "import")
      assert run["pending"] == %{"version" => 1, "writes" => []}
      assert run["deadlines"]["timers"] == []
      {_, expected, owner} = legacy_presents(live("writing"))
      assert {expected, owner} == {"Write its Design part", @architect}
      assert run_presents(env, "designing", values) == {expected, owner}
      assert writer(env, values, %{@name => run}) == {:run, @name}

      # In review, or sent back by its review (none on test or prod today): the row joins
      # that wait, writing nothing, presenting what the legacy flow did, to the same owner.
      for {status, state, owner} <- [
            {"in_review", "design_review", @coordinator},
            {"changes_requested", "redesign", @architect}
          ] do
        {values, _} = live(status)
        run = new(env, values)
        assert at(run) == {state, "active", 1}
        assert run["last_input"] == %{"version" => 1, "import" => true}
        assert run["pending"] == %{"version" => 1, "writes" => []}
        assert run["deadlines"]["timers"] == []
        {_, expected, ^owner} = legacy_presents(live(status))
        assert run_presents(env, state, values) == {expected, owner}
        assert writer(env, values, %{@name => run}) == {:run, @name}
        # Imported where it is, it stays there: nothing moves it until its design does.
        assert {:ok, ^run} = Run.step(run, flow(env), use_case(values), @now)
      end
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
      # phase: "Build it", with or without issues (legacy breaks down only an accepted
      # design). Each imports into building, writing nothing, and its count of issues, on
      # its first entry, gives it the state the legacy flow presents, to the same owner.
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
        {^state, expected, owner} = legacy_presents(row)
        assert owner == @coordinator
        assert run_presents(env, @build, state, values) == {expected, owner}
      end

      # One whose issues are all completed is the decider's to test, in both.
      {values, children} = row = live("approved", 2)
      tested = counted(build(env, values), env, values, length(children), 0)
      assert tested["state"] == "to_test"

      {"to_test", expected, owner} =
        legacy_presents(row, %{"progress" => %{"value" => "to_test"}})

      assert owner == tester() and owner["kind"] == "person"
      assert run_presents(env, @build, "to_test", values) == {expected, owner}

      # An accepted use case (Facts derives its completion from accepted_by) is completed
      # history, whatever its design status: nothing written, nothing rerun, nothing
      # presented, as the legacy flow's done.
      for status <- ["approved", "accepted", nil] do
        {values, _} = row = live(status, 1)
        done = build(env, values, %{"completion" => %{"by" => "accepted_by"}})
        assert at(done) == {"accepted", "completed", 1}
        assert done["last_input"] == %{"version" => 1, "import" => true}
        assert done["pending"]["writes"] == []
        assert writer(env, values, %{@build => done}) == :done
        {"done", _, nil} = legacy_presents(row, %{"completed" => true, "completion" => %{}})
      end

      # One whose design run accepted it matches no row: it starts on its predicate.
      started = build(env, %{"design_status" => "accepted"})
      assert at(started) == {"break_down", "active", 1}
      refute Map.has_key?(started["last_input"], "import")
    end
  end

  test "the design's acceptance: the review's approval ends its run, which writes accepted once" do
    for env <- @envs, status <- ["approved", "accepted"] do
      f = flow(env)

      for from <- [
            sent(new(env, %{"design_status" => "in_review"})),
            new(env, %{"design_status" => "writing"}),
            new(env, %{"design_status" => "changes_requested"})
          ] do
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

  test "the design's rejection: changes requested (or writing again) send it to the rework" do
    for env <- @envs do
      f = flow(env)
      review = sent(new(env, %{"design_status" => "in_review"}))

      for status <- ["changes_requested", "writing"] do
        assert {:ok, rework} = Run.step(review, f, use_case(%{"design_status" => status}), @now)
        assert at(rework) == {"redesign", "active", 2}
        assert rework["pending"]["writes"] == [] and rework["deadlines"]["timers"] == []
        assert run_presents(env, "redesign", %{}) == {"Write its Design part", @architect}

        assert {:ok, again} =
                 Run.step(rework, f, use_case(%{"design_status" => "in_review"}), @now)

        assert at(again) == {"design_review", "active", 3}

        assert run_presents(env, "design_review", %{}) ==
                 {"Have its design reviewed", @coordinator}
      end

      writing = new(env, %{"design_status" => "writing"})

      assert {:ok, ^writing} =
               Run.step(writing, f, use_case(%{"design_status" => "changes_requested"}), @now)

      assert {:ok, reviewed} =
               Run.step(writing, f, use_case(%{"design_status" => "in_review"}), @now)

      assert at(reviewed) == {"design_review", "active", 2}
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

        assert counted(build(env, values), env, values, 1, 1)["state"] == "building"
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

      # An accepted design: issues come under it, are built, all are completed; a new one
      # opens; all are completed again.
      values = %{"design_status" => "accepted"}
      run = build(env, values)

      steps = [
        {0, 0, "break_down"},
        {1, 1, "building"},
        {2, 2, "building"},
        {2, 1, "building"},
        {2, 0, "to_test"},
        {3, 1, "building"},
        {3, 0, "to_test"}
      ]

      Enum.reduce(steps, run, fn {children, open, state}, run ->
        moved = sent(counted(run, env, values, children, open))
        assert moved["state"] == state, inspect({children, open})
        moved
      end)

      # Its issues removed while it is built: back to break down, when its design was
      # accepted; without a design phase it stays built, as in the legacy flow.
      building = counted(build(env, values), env, values, 2, 1)
      assert counted(building, env, values, 0, 0)["state"] == "break_down"
      phaseless = counted(build(env, %{}), env, %{}, 2, 1)
      assert counted(phaseless, env, %{}, 0, 0)["state"] == "building"
    end
  end

  test "the decider's verdict ends the test: accepted, or reworked until a new issue opens" do
    for env <- @envs do
      # Each entry is offered the count once: break down, built, then tested.
      values = %{"design_status" => "accepted", "children" => 2, "open_children" => 0}
      tested = counted(counted(build(env, values), env, values, 2, 0), env, values, 2, 0)
      assert at(tested) == {"to_test", "active", 3}

      # Its entry resets the verdict, so an older one moves nothing: until Facts has it,
      # the run waits; then only a new verdict moves it.
      assert [%{"content" => %{"values" => %{"verdict" => "none"}}}] = tested["pending"]["writes"]
      assert {:ok, ^tested} = step(env, tested, Map.put(values, "verdict", "accept"))
      tested = sent(tested)
      assert {:ok, ^tested} = step(env, tested, Map.put(values, "verdict", "none"))

      # Accept: completed, nothing written; the use case is completed by its accepted_by.
      assert {:ok, done} = step(env, tested, Map.put(values, "verdict", "accept"))
      assert at(done) == {"accepted", "completed", 4}
      assert done["pending"]["writes"] == []

      # Reject: reworked, by the coordinator; a new open issue sends it to building, and
      # its completion back to the decider, whose verdict is reset again.
      assert {:ok, rework} = step(env, tested, Map.put(values, "verdict", "reject"))
      assert at(rework) == {"rework", "active", 4}
      assert run_presents(env, @build, "rework", %{}) == {"Rework", @coordinator}
      rejected = Map.put(values, "verdict", "reject")
      assert {:ok, ^rework} = step(env, rework, rejected)
      again = counted(rework, env, rejected, 3, 1)
      assert at(again) == {"building", "active", 5}
      retest = counted(sent(again), env, rejected, 3, 0)
      assert at(retest) == {"to_test", "active", 6}
      assert [%{"content" => %{"values" => %{"verdict" => "none"}}}] = retest["pending"]["writes"]

      # A new open issue while it is tested sends it back to building.
      assert at(counted(tested, env, values, 3, 1)) == {"building", "active", 4}
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
          {"design_and_accept", "design_review", "Have its design reviewed"},
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
      done = sent(counted(counted(build(env, values), env, values, 1, 0), env, values, 1, 0))
      {:ok, done} = step(env, done, values)
      assert at(done) == {"accepted", "completed", 4}

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
      [m] = selection()["migrations"]
      assert {m["from"], m["to"]} == {@base, f.digest()}
      refute Map.has_key?(m, "rekey") or Map.has_key?(m, "preserve_entry")

      assert Enum.sort(Map.keys(m["states"])) ==
               ~w(accepted design_gate design_review designing dropped needs_person redesign to_accept)

      assert Enum.all?(Map.values(m["states"]), &(&1 in f.states()))

      old = fn state, status, pending ->
        new(env, %{"design_status" => "writing"})
        |> Map.merge(%{"definition_sha256" => @base, "state" => state, "status" => status})
        |> update_in(["pending"], &Map.merge(&1, pending))
      end

      # A quiescent open run of the old digest re-enters its new state, in a new entry.
      for {state, to} <- [
            {"designing", "designing"},
            {"redesign", "redesign"},
            {"design_review", "design_review"},
            {"design_gate", "design_review"},
            {"to_accept", "design_review"},
            {"needs_person", "design_review"}
          ] do
        assert {:ok, moved} = Run.migrate(old.(state, "active", %{}), f, [m], @now)
        assert at(moved) == {to, "active", 2}
        assert moved["definition_sha256"] == f.digest()
        assert [%{"from" => @base, "state" => ^state}] = moved["pending"]["migrations"]
      end

      # One with a frozen pass or gate is not quiescent: it blocks, nothing is redone.
      for {state, pending} <- [
            {"designing", %{"pass" => %{"request" => %{}}}},
            {"design_gate", %{"gate" => %{"id" => "g"}}}
          ],
          do:
            assert(
              {:error, :definition_changed} =
                Run.migrate(old.(state, "active", pending), f, [m], @now)
            )

      # An accepted run stays accepted; a dropped (cancelled) one is never taken for it.
      assert {:ok, done} = Run.migrate(old.("accepted", "completed", %{}), f, [m], @now)
      assert {done["state"], done["status"]} == {"accepted", "completed"}

      assert {:error, :definition_changed} =
               Run.migrate(old.("dropped", "completed", %{}), f, [m], @now)

      # The build run's: its states kept, each re-entered; a frozen pass blocks.
      b = flow(env, @build)
      [bm] = selection(@build)["migrations"]
      assert {bm["from"], bm["to"]} == {@build_base, b.digest()}
      refute Map.has_key?(bm, "rekey") or Map.has_key?(bm, "preserve_entry")
      assert bm["states"] == Map.new(b.states(), &{&1, &1})

      built = fn state, status, pending ->
        build(env, %{"design_status" => "accepted"})
        |> Map.merge(%{"definition_sha256" => @build_base, "state" => state, "status" => status})
        |> update_in(["pending"], &Map.merge(&1, pending))
      end

      for state <- ~w(break_down building rework) do
        assert {:ok, moved} = Run.migrate(built.(state, "active", %{}), b, [bm], @now)
        assert at(moved) == {state, "active", 2}
      end

      # Its test re-entered resets the verdict, as a new entry does.
      assert {:ok, moved} = Run.migrate(built.("to_test", "active", %{}), b, [bm], @now)
      assert [%{"content" => %{"values" => %{"verdict" => "none"}}}] = moved["pending"]["writes"]

      assert {:error, :definition_changed} =
               Run.migrate(
                 built.("rework", "active", %{"pass" => %{"request" => %{}}}),
                 b,
                 [bm],
                 @now
               )

      assert {:ok, accepted} = Run.migrate(built.("accepted", "completed", %{}), b, [bm], @now)
      assert {accepted["state"], accepted["status"]} == {"accepted", "completed"}
    end
  end
end
