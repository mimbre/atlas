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
end
