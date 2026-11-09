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

  defp legacy_digest(flow),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(flow)) |> Base.encode16(case: :lower)

  defp rekey(flow) do
    %{
      "from" => legacy_digest(flow),
      "to" => Run.digest(flow),
      "rekey" => true,
      "states" => Map.new(flow["states"], fn {state, _} -> {state, state} end),
      "reason" => "Canonical JSON identity"
    }
  end

  test "an explicit encoding re-key preserves every entry field, including in-flight work and imports" do
    flow = FixtureTarget.flow()
    fresh = Run.new("sort", flow, subject("B-1"), [], @now)

    for run <- [
          fresh,
          put_in(fresh, ["pending", "gate"], %{"id" => "frozen", "request" => %{"evidence" => 1}}),
          %{fresh | "state" => "done", "status" => "completed"},
          %{
            fresh
            | "state" => "done",
              "status" => "completed",
              "last_input" => %{"version" => 1, "import" => true}
          },
          %{fresh | "status" => "idle"},
          %{fresh | "status" => "blocked", "blocked_reason" => "other reason"}
        ] do
      old = Map.put(run, "definition_sha256", legacy_digest(flow))
      assert {:error, :definition_changed} = Run.migrate(old, flow, [], @now)
      assert {:ok, migrated} = Run.migrate(old, flow, [rekey(flow)], @now)
      assert migrated["definition_sha256"] == Run.digest(flow)
      assert [audit] = migrated["pending"]["migrations"]

      assert Map.drop(migrated, ["definition_sha256", "pending"]) ==
               Map.drop(old, ["definition_sha256", "pending"])

      assert Map.delete(migrated["pending"], "migrations") == old["pending"]

      assert audit == %{
               "from" => legacy_digest(flow),
               "to" => Run.digest(flow),
               "state" => old["state"],
               "entry" => old["entry"],
               "at" => DateTime.to_iso8601(@now),
               "reason" => "Canonical JSON identity"
             }

      assert {:ok, ^migrated} = Run.migrate(migrated, flow, [rekey(flow)], @now)
    end

    blocked =
      fresh |> Map.put("definition_sha256", legacy_digest(flow)) |> Run.block_definition(flow)

    assert {:ok, recovered} = Run.migrate(blocked, flow, [rekey(flow)], @now)
    assert recovered["status"] == fresh["status"]
    assert recovered["entry"] == fresh["entry"]
    refute recovered["pending"]["definition_block"]
    assert recovered["blocked_reason"] == ""
    bad = put_in(rekey(flow), ["states", "waiting"], "done")
    assert {:error, :definition_changed} = Run.migrate(blocked, flow, [bad], @now)
    changed = put_in(flow, ["states", "waiting", "timers"], [])
    assert {:error, :definition_changed} = Run.migrate(blocked, changed, [rekey(flow)], @now)
  end

  @tag :tmp_dir
  test "engine restarts over legacy digests without re-entering or resetting deadlines", %{
    clock: clock,
    tmp_dir: dir
  } do
    alias AtlasFlow.Engine
    flow = FixtureTarget.flow()
    config = put_in(config(), ["selection", "sort", "migrations"], [rekey(flow)])
    FakeFacts.set_description(Map.put(FakeFacts.run_description(), "flow_runtime", config))
    old = seed("B-restart", flow)

    old =
      old
      |> Map.put("definition_sha256", legacy_digest(flow))
      |> put_in(["pending", "writes"], [])

    FakeFacts.put("cursor", %{"key" => old["key"], "values" => Store.encode(config, old)})
    yaml = Path.join(dir, "flows.yaml")
    File.write!(yaml, "fixture\n")
    opts = [clock: {ManualClock, clock}, target: FixtureTarget, deployed_yaml: yaml]

    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(AtlasFlow.Supervisor),
          do: DynamicSupervisor.terminate_child(AtlasFlow.Supervisor, pid)
    end)

    FakeFacts.lose_ack("cursor")
    Registry.unregister(AtlasBus.Endpoints, "flow")
    engine = start_supervised!({Engine, opts})
    :ok = Engine.round(engine)
    assert {:ok, migrated} = Store.decode(config, FakeFacts.get("cursor", old["key"]))
    assert migrated["definition_sha256"] == Run.digest(flow)
    assert migrated["state"] == old["state"]
    assert migrated["entry"] == old["entry"]
    assert migrated["entered_at"] == old["entered_at"]
    assert migrated["deadlines"] == old["deadlines"]
    assert length(migrated["pending"]["migrations"]) == 1
    stop_supervised!(Engine)
    restarted = start_supervised!({Engine, opts})
    :ok = Engine.round(restarted)
    assert {:ok, ^migrated} = Store.decode(config, FakeFacts.get("cursor", old["key"]))
    refute Enum.any?(FakeFacts.sent(), &(&1["values"]["mark"] == "entered"))
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
