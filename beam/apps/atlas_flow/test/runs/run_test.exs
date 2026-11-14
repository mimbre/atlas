defmodule AtlasFlow.Runs.RunTest do
  use ExUnit.Case, async: false
  alias AtlasFlow.{FakeFacts, ManualClock, Sorts, Talk, TestModel}
  alias AtlasFlow.Runs.{Run, Store}

  @now ~U[2026-11-12 00:00:00Z]
  defp subject(values \\ %{}),
    do: %{"key" => "B-1", "values" => Map.merge(%{"phase" => "first"}, values)}

  defp config, do: TestModel.config()
  defp sort, do: TestModel.sort()

  defmodule Unselected do
    use AtlasFlow.TestModel, selection: %{"sort" => nil}
  end

  defmodule Unrunnable do
    use AtlasFlow.TestModel, subflows: [AtlasFlow.Sorts.Unbound]
  end

  test "a model that selects no subflow keeps and reconciles no runs" do
    assert AtlasFlow.Model.load(Unselected, :prod).config == nil
    assert {:ok, []} = Store.reconcile(nil, %{}, @now)
    assert FakeFacts.sent() == []
  end

  test "activation refuses a selected subflow this runner cannot run, with zero writes" do
    assert %{refusal: {:unsupported_definition, "sort"}} = AtlasFlow.Model.load(Unrunnable, :prod)
    assert FakeFacts.sent() == []
  end

  defp new(values \\ %{}) do
    Run.new(
      "sort",
      sort(),
      subject(values),
      config()["selection"]["sort"]["imports"],
      @now
    )
  end

  test "ordered equalities, missing values, durable finality and imports" do
    flow = sort()
    run = new()
    assert Run.validate(flow) == :ok
    run = put_in(run, ["pending", "writes"], [])
    assert {:ok, ^run} = Run.step(run, flow, subject(), @now)
    assert {:ok, final} = Run.step(run, flow, subject(%{"result" => "ok"}), @now)
    assert final["state"] == "done" and final["status"] == "completed"
    assert {:ok, ^final} = Run.step(final, flow, subject(%{"result" => "no"}), @now)

    # Two branches hold: the first written is taken.
    assert {:ok, %{"state" => "done"}} =
             Run.step(
               %{run | "definition_sha256" => Sorts.Twice.digest()},
               Sorts.Twice,
               subject(%{"result" => "ok"}),
               @now
             )

    for {value, state} <- [{"ok", "done"}, {"old", "done"}, {"no", "discarded"}] do
      imported = new(%{"result" => value})
      assert imported["state"] == state
      assert imported["status"] == "completed"
      assert imported["pending"]["writes"] == []
      assert imported["last_input"]["import"]
    end
  end

  test "only an exact reviewed mapping migrates a quiescent run, preserving historical finals" do
    flow = sort()
    run = new() |> put_in(["pending", "writes"], []) |> put_in(["deadlines", "timers"], [])
    old = Map.put(run, "definition_sha256", "old")

    mapping = %{
      "from" => "old",
      "to" => flow.digest(),
      "states" => %{"waiting" => "waiting", "done" => "done"}
    }

    assert {:error, :definition_changed} = Run.migrate(old, flow, [], @now)

    assert {:error, :definition_changed} =
             Run.migrate(old, flow, [put_in(mapping, ["states", "waiting"], "missing")], @now)

    assert {:ok, migrated} = Run.migrate(old, flow, [mapping], @now)
    assert migrated["entry"] == old["entry"] + 1
    assert migrated["key"] == old["key"]
    assert migrated["definition_sha256"] == flow.digest()

    assert {:error, _} =
             Run.migrate(put_in(old, ["deadlines", "timers"], [%{}]), flow, [mapping], @now)

    completed = old |> Map.put("status", "completed") |> Map.put("state", "done")
    assert {:ok, historical} = Run.migrate(completed, flow, [mapping], @now)
    assert historical["entry"] == completed["entry"]
    assert historical["pending"]["writes"] == []
    assert historical["status"] == "completed"
  end

  test "refuses a subflow whose mechanism this runner cannot run" do
    assert {:error, :unsupported_definition} = Run.validate(Sorts.Unbound)
  end

  test "overdue timers use due time first and declaration order for ties" do
    for {flow, expected} <- [{Sorts.Ties, "done"}, {Sorts.Earlier, "discarded"}] do
      run = Run.new("sort", flow, subject(), [], @now) |> put_in(["pending", "writes"], [])

      assert {:ok, transitioned} =
               Run.step(run, flow, subject(), DateTime.add(@now, 360, :second))

      assert transitioned["state"] == expected
    end
  end

  setup do
    Application.put_env(:atlas_bus, :store, "runs-#{System.unique_integer([:positive])}")
    start_supervised!(FakeFacts)
    :ok = AtlasBus.attach("flow")
    clock = start_supervised!({ManualClock, @now})
    FakeFacts.put("box", subject())
    %{clock: clock}
  end

  defp reconcile(clock),
    do: Store.reconcile(config(), %{"sort" => sort()}, ManualClock.now(clock))

  defp stored do
    fact = FakeFacts.get("cursor", Run.key("sort", "box", "B-1", 1))
    {:ok, run} = Store.decode(config(), fact)
    run
  end

  test "restart in a waiting entry, duplicate create, just before and exactly at original due time",
       %{clock: clock} do
    assert {:ok, [first]} = reconcile(clock)
    assert first["entry"] == 1
    assert FakeFacts.get("box", "B-1")["values"]["mark"] == "entered"
    assert {:ok, [^first]} = reconcile(clock)
    ManualClock.advance(clock, 299_999)
    assert {:ok, [^first]} = reconcile(clock)
    ManualClock.advance(clock, 1)
    assert {:ok, [second]} = reconcile(clock)
    assert second["entry"] == 2

    assert second["last_input"] == %{
             "version" => 1,
             "entry" => 1,
             "name" => "retry",
             "due" => "2026-11-12T00:05:00.000Z",
             "waited_from" => "2026-11-12T00:00:00Z"
           }

    # A duplicate or cancelled old-entry notification only rereads the new cursor.
    assert {:ok, [^second]} = reconcile(clock)
    assert stored() == second
    assert Enum.count(FakeFacts.sent(), &(&1["op"] == "create")) == 1
  end

  test "lost entry-write acknowledgement replays the same id and frozen payload", %{clock: clock} do
    FakeFacts.lose_ack("box")
    assert {:error, {:pending, _}} = reconcile(clock)
    assert stored()["pending"]["writes"] != []
    writes = length(FakeFacts.sent())
    assert {:ok, [run]} = reconcile(clock)
    assert run["entry"] == 1 and run["pending"]["writes"] == []
    assert Enum.count(FakeFacts.sent(), &(&1["values"]["mark"] == "entered")) == 1
    assert length(FakeFacts.sent()) == writes + 1
  end

  test "a lost create acknowledgement recovers the committed cursor before entry writes", %{
    clock: clock
  } do
    FakeFacts.lose_ack("cursor")
    assert {:ok, [run]} = reconcile(clock)
    assert run["entry"] == 1
    assert {:ok, [^run]} = reconcile(clock)
    assert Enum.count(FakeFacts.sent(), &(&1["op"] == "create")) == 1
    assert Enum.count(FakeFacts.sent(), &(&1["values"]["mark"] == "entered")) == 1
  end

  test "input before the deadline cancels the old entry and completed runs never reopen", %{
    clock: clock
  } do
    {:ok, [_]} = reconcile(clock)
    ManualClock.advance(clock, 299_999)

    {:stored, _} =
      Talk.put("box", %{"op" => "change", "key" => "B-1", "values" => %{"result" => "ok"}})

    assert {:ok, [%{"state" => "done", "entry" => 2} = final]} = reconcile(clock)
    ManualClock.advance(clock, 300_001)
    assert {:ok, [^final]} = reconcile(clock)
    changed = %{"sort" => Sorts.Relabelled}
    assert {:ok, [blocked]} = Store.reconcile(config(), changed, ManualClock.now(clock))
    assert blocked["status"] == "blocked"
    assert blocked["blocked_reason"] =~ "definition_changed"
    assert blocked["entry"] == final["entry"]
    assert blocked["pending"]["writes"] == []
  end

  # -- Imports, writers and replies: a neutral inspection of a box ---------------------

  defmodule Written do
    @moduledoc """
    An inspection of a box: a clerk keeps or returns it (a trusted choice), a dropped box
    ends it as it is written, and after five minutes a keeper may answer too. `Busy` marks
    the box when it starts looking: a state an import may not join.
    """

    defmodule Inspected do
      @moduledoc false
      use RelaDSL.Schema

      subflow :inspect, label: "Inspect", subject: :box do
        run_as("system:depot")
        owner(default: {:clerk, :ada})
        start(:create)
        initial(:looking)

        state :looking do
          branch(to: :dropped, when: "entity.dropped == true")
          wait_for([:clerk], on: :choice, reset: false, yes: :kept, no: :returned)
          timer(:stalled, "5m", to: :escalated)
        end

        state :escalated do
          branch(to: :dropped, when: "entity.dropped == true")
          wait_for([:clerk, :keeper], on: :choice, reset: false, yes: :kept, no: :returned)
        end

        final(:kept)
        final(:returned)
        final(:dropped, status: :cancelled)
      end
    end

    defmodule Busy do
      @moduledoc false
      use RelaDSL.Schema

      subflow :inspect, label: "Inspect", subject: :box do
        run_as("system:depot")
        owner(default: {:clerk, :ada})
        start(:create)
        initial(:looking)

        state :looking do
          set(mark: "looking")
          wait_for([:clerk], on: :choice, reset: false, yes: :kept)
        end

        final(:kept)
      end
    end
  end

  defmodule Inspect do
    use AtlasFlow.Sorts, from: Written.Inspected, subflow: :inspect
  end

  defmodule BusyInspect do
    use AtlasFlow.Sorts, from: Written.Busy, subflow: :inspect
  end

  # The import table, in order: the first row that holds gives the entry.
  @imports [
    %{"when" => %{"dropped" => [true]}, "state" => "dropped"},
    %{"when" => %{"choice" => ["yes"]}, "state" => "kept"},
    %{"when" => %{"choice" => ["no"]}, "state" => "returned"},
    %{"when" => [], "state" => "looking"}
  ]

  @inspection %{
    "subject" => "box",
    "choices" => ["choice"],
    "admission" => [],
    "imports" => @imports,
    "migrations" => []
  }

  defmodule Inspecting do
    use AtlasFlow.TestModel,
      subflows: [AtlasFlow.Runs.RunTest.Inspect],
      selection: %{
        "inspect" => %{
          "subject" => "box",
          "choices" => ["choice"],
          "admission" => [],
          "imports" => [
            %{"when" => %{"dropped" => [true]}, "state" => "dropped"},
            %{"when" => %{"choice" => ["yes"]}, "state" => "kept"},
            %{"when" => %{"choice" => ["no"]}, "state" => "returned"},
            %{"when" => [], "state" => "looking"}
          ],
          "migrations" => []
        }
      }
  end

  defp imported(values), do: Run.new("inspect", Inspect, subject(values), @imports, @now)

  test "every import row: history completes as it was, an open subject joins its wait" do
    assert Inspecting.selection("inspect") == @inspection

    for {values, state} <- [
          {%{"dropped" => true, "choice" => "yes"}, "dropped"},
          {%{"choice" => "yes"}, "kept"},
          {%{"choice" => "no"}, "returned"}
        ] do
      run = imported(values)
      assert {run["state"], run["status"], run["entry"]} == {state, "completed", 1}
      assert run["pending"]["writes"] == [] and run["deadlines"]["timers"] == []
      assert run["last_input"] == %{"version" => 1, "import" => true}
      # History stays as it was: no later change moves it.
      assert {:ok, ^run} = Run.step(run, Inspect, subject(%{"choice" => "no"}), @now)
    end

    # Open (no choice, or one no branch reads): its wait, with the timer counted from the
    # import; nothing written, no activity, the import recorded.
    for values <- [%{}, %{"choice" => "maybe"}, %{"dropped" => false}] do
      run = imported(values)
      assert {run["state"], run["status"], run["entry"]} == {"looking", "active", 1}
      assert run["pending"] == %{"version" => 1, "writes" => []}

      assert run["deadlines"]["timers"] == [
               %{
                 "name" => "stalled",
                 "entry" => 1,
                 "to" => "escalated",
                 "due" => "2026-11-12T00:05:00.000Z"
               }
             ]

      assert run["last_input"] == %{"version" => 1, "import" => true}
    end

    # A later write the subflow reads moves an imported open run as any other.
    open = imported(%{})

    assert {:ok, %{"state" => "dropped"}} =
             Run.step(open, Inspect, subject(%{"dropped" => true}), @now)
  end

  test "a condition's nil allows no value; an import row may also say whether it is completed" do
    # nil among the values: the field absent, nil or empty; any other value only itself.
    for values <- [%{}, %{"phase" => nil}, %{"phase" => ""}],
        do: assert(Run.holds?(%{"phase" => [nil, "second"]}, values), inspect(values))

    assert Run.holds?(%{"phase" => [nil, "second"]}, %{"phase" => "second"})
    refute Run.holds?(%{"phase" => [nil, "second"]}, %{"phase" => "first"})
    refute Run.holds?(%{"phase" => ["second"]}, %{})
    refute Run.holds?(%{"phase" => ["second"]}, %{"phase" => ""})
    refute Run.holds?(%{"flag" => [nil]}, %{"flag" => false})

    # A completed subject is history whatever it holds; one that is not, by its values.
    imports = [
      %{"completed" => true, "state" => "kept"},
      %{"when" => %{"choice" => [nil]}, "state" => "looking"},
      %{"when" => %{"choice" => ["no"]}, "completed" => false, "state" => "returned"}
    ]

    new = fn values, extra ->
      Run.new("inspect", Inspect, Map.merge(subject(values), extra), imports, @now)
    end

    for extra <- [%{"completion" => %{"by" => "signed_by"}}, %{"completion" => true}] do
      run = new.(%{"choice" => "no"}, extra)
      assert {run["state"], run["status"]} == {"kept", "completed"}
      assert run["last_input"]["import"]
    end

    for extra <- [%{}, %{"completion" => nil}] do
      assert new.(%{}, extra)["state"] == "looking"
      assert new.(%{"choice" => "no"}, extra)["state"] == "returned"
      # No row holds: it starts as a new one does.
      started = new.(%{"choice" => "maybe"}, extra)
      assert {started["state"], started["last_input"]} == {"looking", %{"version" => 1}}
    end
  end

  test "an import into a state that writes or runs something on entry refuses, with zero writes" do
    defmodule BusyModel do
      use AtlasFlow.TestModel,
        subflows: [AtlasFlow.Runs.RunTest.BusyInspect],
        selection: %{
          "inspect" => %{
            "subject" => "box",
            "admission" => [],
            "imports" => [%{"when" => [], "state" => "looking"}]
          }
        }
    end

    assert Run.importable?(Inspect, "looking") and Run.importable?(Inspect, "kept")
    refute Run.importable?(BusyInspect, "looking")
    refute Run.importable?(Inspect, "missing")
    refute Run.importable?(Sorts.Unbound, "waiting")

    assert %{refusal: {:unsupported_definition, "inspect"}} =
             AtlasFlow.Model.load(BusyModel, :prod)

    assert FakeFacts.sent() == []
  end

  test "two writers refuse every run: projections that admit the same fact" do
    projection = %{"field" => "todo", "owner_relation" => "owned_by"}

    # Two projecting subflows on one kind: one per fact, so their admissions are disjoint.
    for {phases, refusal} <- [{["first"], {:two_writers, "inspect"}}, {["second"], nil}] do
      name = Module.concat(__MODULE__, "Both#{hd(phases)}")

      Module.create(
        name,
        quote do
          use AtlasFlow.TestModel,
            subflows: [AtlasFlow.Depot.Subflows.Sort.Prod, AtlasFlow.Runs.RunTest.Inspect],
            selection: %{
              "inspect" => %{
                "subject" => "box",
                "projection" => unquote(Macro.escape(projection)),
                "admission" => %{"phase" => unquote(phases)},
                "imports" => []
              }
            }
        end,
        Macro.Env.location(__ENV__)
      )

      assert AtlasFlow.Model.load(name, :prod).refusal == refusal
    end

    assert FakeFacts.sent() == []
  end

  test "stale replies: a choice for an older entry, or after the end, moves nothing" do
    open = imported(%{}) |> Map.put("key", "R-1")
    box = %{subject() | "values" => %{"phase" => "first"}} |> Map.put("version", "v2")

    choice = fn run, entry, roles ->
      %{
        "key" => "I-#{entry}-#{Enum.join(roles)}",
        "run" => run["key"],
        "entry" => entry,
        "status" => "applied",
        "roles" => roles,
        "changed_fields" => %{"choice" => "yes"},
        "position" => entry * 10,
        "subject_version" => "v2",
        "prepared_at" => "2026-11-12T00:01:00Z"
      }
    end

    # Only the clerk answers while it is looking: a keeper's choice is consumed, ignored.
    assert {:ok, ignored} = Run.step(open, Inspect, box, @now, [choice.(open, 1, ["keeper"])])
    assert {ignored["state"], ignored["entry"]} == {"looking", 1}
    assert ignored["last_input"] == %{"version" => 1, "input" => "I-1-keeper", "ignored" => true}

    # The timer moves it on; the clerk's choice of the old entry then changes nothing.
    due = DateTime.add(@now, 300, :second)
    assert {:ok, escalated} = Run.step(open, Inspect, box, due)
    assert {escalated["state"], escalated["entry"]} == {"escalated", 2}

    assert {:ok, ^escalated} =
             Run.step(escalated, Inspect, box, due, [choice.(open, 1, ["clerk"])])

    # The current entry's keeper choice ends it; nothing reopens it afterwards.
    assert {:ok, kept} =
             Run.step(escalated, Inspect, box, due, [choice.(escalated, 2, ["keeper"])])

    assert {kept["state"], kept["status"]} == {"kept", "completed"}
    late = [choice.(kept, kept["entry"], ["clerk"])]
    assert {:ok, ^kept} = Run.step(kept, Inspect, box, due, late)
  end

  defp inspection_config, do: TestModel.config(Inspecting)

  defp inspection(key) do
    {:ok, run} =
      Store.decode(
        inspection_config(),
        FakeFacts.get("cursor", Run.key("inspect", "box", key, 1))
      )

    run
  end

  test "imports through the store: no subject write, restart while waiting, the original due",
       %{clock: clock} do
    FakeFacts.put("box", %{"key" => "B-2", "values" => %{"choice" => "yes"}})
    FakeFacts.put("box", %{"key" => "B-3", "values" => %{"dropped" => true}})

    reconcile = fn ->
      Store.reconcile(inspection_config(), %{"inspect" => Inspect}, ManualClock.now(clock))
    end

    assert {:ok, runs} = reconcile.()

    assert Enum.map(Enum.sort_by(runs, & &1["subject_key"]), &{&1["subject_key"], &1["state"]}) ==
             [{"B-1", "looking"}, {"B-2", "kept"}, {"B-3", "dropped"}]

    # Only the three cursors were written: no subject write, no activity.
    assert Enum.map(FakeFacts.sent(), & &1["op"]) == ~w(create create create)
    waiting = inspection("B-1")
    [timer] = waiting["deadlines"]["timers"]

    # Flow keeps nothing between reconciles: each is a restart over the stored cursors.
    ManualClock.advance(clock, 299_999)
    assert {:ok, _} = reconcile.()
    assert inspection("B-1") == waiting
    assert {:ok, _} = reconcile.()
    assert inspection("B-1") == waiting
    assert length(FakeFacts.sent()) == 3

    ManualClock.advance(clock, 1)
    assert {:ok, _} = reconcile.()
    escalated = inspection("B-1")
    assert {escalated["state"], escalated["entry"]} == {"escalated", 2}
    assert escalated["last_input"]["due"] == timer["due"]
    assert escalated["last_input"]["entry"] == 1

    # History did not move, and is not written again.
    assert inspection("B-2")["state"] == "kept" and inspection("B-3")["state"] == "dropped"
    assert {:ok, _} = reconcile.()
    assert Enum.count(FakeFacts.sent(), &(&1["op"] == "create")) == 3
  end

  # An aggregate parent taken over from facts as they were (the neutral yard: a tray counts
  # its cups, and its tally ends once none is open): its import table holds on whether the
  # parent is completed, as Facts derives it, and leads to its wait otherwise; its count,
  # given on its first entry, moves it on. No row reads the children: no parent holds a
  # count before a subflow runs on it. Reopening is explicit only. Each reconcile is a
  # restart over what Facts holds; no timer is waited on.
  test "an aggregate's imports: history, an empty and a non-empty wait; a reopened child after the end" do
    %{config: config, flows: flows} = AtlasFlow.Model.load(AtlasFlow.Yard, :prod)

    config =
      config
      |> update_in(["selection"], &Map.delete(&1, "fill"))
      |> put_in(["selection", "tally", "reopen"], "explicit")
      |> put_in(["selection", "tally", "imports"], [
        %{"completed" => true, "state" => "counted"},
        %{"completed" => false, "state" => "counting"}
      ])

    reconcile = fn -> Store.reconcile(config, flows, @now) end

    tally = fn key, generation ->
      case FakeFacts.get("cursor", Run.key("tally", "tray", key, generation)) do
        nil -> nil
        fact -> elem(Store.decode(config, fact), 1)
      end
    end

    at = fn run -> {run["state"], run["status"], run["entry"]} end
    counts = fn key -> Map.take(FakeFacts.get("tray", key)["values"], ~w(cups open_cups)) end

    tray = fn key, extra ->
      FakeFacts.put("tray", Map.merge(%{"key" => key, "values" => %{"phase" => "first"}}, extra))
    end

    cup = fn key, on, values ->
      FakeFacts.put("cup", %{
        "key" => key,
        "values" => Map.merge(%{"phase" => "first", "revision" => "r1"}, values),
        "links" => %{"on_tray" => [on]}
      })
    end

    # Completed (history), empty and open, and open with one cup of two still open.
    tray.("T-1", %{"completion" => %{"by" => "signed_by"}})
    cup.("C-1", "T-1", %{"level" => "full"})
    tray.("T-2", %{})
    tray.("T-3", %{})
    cup.("C-2", "T-3", %{"level" => "full"})
    cup.("C-3", "T-3", %{})
    assert {:ok, _} = reconcile.()

    assert at.(tally.("T-1", 1)) == {"counted", "completed", 1}
    assert at.(tally.("T-2", 1)) == {"counting", "active", 1}
    assert at.(tally.("T-3", 1)) == {"counting", "active", 1}
    for key <- ~w(T-1 T-2 T-3), do: assert(tally.(key, 1)["last_input"]["import"] == true)

    # Nothing was written on a parent but its count: the empty one zero, the history its
    # cups as they are.
    assert counts.("T-1") == %{"cups" => 1, "open_cups" => 0}
    assert counts.("T-2") == %{"cups" => 0, "open_cups" => 0}
    assert counts.("T-3") == %{"cups" => 2, "open_cups" => 1}

    for w <- FakeFacts.sent(),
        w["key"] in ~w(T-1 T-2 T-3),
        do: assert(Map.keys(w["values"]) -- ~w(cups open_cups) == [])

    # Restarted while waiting: nothing moves, nothing is written again.
    sent = FakeFacts.sent()
    assert {:ok, _} = reconcile.()
    assert FakeFacts.sent() == sent

    # Its last open cup completes: the count moves the imported wait to its end, once.
    FakeFacts.put("cup", put_in(FakeFacts.get("cup", "C-3"), ["values", "level"], "full"))
    assert {:ok, _} = reconcile.()
    done = tally.("T-3", 1)
    assert at.(done) == {"counted", "completed", 2}
    assert counts.("T-3") == %{"cups" => 2, "open_cups" => 0}

    # A cup reopened after its tray's tally ended (its run stays completed: explicit), and a
    # new open cup under it: the count changes and is written, but the ended run stays as
    # it is and no new generation is made.
    FakeFacts.put(
      "cup",
      update_in(FakeFacts.get("cup", "C-3"), ["values"], &Map.delete(&1, "level"))
    )

    cup.("C-4", "T-3", %{})
    assert {:ok, _} = reconcile.()
    assert {:ok, _} = reconcile.()
    assert counts.("T-3") == %{"cups" => 3, "open_cups" => 1}
    assert tally.("T-3", 1) == done
    assert tally.("T-3", 2) == nil

    # The explicit restart: the next generation, as a new run starts, stored as Flow stores
    # a run; the next reconcile drains it, and the count moves it as any other.
    {:ok, second} = Run.restart(done, flows["tally"], FakeFacts.get("tray", "T-3"), @now)
    assert {second["generation"], at.(second)} == {2, {"counting", "active", 1}}

    FakeFacts.put("cursor", %{
      "key" => second["key"],
      "values" => Store.encode(config, second),
      "links" => %{}
    })

    assert {:ok, _} = reconcile.()
    assert at.(tally.("T-3", 2)) == {"counting", "active", 1}
    FakeFacts.put("cup", put_in(FakeFacts.get("cup", "C-4"), ["values", "level"], "full"))
    assert {:ok, _} = reconcile.()
    assert at.(tally.("T-3", 2)) == {"counted", "completed", 2}
    assert tally.("T-3", 1) == done
  end
end
