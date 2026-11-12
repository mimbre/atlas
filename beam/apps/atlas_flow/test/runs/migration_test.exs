defmodule AtlasFlow.Runs.MigrationTest do
  use ExUnit.Case, async: false
  alias AtlasFlow.{FakeFacts, FixtureTarget, ManualClock}
  alias AtlasFlow.Runs.{Run, Store}
  @now ~U[2026-11-12 00:00:00Z]

  setup do
    Application.put_env(:atlas_bus, :store, "upgrade-#{System.unique_integer([:positive])}")
    start_supervised!({FakeFacts, description: FakeFacts.run_description()})
    :ok = AtlasBus.attach("flow")
    clock = start_supervised!({ManualClock, @now})
    %{clock: clock}
  end

  defp subject(key), do: %{"key" => key, "values" => %{"phase" => "first"}}
  defp config, do: FakeFacts.run_description()["flow_runtime"]

  defp seed(key, flow) do
    FakeFacts.put("box", subject(key))
    run = Run.new("sort", flow, subject(key), [], @now)
    FakeFacts.put("cursor", %{"key" => run["key"], "values" => Store.encode(config(), run)})
    run
  end

  defp old_flow do
    FixtureTarget.flow()
    |> put_in(["states", "waiting", "set"], [])
    |> put_in(["states", "waiting", "timers"], [])
  end

  test "unmapped runs block locally, retry without writes, and recover when a mapping arrives", %{
    clock: clock
  } do
    old = seed("B-old", old_flow())
    FakeFacts.put("box", subject("B-new"))
    now = ManualClock.now(clock)
    flows = FixtureTarget.flows()
    assert {:ok, runs} = Store.reconcile(config(), flows, now)
    blocked = Enum.find(runs, &(&1["key"] == old["key"]))
    assert blocked["status"] == "blocked"
    assert blocked["blocked_reason"] =~ old["definition_sha256"]
    assert blocked["blocked_reason"] =~ Run.digest(flows["sort"])
    assert blocked["state"] == old["state"] and blocked["entry"] == old["entry"]
    assert Enum.find(runs, &(&1["subject_key"] == "B-new"))["status"] == "active"
    before = FakeFacts.sent()
    assert {:ok, ^runs} = Store.reconcile(config(), flows, now)
    assert FakeFacts.sent() == before

    mapping = %{
      "from" => Run.digest(old_flow()),
      "to" => Run.digest(flows["sort"]),
      "states" => %{"waiting" => "waiting"},
      "reason" => "Upgrade the waiting entry"
    }

    config = put_in(config(), ["selection", "sort", "migrations"], [mapping])
    # Lose the acknowledgement of the migration cursor, not its entry write.
    FakeFacts.lose_ack("cursor")
    assert {:ok, migrated} = Store.reconcile(config, flows, now)
    run = Enum.find(migrated, &(&1["key"] == old["key"]))
    assert run["status"] == "active" and run["blocked_reason"] in [nil, ""]
    assert run["entry"] == old["entry"] + 1
    assert [audit] = run["pending"]["migrations"]
    assert audit["reason"] == mapping["reason"]
    assert audit["from"] == old["definition_sha256"]
    assert {:ok, ^run} = Run.migrate(run, flows["sort"], [mapping], now)
    assert {:ok, ^migrated} = Store.reconcile(config, flows, now)

    assert Enum.count(
             FakeFacts.sent(),
             &(&1["key"] == "B-old" and &1["values"]["mark"] == "entered")
           ) == 1

    ManualClock.advance(clock, 300_000)
    assert {:ok, later} = Store.reconcile(config, flows, ManualClock.now(clock))
    assert Enum.find(later, &(&1["key"] == old["key"]))["pending"]["migrations"] == [audit]
  end

  test "restart after a migration commits an entry but before its writes finish" do
    old = seed("B-old", old_flow())
    flow = FixtureTarget.flow()

    mapping = %{
      "from" => Run.digest(old_flow()),
      "to" => Run.digest(flow),
      "states" => %{"waiting" => "waiting"}
    }

    config = put_in(config(), ["selection", "sort", "migrations"], [mapping])
    FakeFacts.lose_ack("box")
    assert {:error, {:pending, _}} = Store.reconcile(config, %{"sort" => flow}, @now)
    {:ok, interrupted} = Store.decode(config, FakeFacts.get("cursor", old["key"]))
    assert interrupted["entry"] == old["entry"] + 1
    assert interrupted["pending"]["writes"] != []
    assert {:ok, [recovered]} = Store.reconcile(config, %{"sort" => flow}, @now)
    assert recovered["entry"] == interrupted["entry"]
    assert recovered["pending"]["writes"] == []
    assert length(recovered["pending"]["migrations"]) == 1
    assert {:ok, [^recovered]} = Store.reconcile(config, %{"sort" => flow}, @now)
    assert Enum.count(FakeFacts.sent(), &(&1["key"] == "B-old")) == 1
  end
end
