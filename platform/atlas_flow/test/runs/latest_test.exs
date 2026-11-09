defmodule AtlasFlow.Runs.LatestTest do
  use ExUnit.Case, async: false

  alias AtlasFlow.{FakeFacts, Talk, TestModel}
  alias AtlasFlow.Runs.{Run, Store}

  @now ~U[2026-11-14 00:00:00Z]

  setup do
    Application.put_env(:atlas_bus, :store, "latest-#{System.unique_integer([:positive])}")
    start_supervised!(FakeFacts)
    :ok = AtlasBus.attach("flow")
    :ok
  end

  test "no stored run is absence" do
    assert {:ok, nil} = Store.latest(TestModel.config(), "sort", "box", "missing")
  end

  test "durable restarts through 64 and 65 select the successor and preserve read failures" do
    config = put_in(TestModel.config(), ["selection", "sort", "restart_by"], ["owner"])
    flows = %{"sort" => TestModel.sort()}
    subject = %{"key" => "B-1", "values" => %{"phase" => "first", "result" => "old"}}
    FakeFacts.put("box", subject)

    assert {:ok, [%{"generation" => 1, "status" => "completed"}]} =
             Store.reconcile(config, flows, @now)

    Enum.each(1..64, fn generation ->
      FakeFacts.put("box", subject)
      assert {:ok, current} = Store.latest(config, "sort", "box", "B-1")
      assert current["generation"] == generation

      id = "restart-#{generation}"

      request = %{
        "op" => "submit",
        "key" => id,
        "values" => %{
          "run" => current["key"],
          "entry" => current["entry"],
          "roles" => ["restart"],
          "changed_fields" => %{}
        }
      }

      assert {:stored, _} = Talk.put("choice", request, id)
      assert {:ok, [successor]} = Store.reconcile(config, flows, @now)
      assert {successor["generation"], successor["status"]} == {generation + 1, "active"}
      assert {:ok, ^successor} = Store.latest(config, "sort", "box", "B-1")

      FakeFacts.put("box", put_in(subject, ["values", "result"], "ok"))
      assert {:ok, [completed]} = Store.reconcile(config, flows, @now)
      assert {completed["generation"], completed["status"]} == {generation + 1, "completed"}
      assert {:ok, ^completed} = Store.latest(config, "sort", "box", "B-1")
    end)

    # An unreadable successor or next key must not silently select an older run.
    for generation <- [65, 66] do
      key = Run.key("sort", "box", "B-1", generation)
      GenServer.call(FakeFacts, {:busy, "cursor", key})
      assert {:error, %{"error" => _}} = Store.latest(config, "sort", "box", "B-1")
      GenServer.call(FakeFacts, {:free, "cursor", key})
    end

    key = Run.key("sort", "box", "B-1", 65)
    fact = FakeFacts.get("cursor", key)
    FakeFacts.put("cursor", put_in(fact, ["values", "pending"], "invalid JSON"))
    assert {:error, :invalid_record} = Store.latest(config, "sort", "box", "B-1")
    FakeFacts.put("cursor", put_in(fact, ["values", "pending"], JSON.encode!(%{"version" => 2})))
    assert {:error, :unknown_record_version} = Store.latest(config, "sort", "box", "B-1")
  end
end
