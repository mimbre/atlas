defmodule AtlasFlow.Runs.RunTest do
  use ExUnit.Case, async: false
  alias AtlasFlow.{FakeFacts, FixtureTarget, ManualClock, Talk}
  alias AtlasFlow.Runs.{Run, Store}

  @now ~U[2026-11-12 00:00:00Z]
  defp subject(values \\ %{}),
    do: %{"key" => "B-1", "values" => Map.merge(%{"phase" => "first"}, values)}

  defp config, do: FakeFacts.run_description()["flow_runtime"]

  defmodule UnsupportedTarget do
    def rela_flows_sha256, do: AtlasFlow.FixtureTarget.rela_flows_sha256()
    def check_rela_flows(bytes), do: AtlasFlow.FixtureTarget.check_rela_flows(bytes)

    def flows,
      do: put_in(AtlasFlow.FixtureTarget.flows(), ["sort", "states", "waiting", "kind"], "gate")
  end

  defmodule AbsentTarget do
    def rela_flows_sha256, do: raise("no environment pair")
    def flows, do: raise("no generated flows")
    def gates, do: raise("no gates or answer limits")
    def check_rela_flows(_), do: raise("no deployed YAML")
  end

  test "an unselected composition needs no environment pair, gates or limits" do
    description = put_in(FakeFacts.run_description(), ["flow_runtime", "selection"], %{})
    assert {:ok, nil} = Store.activate(description, AbsentTarget, nil)
    assert {:ok, []} = Store.reconcile(nil, %{}, @now)
    assert FakeFacts.sent() == []
  end

  @tag :tmp_dir
  test "activation refuses unsupported selected data with zero writes", %{tmp_dir: dir} do
    yaml = Path.join(dir, "flows.yaml")
    File.write!(yaml, "fixture\n")

    assert {:error, {:unsupported_definition, "sort"}} =
             Store.activate(FakeFacts.run_description(), UnsupportedTarget, yaml)

    assert FakeFacts.sent() == []
  end

  defp new(values \\ %{}) do
    Run.new(
      "sort",
      FixtureTarget.flow(),
      subject(values),
      config()["selection"]["sort"]["imports"],
      @now
    )
  end

  test "ordered equalities, missing values, durable finality and imports" do
    flow = FixtureTarget.flow()
    run = new()
    assert Run.validate(flow) == :ok
    run = put_in(run, ["pending", "writes"], [])
    assert {:ok, ^run} = Run.step(run, flow, subject(), @now)
    assert {:ok, final} = Run.step(run, flow, subject(%{"result" => "ok"}), @now)
    assert final["state"] == "done" and final["status"] == "completed"
    assert {:ok, ^final} = Run.step(final, flow, subject(%{"result" => "no"}), @now)
    branches = flow["states"]["waiting"]["branches"]

    flow =
      put_in(flow, ["states", "waiting", "branches"], [
        hd(branches),
        %{hd(branches) | "to" => "discarded"}
      ])

    assert {:ok, %{"state" => "done"}} =
             Run.step(
               %{run | "definition_sha256" => Run.digest(flow)},
               flow,
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
    flow = FixtureTarget.flow()
    run = new() |> put_in(["pending", "writes"], []) |> put_in(["deadlines", "timers"], [])
    old = Map.put(run, "definition_sha256", "old")

    mapping = %{
      "from" => "old",
      "to" => Run.digest(flow),
      "states" => %{"waiting" => "waiting", "done" => "done"}
    }

    assert {:error, :definition_changed} = Run.migrate(old, flow, [], @now)

    assert {:error, :definition_changed} =
             Run.migrate(old, flow, [put_in(mapping, ["states", "waiting"], "missing")], @now)

    assert {:ok, migrated} = Run.migrate(old, flow, [mapping], @now)
    assert migrated["entry"] == old["entry"] + 1
    assert migrated["key"] == old["key"]
    assert migrated["definition_sha256"] == Run.digest(flow)

    assert {:error, _} =
             Run.migrate(put_in(old, ["deadlines", "timers"], [%{}]), flow, [mapping], @now)

    completed = old |> Map.put("status", "completed") |> Map.put("state", "done")
    assert {:ok, historical} = Run.migrate(completed, flow, [mapping], @now)
    assert historical["entry"] == completed["entry"]
    assert historical["pending"]["writes"] == []
    assert historical["status"] == "completed"
  end

  test "refuses every unsupported executable feature before activation" do
    flow = FixtureTarget.flow()

    for invalid <- [
          put_in(flow, ["start"], [%{"on" => "predicate"}]),
          put_in(flow, ["states", "waiting", "kind"], "gate"),
          put_in(flow, ["states", "waiting", "creates"], [%{}]),
          put_in(
            flow,
            ["states", "waiting", "branches", Access.at(0), "when"],
            "System.cmd('x')"
          )
        ],
        do: assert({:error, _} = Run.validate(invalid))
  end

  test "overdue timers use due time first and declaration order for ties" do
    for {period, expected} <- [{"5m", "done"}, {"1m", "discarded"}] do
      flow =
        put_in(FixtureTarget.flow(), ["states", "waiting", "timers"], [
          %{"name" => "first", "period" => "5m", "to" => "done"},
          %{"name" => "second", "period" => period, "to" => "discarded"}
        ])

      run = Run.new("sort", flow, subject(), [], @now) |> put_in(["pending", "writes"], [])

      assert {:ok, transitioned} =
               Run.step(run, flow, subject(), DateTime.add(@now, 360, :second))

      assert transitioned["state"] == expected
    end
  end

  setup do
    Application.put_env(:atlas_bus, :store, "runs-#{System.unique_integer([:positive])}")
    start_supervised!({FakeFacts, description: FakeFacts.run_description()})
    :ok = AtlasBus.attach("flow")
    clock = start_supervised!({ManualClock, @now})
    FakeFacts.put("box", subject())
    %{clock: clock}
  end

  defp reconcile(clock),
    do: Store.reconcile(config(), FixtureTarget.flows(), ManualClock.now(clock))

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
    changed = put_in(FixtureTarget.flows(), ["sort", "states", "waiting", "label"], "Changed")
    before = FakeFacts.sent()

    assert {:error, {:definition_changed, _}} =
             Store.reconcile(config(), changed, ManualClock.now(clock))

    assert FakeFacts.sent() == before
  end
end
