defmodule Model.AcceptanceRunsTest do
  @moduledoc """
  Slice 10: the design of a use case runs on Flow's durable runs (`design_and_accept`),
  for the design phase of the legacy flow `design_and_accept`, which keeps the building
  phase. Its selection, the disjoint admission that gives each use case one writer at any
  moment, the import table mapped onto the use cases on test and prod, acceptance and
  rejection, the restart before the accepted output is acknowledged, the hand-off to the
  legacy building phase, and the migration from the base's digest, on the compiled
  subflow of both environments.
  """
  use ExUnit.Case, async: true

  alias AtlasFlow.Runs.{Run, Store}

  @now ~U[2026-11-13 00:00:00Z]
  @envs [:prod, :test]
  @name "design_and_accept"
  @kind "use_case"
  # The digest the base recorded before slice 10 (the same in prod and test, its only one).
  @base "25f57fda40fa0e12d9322c7eb41a9d1829bee934777abe157f5c6a93685e377e"
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

  defp flow(env), do: Enum.find(Model.AtlasEyra.subflows(env), &(&1.name() == @name))
  defp flows(env), do: Map.new(Model.AtlasEyra.subflows(env), &{&1.name(), &1})
  defp selection, do: Model.AtlasEyra.selection(@name)
  defp legacy, do: Enum.find(Model.AtlasEyra.legacy(), &(&1.name() == @name))

  defp config(env),
    do: AtlasFlow.Model.load(Model.AtlasEyra, env, %{"decider" => "someone"}).config

  defp use_case(values),
    do: %{"key" => "UC-Atlas-01", "version" => "v1", "position" => 11, "values" => values}

  defp new(env, values),
    do: Run.new(@name, flow(env), use_case(values), selection()["imports"], @now)

  # A run whose entry writes Facts acknowledged.
  defp sent(run), do: put_in(run, ["pending", "writes"], [])

  defp at(run), do: {run["state"], run["status"], run["entry"]}

  # As the use cases on test and prod are today (status refine), with `issues` under it.
  defp live(design_status, issues \\ 0) do
    values = %{"title" => "A use case", "description" => "What it is", "status" => "refine"}
    values = if design_status, do: Map.put(values, "design_status", design_status), else: values
    {values, for(n <- List.duplicate(nil, issues) |> Enum.with_index(), do: issue(elem(n, 1)))}
  end

  defp issue(n), do: %{"key" => "IS-Atlas-#{n}", "links" => %{"in_use_case" => ["UC-Atlas-01"]}}

  # What the legacy flow presents for a use case: {state, expected, owner}.
  defp legacy_presents({values, children}) do
    fact = %{"key" => "UC-Atlas-01", "values" => values, "links" => %{}}
    {state, vars} = legacy().state(fact, children, ["in_use_case"], [])
    {state, legacy().expected(state, vars), legacy().owner(state)}
  end

  # What the run presents in its state: {expected, owner}, as Flow's projection reads it.
  defp run_presents(env, state, values) do
    f = flow(env)
    {f.present(state, values)["expected"], f.owner(state)["default"]}
  end

  # Which writer presents the use case, as Flow's projection chooses it: the run of the
  # selected subflow, unless it is completed and its follow-through holds, else the legacy.
  defp writer(env, values, run) do
    case Store.selected(config(env), @kind, %{"values" => values}) do
      nil ->
        :legacy

      {@name, s} ->
        follow = s["follow_through"]

        cond do
          run == nil -> :none
          run["status"] == "active" -> :run
          run["state"] == follow["state"] and Run.holds?(follow["when"], values) -> :legacy
          true -> :none
        end
    end
  end

  @architect %{"kind" => "agent", "key" => "architect"}
  @coordinator %{"kind" => "agent", "key" => "coordinator"}

  test "selected in both environments, runnable, and the one writer of a use case's design" do
    for env <- @envs do
      runner = AtlasFlow.Model.load(Model.AtlasEyra, env, %{"decider" => "someone"})
      assert runner.refusal == nil
      assert Map.has_key?(runner.config["selection"], @name)
      # Its building phase is not selected yet (slice 11).
      refute Map.has_key?(runner.config["selection"], "test_and_accept_use_case")

      f = flow(env)
      assert Run.validate(f) == :ok
      assert f.states() == ~w(accepted design_review designing redesign)
      # No pass, gate or effect, no create and no timer: nothing is dispatched or made for
      # a use case, and nothing is due.
      assert Enum.all?(f.states(), &(f.mechanism(&1) == nil))
      assert for(s <- f.states(), {:create, _} <- f.enter(s, %{}), do: s) == []
      assert Enum.all?(f.states(), &(f.timers(&1) == []))
      # No person's choice: nothing waits for a role.
      assert Enum.all?(f.states(), &(f.waiting_for(&1) == []))
    end

    s = selection()
    assert {s["subject"], s["legacy"]} == {@kind, @name}
    assert s["admission"] == %{"design_status" => @admitted}
    assert {s["choices"], s["choice_states"]} == {[], []}
    # It presents where the legacy flow did, the only legacy flow on the kind.
    assert Map.take(legacy().writes(), Map.keys(s["projection"])) == s["projection"]
    assert for(l <- Model.AtlasEyra.legacy(), @kind in l.kinds(), do: l.name()) == [@name]
  end

  test "disjoint phase admission: the run while the design is written or reviewed, never after" do
    for env <- @envs do
      c = config(env)

      for status <- @admitted,
          do:
            assert(
              {@name, _} = Store.selected(c, @kind, %{"values" => %{"design_status" => status}})
            )

      # From its acceptance on, and without a design phase, the legacy flow presents it.
      for values <- [
            %{"design_status" => "approved"},
            %{"design_status" => "accepted"},
            %{"design_status" => ""},
            %{"design_status" => nil},
            %{}
          ],
          do: assert(Store.selected(c, @kind, %{"values" => values}) == nil)
    end
  end

  test "a selection that would give a use case two writers is refused" do
    for env <- @envs,
        alter <- [
          &Map.delete(&1, "legacy"),
          &Map.delete(&1, "projection"),
          &Map.put(&1, "legacy", "test_and_accept")
        ] do
      Process.put(:alter, %{@name => alter})
      assert {_config, {:two_writers, @name}} = Store.activate(Altered, flows(env))
    end

    # A second projecting subflow on use cases (here the design's, by another name) may
    # admit none the design admits: overlapping, every run is refused; disjoint (the
    # building phase, as slice 11 selects it), none is.
    second = fn admission ->
      fn nil ->
        Map.merge(selection(), %{"admission" => admission, "imports" => [], "migrations" => []})
      end
    end

    for env <- @envs do
      flows = Map.put(flows(env), "test_and_accept_use_case", flow(env))

      for overlapping <- [[], %{"design_status" => ["accepted", "writing"]}] do
        Process.put(:alter, %{"test_and_accept_use_case" => second.(overlapping)})
        assert {_config, {:two_writers, _}} = Store.activate(Altered, flows)
      end

      Process.put(:alter, %{
        "test_and_accept_use_case" => second.(%{"design_status" => ["approved", "accepted"]})
      })

      assert {_config, nil} = Store.activate(Altered, flows)
    end

    Process.put(:alter, %{})
    assert {_config, nil} = Store.activate(Altered, flows(:prod))
  end

  test "every import row, mapped onto the use cases on test and prod" do
    assert selection()["imports"] == [
             %{"when" => %{"design_status" => ["in_review"]}, "state" => "design_review"},
             %{"when" => %{"design_status" => ["changes_requested"]}, "state" => "redesign"}
           ]

    # No row leads to the accepted end: no acceptance is made for a use case whose design
    # was approved before; it is never admitted, so it never has a run.
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
      assert writer(env, values, run) == :run

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
        assert writer(env, values, run) == :run
        # Imported where it is, it stays there: nothing moves it until its design does.
        assert {:ok, ^run} = Run.step(run, flow(env), use_case(values), @now)
      end

      # prod 5 and 3: approved, "Build it" (issues under it) and "Break it down into
      # issues" (none yet), for the coordinator; test 2: no design_status, "Build it". None
      # is admitted: no run starts, nothing is imported or written, the legacy flow presents
      # it exactly as now.
      for {status, issues, state, expected} <- [
            {"approved", 2, "building", "Build it"},
            {"approved", 0, "break_down", "Break it down into issues"},
            {nil, 0, "building", "Build it"},
            {nil, 3, "building", "Build it"}
          ] do
        {values, _} = row = live(status, issues)
        assert legacy_presents(row) == {state, expected, @coordinator}
        assert writer(env, values, nil) == :legacy
      end
    end
  end

  test "acceptance: the review's approval ends the run, which writes accepted once" do
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

  test "rejection: changes requested (or writing again) send it to the rework, in review back" do
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

      # Written, then in review: the review presents it.
      writing = new(env, %{"design_status" => "writing"})

      assert {:ok, ^writing} =
               Run.step(writing, f, use_case(%{"design_status" => "changes_requested"}), @now)

      assert {:ok, reviewed} =
               Run.step(writing, f, use_case(%{"design_status" => "in_review"}), @now)

      assert at(reviewed) == {"design_review", "active", 2}
    end
  end

  test "restarted before the accepted output is acknowledged: replayed, never redone or lost" do
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

      # Meanwhile, and after, the legacy building phase presents it, the same way: the
      # review's approved is no longer the design's, and neither is the accepted it writes.
      for status <- ["approved", "accepted"] do
        values = %{"design_status" => status}
        assert writer(env, values, accepted) == :legacy

        assert legacy_presents({values, []}) ==
                 {"break_down", "Break it down into issues", @coordinator}

        assert legacy_presents({values, [issue(1)]}) == {"building", "Build it", @coordinator}
      end
    end
  end

  test "the hand-off: one writer at every step, from a new use case to its building phase" do
    for env <- @envs do
      f = flow(env)
      c = config(env)
      run = new(env, %{"design_status" => "writing"})

      steps = [
        {"writing", :run, "designing"},
        {"in_review", :run, "design_review"},
        {"changes_requested", :run, "redesign"},
        {"in_review", :run, "design_review"},
        {"approved", :legacy, "accepted"},
        {"accepted", :legacy, "accepted"}
      ]

      Enum.reduce(steps, run, fn {status, who, state}, run ->
        values = %{"design_status" => status}
        {:ok, run} = Run.step(run, f, use_case(values), @now)
        run = sent(run)
        assert run["state"] == state

        # Exactly one writer: the run (admitted and active) or the legacy flow (not
        # admitted); never both, never neither.
        assert writer(env, values, run) == who
        assert Store.selected(c, @kind, %{"values" => values}) != nil == (who == :run)

        # And it presents what the legacy flow presented for the same design status.
        {_, expected, owner} = legacy_presents({values, []})

        if who == :run,
          do: assert(run_presents(env, state, values) == {expected, owner}),
          else: assert(expected == "Break it down into issues" and owner == @coordinator)

        run
      end)

      # A design put back by hand after its acceptance is not started again: its completed
      # run stays as it is, and the legacy flow presents it (follow-through), as today.
      review = sent(new(env, %{"design_status" => "in_review"}))
      {:ok, accepted} = Run.step(review, f, use_case(%{"design_status" => "approved"}), @now)
      done = sent(accepted)

      for status <- @admitted do
        values = %{"design_status" => status}
        assert {:ok, ^done} = Run.step(done, f, use_case(values), @now)
        assert writer(env, values, done) == :legacy
        assert {state, _, _} = legacy_presents({values, []})
        assert state in ["design", "design_review"]
      end
    end
  end

  test "the use case's count of its issues offers its run nothing it moves on" do
    count = Enum.find(Model.AtlasEyra.composition()["counts"], &(&1["parent_subject"] == @kind))
    assert {count["child"], count["all"], count["open"]} == {"issue", "children", "open_children"}

    for env <- @envs, status <- ["writing", "in_review", "changes_requested"] do
      run = new(env, %{"design_status" => status})

      offered =
        put_in(run, ["pending", "synthetic"], %{
          "id" => "S-1",
          "values" => %{"children" => 2, "open_children" => 1},
          "sources" => []
        })

      # Taken once, at this entry, and dropped: no state of the design reads a count.
      assert {:ok, ^run} =
               Run.synthetic(offered, flow(env), use_case(%{"design_status" => status}), @now)
    end
  end

  test "the change from the base's digest is a declared state migration, never a re-key" do
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
    end
  end
end
