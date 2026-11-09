defmodule Model.SceneRunsTest do
  @moduledoc """
  Slice 12: a scene runs on Flow's durable runs, its building, testing and acceptance on
  `test_and_accept_scene`, which takes every scene (the old flow `test_and_accept` went
  in slice 14).
  Its selection; the import table mapped onto the scenes on test and prod, each keeping
  what it presents and its owner; the count of its use cases (empty and not, as use cases
  open and complete); the decider's verdict; restart while it is tested; reopening (of
  the scene, or of a use case under it after it was accepted), which starts a new
  generation only on an explicit restart; and the migration from the base's digest, on
  the compiled subflow of both environments.
  """
  use ExUnit.Case, async: true

  alias AtlasFlow.Composition.Counts
  alias AtlasFlow.Runs.{Run, Store}

  @now ~U[2026-11-13 00:00:00Z]
  @envs [:prod, :test]
  @name "test_and_accept_scene"
  @kind "scene"
  @child "test_and_accept_use_case"
  # The digest the base recorded before slice 12 (the same in prod and test, the only one).
  @base "79141c9da4b0fe990b2add3265ce542b546a0a68f9922e0128c502aa5ae1b444"

  # The model as composed, with the selections the calling test puts in its process
  # (`%{name => fun}`) changed: what Flow's runner would be given.
  defp flow(env, name \\ @name),
    do: Enum.find(Model.AtlasEyra.subflows(env), &(&1.name() == name))

  defp selection, do: Model.AtlasEyra.selection(@name)
  defp decider, do: %{"decider" => "someone"}
  defp runner(env), do: AtlasFlow.Model.load(Model.AtlasEyra, env, decider())
  defp actors, do: elem(AtlasBus.Actors.resolve(Model.AtlasEyra.actors(), decider()), 1)
  defp tester, do: actors()["decider"]
  @coordinator %{"kind" => "agent", "key" => "coordinator"}

  defp scene(values, extra \\ %{}),
    do:
      Map.merge(
        %{"key" => "SC-Atlas-01", "version" => "v1", "position" => 11, "values" => values},
        extra
      )

  # A run as Flow makes it for a scene, on a full read of it (`extra`: what Facts
  # derives, its `completion`).
  defp new(env, values, extra \\ %{}),
    do: Run.new(@name, flow(env), scene(values, extra), selection()["imports"], @now)

  # A run whose entry writes Facts acknowledged.
  defp sent(run), do: put_in(run, ["pending", "writes"], [])
  defp at(run), do: {run["state"], run["status"], run["entry"]}

  # The count of the scene's use cases as the composition gives it to its run: the changed
  # aggregate, offered once per entry (`AtlasFlow.Runs.Store`).
  defp counted(run, env, values, children, open) do
    counts = %{"children" => children, "open_children" => open}

    offered =
      put_in(run, ["pending", "synthetic"], %{"id" => "S", "values" => counts, "sources" => []})

    {:ok, moved} = Run.synthetic(offered, flow(env), scene(Map.merge(values, counts)), @now)
    moved
  end

  # A step of the run on what the scene says now, as Flow's store takes it: with the
  # selection's reopen policy.
  defp step(env, run, values, extra \\ %{}),
    do: Run.step(run, flow(env), scene(values, extra), @now, [], reopen: selection()["reopen"])

  # As the scenes on test and prod are today (status refine).
  @live %{"title" => "A scene", "description" => "What it is", "status" => "refine"}

  # What the run presents in its state: {expected, owner}, as Flow's projection reads it.
  defp run_presents(env, state, values) do
    f = flow(env)

    {f.present(state, values)["expected"],
     AtlasFlow.Model.owner(f.owner(state)["default"], actors())}
  end

  test "selected in both environments, runnable, the one writer of every scene" do
    for env <- @envs do
      r = runner(env)
      assert r.refusal == nil
      # Every generated subflow is selected now.
      assert Enum.sort(Map.keys(r.config["selection"])) ==
               Enum.sort(Enum.map(Model.AtlasEyra.subflows(env), & &1.name()))

      assert map_size(r.config["selection"]) == 10

      f = flow(env)
      assert Run.validate(f) == :ok
      assert f.states() == ~w(accepted break_down building rework to_test)
      assert f.initial() == "break_down"
      assert f.start?(:create, scene(%{}))

      # No pass, gate or effect, no create and no timer: nothing is dispatched or made for
      # a scene, and nothing is due. No typed choice: nothing waits for a role's input.
      assert Enum.all?(f.states(), &(f.mechanism(&1) == nil))
      assert for(s <- f.states(), {:create, _} <- f.enter(s, %{}), do: s) == []
      assert Enum.all?(f.states(), &(f.timers(&1) == []))
      assert Enum.all?(f.states(), &(f.waiting_for(&1) == []))

      # Its test is the configured decider's; every other state the coordinator's.
      assert AtlasFlow.Model.owner(f.owner("to_test")["default"], actors()) == tester()
      for s <- ~w(break_down building rework), do: assert(f.owner(s)["default"] == @coordinator)

      # Every scene is admitted, whatever it holds.
      for values <- [%{}, @live, %{"status" => "ready_to_pick_up"}, %{"verdict" => "accept"}],
          do: assert({@name, _} = Store.selected(r.config, @kind, %{"values" => values}))

      # The scene's count of its use cases applies (both ends are selected).
      assert Enum.find(r.config["composition"]["counts"], &(&1["parent_subject"] == @kind)) ==
               %{
                 "all" => "children",
                 "open" => "open_children",
                 "child" => @child,
                 "child_subject" => "use_case",
                 "parent_subject" => @kind,
                 "relation" => "in_scene"
               }
    end

    s = selection()
    assert {s["subject"], s["reopen"]} == {@kind, "explicit"}
    assert {s["choices"], s["choice_states"], s["admission"]} == {[], [], []}
    assert s["projection"]["on"] == "assignment"
  end

  # The scenes as the coordinator read them on test and prod before slice 12 (no scene
  # had a run): {env, scene, expected, use cases under it, how many of them
  # are open at least}. Progress shows the least far open use cases' stage, and how many
  # of all are there (Refine · 2/3: two of three at Refine), so at least that many are open,
  # and at most all of them; the import is the same for every number in between.
  @rows [
    {:prod, "SC-Atlas-01", "Build it", 1, 1},
    {:prod, "SC-Atlas-02", "Build it", 3, 2},
    {:prod, "SC-Atlas-03", "Build it", 1, 1},
    {:prod, "SC-Atlas-04", "Build it", 4, 3},
    {:prod, "SC-Atlas-05", "Build it", 3, 2},
    {:prod, "SC-Atlas-06", "Build it", 4, 4},
    {:prod, "SC-Atlas-07", "Build it", 2, 1},
    {:prod, "SC-Atlas-08", "Build it", 1, 1},
    {:test, "SC-Atlas-01", "Build it", 1, 1},
    {:test, "SC-Atlas-02", "Break it down into use cases and issues", 0, 0},
    {:test, "SC-Atlas-04", "Build it", 1, 1},
    {:test, "SC-Atlas-09", "Build it", 1, 1}
  ]

  test "every import row, mapped onto the scenes on test and prod" do
    assert selection()["imports"] == [
             %{"completed" => true, "state" => "accepted"},
             %{"completed" => false, "state" => "building"}
           ]

    assert length(@rows) == 12

    for {env, key, expected, children, least_open} = row <- @rows,
        open <- Enum.uniq([least_open, children]) do
      # Not completed (Facts derives no completion: nobody accepted it): it joins building,
      # writing nothing, with no timer; no scene holds a count yet.
      run = new(env, @live)
      assert at(run) == {"building", "active", 1}, inspect(row)
      assert run["last_input"] == %{"version" => 1, "import" => true}
      assert run["pending"] == %{"version" => 1, "writes" => []}
      assert run["deadlines"]["timers"] == []
      refute Map.has_key?(@live, "children")

      # The count of its use cases, given to the run on its first entry, gives it the
      # state it was presented in, to the same owner: building while one is open,
      # break_down with none under it (test SC-Atlas-02).
      settled = counted(run, env, @live, children, open)
      state = if children == 0, do: "break_down", else: "building"
      assert settled["state"] == state, inspect(row)
      assert settled["status"] == "active"
      assert settled["pending"]["writes"] == []
      assert run_presents(env, state, @live) == {expected, @coordinator}, inspect({key, row})

      # Once there, the same count moves it no further.
      assert counted(sent(settled), env, @live, children, open)["state"] == state
    end

    for env <- @envs do
      # One whose use cases are all completed (none on test or prod today) is the
      # decider's to test.
      tested = counted(new(env, @live), env, @live, 2, 0)
      assert tested["state"] == "to_test"
      assert {_expected, owner} = run_presents(env, "to_test", @live)
      assert owner == tester() and owner["kind"] == "person"

      # An accepted scene (Facts derives its completion from accepted_by; none on test or
      # prod today) is completed history: nothing written, nothing rerun, nothing
      # presented.
      done = new(env, @live, %{"completion" => %{"by" => "accepted_by"}})
      assert at(done) == {"accepted", "completed", 1}
      assert done["last_input"] == %{"version" => 1, "import" => true}
      assert done["pending"]["writes"] == []
      # Its count is still given to it, and moves nothing.
      assert at(counted(done, env, @live, 1, 0)) == at(done)

      # A completion Facts does not derive (nil, or none) is no history.
      for extra <- [%{}, %{"completion" => nil}],
          do: assert(at(new(env, @live, extra)) == {"building", "active", 1})
    end
  end

  test "the count of its use cases: empty and non-empty aggregates, as use cases open and complete" do
    count =
      Enum.find(runner(:prod).config["composition"]["counts"], &(&1["parent_subject"] == @kind))

    # How Flow counts them: every use case in the scene, and those whose latest build run
    # is not completed. A use case still in its design (no build run yet) is open; one its
    # build run imported as accepted, or that the decider accepted, is not.
    uc = fn n -> %{"key" => "UC-#{n}"} end
    build = fn status -> %{"flow" => @child, "status" => status} end
    assert Counts.values(count, [], %{}) == %{"children" => 0, "open_children" => 0}

    assert Counts.values(count, [uc.(1), uc.(2), uc.(3)], %{
             "UC-2" => build.("active"),
             "UC-3" => build.("completed")
           }) == %{"children" => 3, "open_children" => 2}

    # Only the child subflow's run counts: a completed design run is not the use case done.
    assert Counts.values(count, [uc.(1)], %{
             "UC-1" => %{"flow" => "design_and_accept", "status" => "completed"}
           }) ==
             %{"children" => 1, "open_children" => 1}

    for env <- @envs do
      # A new scene: nothing under it, broken down; use cases come under it, are built,
      # all are completed; a new one opens; all are completed again.
      run = new(env, @live)

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
        moved = sent(counted(run, env, @live, children, open))
        assert moved["state"] == state, inspect({children, open})
        moved
      end)

      # Its use cases removed while it is built: back to break down.
      building = counted(new(env, @live), env, @live, 2, 1)
      assert at(counted(sent(building), env, @live, 0, 0)) == {"break_down", "active", 2}
    end
  end

  test "the decider's verdict ends the test: accepted, or reworked until a new use case opens" do
    for env <- @envs do
      values = Map.merge(@live, %{"children" => 2, "open_children" => 0})
      tested = counted(new(env, @live), env, @live, 2, 0)
      assert at(tested) == {"to_test", "active", 2}

      # Its entry resets the verdict, so an older one moves nothing: until Facts has it,
      # the run waits; then only a new verdict moves it.
      assert [%{"content" => %{"values" => %{"verdict" => "none"}}}] = tested["pending"]["writes"]
      assert {:ok, ^tested} = step(env, tested, Map.put(values, "verdict", "accept"))
      tested = sent(tested)
      assert {:ok, ^tested} = step(env, tested, Map.put(values, "verdict", "none"))

      # Accept: completed, nothing written; the scene is completed by its accepted_by.
      assert {:ok, done} = step(env, tested, Map.put(values, "verdict", "accept"))
      assert at(done) == {"accepted", "completed", 3}
      assert done["pending"]["writes"] == []

      # Reject: reworked, by the coordinator; a new open use case sends it to building, and
      # its completion back to the decider, whose verdict is reset again.
      assert {:ok, rework} = step(env, tested, Map.put(values, "verdict", "reject"))
      assert at(rework) == {"rework", "active", 3}
      assert run_presents(env, "rework", %{}) == {"Rework", @coordinator}
      rejected = Map.put(values, "verdict", "reject")
      assert {:ok, ^rework} = step(env, rework, rejected)
      again = counted(rework, env, rejected, 3, 1)
      assert at(again) == {"building", "active", 4}
      retest = counted(sent(again), env, rejected, 3, 0)
      assert at(retest) == {"to_test", "active", 5}
      assert [%{"content" => %{"values" => %{"verdict" => "none"}}}] = retest["pending"]["writes"]

      # A new open use case while it is tested sends it back to building.
      assert at(counted(tested, env, values, 3, 1)) == {"building", "active", 3}
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
      "key" => "SC-Atlas-01",
      "values" => @live,
      "links" => %{"assignment" => ["AS-SC-Atlas-01"]}
    }

    assignment =
      %{
        "key" => "AS-SC-Atlas-01",
        "values" => %{"flow_state" => "to_test", "expected" => "Test it"},
        "links" => %{"assigned_to" => ["someone"]}
      }
      |> presented(fact, @name)

    item = %{"fact" => fact, "parts" => %{"assignment" => assignment}}
    viewer = %{key: "someone", kind: "person"}

    assert %{answers: answers} =
             Model.AtlasEyra.todo(@kind, fact, %{"assignment" => assignment}, viewer)

    assert Enum.map(answers, &{&1.key, &1.label, &1.change}) == [
             {"a", "Accept", true},
             {"f", "Reject", true}
           ]

    {:write, accept} = Model.AtlasEyra.answer(@kind, "a", item, viewer)
    {:write, reject} = Model.AtlasEyra.answer(@kind, "f", item, viewer)
    assert {accept["self"], accept["note"]} == {"accepted_by", false}
    assert {reject["self"], reject["note"]} == {nil, true}

    # As Control sends them: one change each, Accept naming the one who answers.
    assert {:ok,
            %{"values" => %{"verdict" => "accept"}, "links" => %{"accepted_by" => ["someone"]}},
            _} = AtlasControl.Answers.change(accept, "SC-Atlas-01", "someone", "", @now)

    assert {:ok, %{"values" => %{"verdict" => "reject"}, "links" => links}, "Not yet"} =
             AtlasControl.Answers.change(reject, "SC-Atlas-01", "someone", "Not yet", @now)

    assert links == %{}

    # Each open state of the run shows its own presentation in Control.
    for {state, expected} <- [
          {"break_down", "Break it down into use cases and issues"},
          {"building", "Build it"},
          {"to_test", "Test it"}
        ] do
      a =
        presented(
          %{assignment | "values" => %{"flow_state" => state, "expected" => expected}},
          fact,
          @name
        )

      assert %{expected: ^expected} =
               Model.AtlasEyra.todo(@kind, fact, %{"assignment" => a}, viewer)
    end
  end

  test "restarted while it is tested: the same run, its reset replayed under its id, never redone" do
    for env <- @envs do
      c = runner(env).config
      values = Map.merge(@live, %{"children" => 1, "open_children" => 0})
      tested = counted(new(env, @live), env, @live, 1, 0)
      [reset] = tested["pending"]["writes"]

      # What Facts keeps, read back by a new Flow with a freshly compiled subflow: the
      # same run, its reset still owed under the same id; the verdict it finds before the
      # reset lands moves nothing.
      stored = %{"key" => tested["key"], "values" => Store.encode(c, tested)}
      assert {:ok, ^tested} = Store.decode(c, stored)
      assert {:ok, ^tested} = Run.migrate(tested, flow(env), selection()["migrations"], @now)
      assert {:ok, ^tested} = step(env, tested, Map.put(values, "verdict", "accept"))
      assert tested["pending"]["writes"] == [reset]

      # Acknowledged and restarted again: it waits, owing nothing, and the count it is
      # given again (the same entry, the same values) is no new input.
      waiting = sent(tested)
      stored = %{"key" => waiting["key"], "values" => Store.encode(c, waiting)}
      assert {:ok, ^waiting} = Store.decode(c, stored)
      assert {:ok, ^waiting} = step(env, waiting, Map.put(values, "verdict", "none"))
      assert at(counted(waiting, env, values, 1, 0)) == {"to_test", "active", 2}

      # The decider's answer after the restart ends it, once.
      assert {:ok, done} = step(env, waiting, Map.put(values, "verdict", "accept"))
      assert at(done) == {"accepted", "completed", 3}
      assert {:ok, ^done} = step(env, done, Map.put(values, "verdict", "accept"))
    end
  end

  test "reopened after it was accepted, or a use case under it reopened: a new generation only on an explicit restart" do
    for env <- @envs do
      f = flow(env)
      values = Map.merge(@live, %{"children" => 1, "open_children" => 0, "verdict" => "accept"})
      tested = sent(counted(new(env, @live), env, @live, 1, 0))
      {:ok, done} = step(env, tested, values)
      assert at(done) == {"accepted", "completed", 3}

      # Reopened: accepted_by removed (Facts no longer completes it), rejected later; or a
      # use case under it reopened, whose count then says one is open (had its build run
      # restarted too). The completed run stays as it is, generation 1, and nothing else is
      # made; the changed count is offered to it, and moves nothing.
      for {values, extra} <- [
            {Map.put(values, "verdict", "accept"), %{"completion" => nil}},
            {Map.put(values, "verdict", "reject"), %{"completion" => nil}},
            {Map.put(values, "open_children", 1), %{}},
            {Map.merge(values, %{"children" => 2, "open_children" => 1}), %{}}
          ] do
        assert {:ok, ^done} = step(env, done, values, extra)
      end

      assert counted(done, env, values, 2, 1) == done

      # The explicit restart is the only way to a new generation: a new run, its own key,
      # started as a new scene is, and its count moves it on; never one that is not
      # completed.
      assert {:ok, second} = Run.restart(done, f, scene(@live), @now)
      assert {second["generation"], at(second)} == {2, {"break_down", "active", 1}}
      assert second["key"] == Run.key(@name, @kind, "SC-Atlas-01", 2)
      assert second["key"] != done["key"]
      refute Map.has_key?(second["last_input"], "import")
      assert at(counted(second, env, @live, 2, 1)) == {"building", "active", 2}
      assert {:error, :not_completed} = Run.restart(second, f, scene(@live), @now)
    end
  end

  test "the change from the base's digest is a declared state migration, never a re-key" do
    for env <- @envs do
      f = flow(env)
      [m] = selection()["migrations"]
      assert {m["from"], m["to"]} == {@base, f.digest()}
      refute Map.has_key?(m, "rekey") or Map.has_key?(m, "preserve_entry")
      assert m["states"] == Map.new(f.states(), &{&1, &1})

      old = fn state, status, pending ->
        new(env, @live)
        |> Map.merge(%{"definition_sha256" => @base, "state" => state, "status" => status})
        |> update_in(["pending"], &Map.merge(&1, pending))
      end

      for state <- ~w(break_down building rework) do
        assert {:ok, moved} = Run.migrate(old.(state, "active", %{}), f, [m], @now)
        assert at(moved) == {state, "active", 2}
        assert moved["definition_sha256"] == f.digest()
      end

      # Its test re-entered resets the verdict, as a new entry does.
      assert {:ok, moved} = Run.migrate(old.("to_test", "active", %{}), f, [m], @now)
      assert [%{"content" => %{"values" => %{"verdict" => "none"}}}] = moved["pending"]["writes"]

      # A frozen pass is not quiescent: it blocks, nothing is redone.
      assert {:error, :definition_changed} =
               Run.migrate(
                 old.("rework", "active", %{"pass" => %{"request" => %{}}}),
                 f,
                 [m],
                 @now
               )

      assert {:ok, accepted} = Run.migrate(old.("accepted", "completed", %{}), f, [m], @now)
      assert {accepted["state"], accepted["status"]} == {"accepted", "completed"}
    end
  end
end
