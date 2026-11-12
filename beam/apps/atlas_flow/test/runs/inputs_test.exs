defmodule AtlasFlow.Runs.InputsTest do
  use ExUnit.Case, async: false
  alias AtlasFlow.{FakeFacts, ManualClock, Sorts, TestModel}
  alias AtlasFlow.Runs.{Run, Store}
  @now ~U[2026-11-12 00:00:00Z]

  defp subject(values \\ %{}),
    do: %{"key" => "B-1", "version" => "v2", "values" => Map.merge(%{"phase" => "first"}, values)}

  # A clerk chooses yes (a branch only the clerk's input takes); entering resets the choice.
  defp flow, do: Sorts.Chosen

  defp run(f), do: Run.new("sort", f, subject(), [], @now) |> put_in(["pending", "writes"], [])

  defp input(r),
    do: %{
      "key" => "I-1",
      "run" => r["key"],
      "entry" => r["entry"],
      "status" => "applied",
      "roles" => ["clerk"],
      "changed_fields" => %{"choice" => "yes"},
      "position" => 7,
      "subject_version" => "v2",
      "prepared_at" => "2026-11-12T00:05:00Z",
      "applied_at" => "2026-11-12T00:10:00Z"
    }

  test "a snapshot, owner or supplied roles cannot take a choice branch" do
    f = flow()
    r = run(f)
    s = subject(%{"choice" => "yes", "roles" => ["clerk"], "owner" => "clerk"})
    assert {:ok, ^r} = Run.step(r, f, s, @now)

    for bad <- [
          Map.put(input(r), "roles", []),
          Map.put(input(r), "status", "prepared"),
          Map.put(input(r), "entry", 0),
          Map.put(input(r), "subject_version", "v1"),
          Map.put(input(r), "changed_fields", %{"other" => true})
        ] do
      assert {:ok, refused} = Run.step(r, f, s, @now, [bad])
      assert refused["state"] == "waiting" and refused["entry"] == 1
    end

    assert {:ok, final} = Run.step(r, f, s, @now, [input(r)])
    assert final["state"] == "done"
    assert final["input_cursor"] == 7
    assert {:ok, ^final} = Run.step(final, f, s, @now, [input(r)])
  end

  test "human stored by the deadline wins; a later choice loses to the original timer" do
    f = flow()
    r = run(f)
    now = DateTime.add(@now, 600)
    assert {:ok, %{"state" => "done"}} = Run.step(r, f, subject(), now, [input(r)])
    late = Map.put(input(r), "prepared_at", "2026-11-12T00:05:00.001Z")

    assert {:ok, %{"state" => "waiting", "entry" => 2} = timed} =
             Run.step(r, f, subject(), now, [late])

    assert timed["last_input"]["due"] == "2026-11-12T00:05:00.000Z"
  end

  test "since is frozen from the persisted field; invalid time blocks before effects" do
    f = Sorts.Since

    for value <- [nil, "invalid"] do
      blocked = Run.new("sort", f, subject(%{"opened_at" => value}), [], @now)
      assert blocked["status"] == "blocked"
      assert blocked["pending"]["writes"] == []
    end

    r = Run.new("sort", f, subject(%{"opened_at" => "2026-11-11T23:59:00Z"}), [], @now)
    assert hd(r["deadlines"]["timers"])["due"] == "2026-11-12T00:04:00.000Z"
  end

  setup do
    Application.put_env(:atlas_bus, :store, "inputs-#{System.unique_integer([:positive])}")
    start_supervised!(FakeFacts)
    :ok = AtlasBus.attach("flow")
    clock = start_supervised!({ManualClock, @now})
    FakeFacts.put("box", subject())
    %{clock: clock}
  end

  test "entry resets and creates replay once; keys include entry and output index", %{
    clock: clock
  } do
    # It also makes two slips on entry.
    f = flow()
    config = TestModel.config()
    FakeFacts.lose_ack("slip")
    assert {:error, {:pending, _}} = Store.reconcile(config, %{"sort" => f}, @now)
    assert {:ok, [first]} = Store.reconcile(config, %{"sort" => f}, @now)
    assert {:ok, [^first]} = Store.reconcile(config, %{"sort" => f}, @now)
    writes = FakeFacts.sent()
    assert Enum.count(writes, &(&1["values"]["choice"] == "none")) == 1
    creates = Enum.filter(writes, &(&1["values"]["title"] in ["One", "Two"]))
    assert length(creates) == 2
    assert length(Enum.uniq_by(creates, & &1["key"])) == 2
    assert Enum.all?(creates, &(&1["links"] == %{"of_box" => ["B-1"]}))
    ManualClock.advance(clock, 300_000)

    assert {:ok, [%{"entry" => 2}]} =
             Store.reconcile(config, %{"sort" => f}, ManualClock.now(clock))

    assert Enum.count(FakeFacts.sent(), &(&1["values"]["choice"] == "none")) == 2
  end

  test "predicate edge is persisted while false, consumed once, and survives reconciliation restart" do
    f = Sorts.Ready
    config = TestModel.config()

    assert {:ok, [%{"status" => "idle", "entry" => 0}]} =
             Store.reconcile(config, %{"sort" => f}, @now)

    FakeFacts.put("box", subject(%{"ready" => true}))
    assert {:ok, [started]} = Store.reconcile(config, %{"sort" => f}, @now)
    assert started["entry"] == 1
    FakeFacts.put("box", subject(%{"ready" => true, "result" => "ok"}))

    assert {:ok, [%{"status" => "completed", "generation" => 1}]} =
             Store.reconcile(config, %{"sort" => f}, @now)

    assert {:ok, [%{"generation" => 1}]} = Store.reconcile(config, %{"sort" => f}, @now)
    FakeFacts.put("box", subject(%{"ready" => false}))
    assert {:ok, [%{"generation" => 1}]} = Store.reconcile(config, %{"sort" => f}, @now)
    FakeFacts.put("box", subject(%{"ready" => true}))
    assert {:ok, [%{"generation" => 2} = second]} = Store.reconcile(config, %{"sort" => f}, @now)
    assert {:ok, [^second]} = Store.reconcile(config, %{"sort" => f}, @now)
    assert second["key"] != started["key"]
  end
end
