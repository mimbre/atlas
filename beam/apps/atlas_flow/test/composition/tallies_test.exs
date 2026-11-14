defmodule AtlasFlow.Composition.TalliesTest do
  @moduledoc """
  A tally of the composition: by itself (`AtlasFlow.Composition.Tallies`), and through the
  run store and fake Facts on the neutral shelf (`AtlasFlow.Shelf`), whose subflow waits
  until something of any kind stands on it. No timer is waited on: each step is one
  synchronous reconcile.
  """
  use ExUnit.Case, async: false

  alias AtlasFlow.Composition.Tallies
  alias AtlasFlow.FakeFacts
  alias AtlasFlow.Runs.{Run, Store}

  @now ~U[2026-11-13 00:00:00Z]
  @tally %{
    "parent_subject" => "shelf",
    "relation" => "on_shelf",
    "all" => "items",
    "readers" => ["stock"]
  }

  describe "by itself" do
    test "a runner applies a tally whose relation starts at some kind" do
      relations = %{"on_shelf" => %{"from" => ["jar", "tin"], "to" => ["shelf"]}}
      resolved = Tallies.resolve(@tally, relations)
      assert resolved["from"] == ["jar", "tin"]
      assert Tallies.valid?(resolved) == :ok
      assert {:error, _} = Tallies.valid?(Tallies.resolve(@tally, %{}))
      assert {:error, _} = Tallies.valid?(Map.delete(resolved, "all"))
      assert {:error, _} = Tallies.valid?(%{resolved | "readers" => []})
    end

    test "it counts every related fact once, of whatever kind; none is zero" do
      jar = %{"kind" => "jar", "key" => "J-1"}
      tin = %{"kind" => "tin", "key" => "J-1"}
      assert Tallies.values(@tally, []) == %{"items" => 0}
      assert Tallies.values(@tally, [jar, tin, jar]) == %{"items" => 2}
    end
  end

  describe "through the store" do
    setup do
      start_supervised!(FakeFacts)
      :ok = AtlasBus.attach("flow")
      %{config: config, flows: flows} = AtlasFlow.Model.load(AtlasFlow.Shelf, :prod)
      %{config: config, flows: flows}
    end

    defp reconcile(c), do: Store.reconcile(c.config, c.flows, @now)

    defp run(c, key, flow \\ "stock") do
      case FakeFacts.get("cursor", Run.key(flow, "shelf", key, 1)) do
        nil -> nil
        fact -> elem(Store.decode(c.config, fact), 1)
      end
    end

    defp put(kind, key, shelf),
      do: FakeFacts.put(kind, %{"key" => key, "links" => %{"on_shelf" => [shelf]}})

    test "the tally is applied with the relation's kinds; it moves its parent on", c do
      assert c.config["composition"]["tallies"] == [Map.put(@tally, "from", ["jar", "tin"])]

      FakeFacts.put("shelf", %{"key" => "S-1"})
      {:ok, _} = reconcile(c)
      assert FakeFacts.get("shelf", "S-1")["values"]["items"] == 0
      assert %{"state" => "empty", "status" => "active"} = run(c, "S-1")

      # A jar and a tin: two of different kinds; the next look counts both and moves on.
      put("jar", "J-1", "S-1")
      put("tin", "T-1", "S-1")
      {:ok, _} = reconcile(c)
      assert FakeFacts.get("shelf", "S-1")["values"]["items"] == 2
      assert %{"state" => "stocked", "status" => "completed"} = run(c, "S-1")
    end

    test "only the subflows that read the tally are given it: another on the parent never", c do
      FakeFacts.put("shelf", %{"key" => "S-1", "values" => %{"dusted" => "no"}})
      put("jar", "J-1", "S-1")
      {:ok, _} = reconcile(c)

      # stock reads items: counted, written, offered, and moved on.
      assert %{"state" => "stocked"} = stock = run(c, "S-1")
      assert stock["pending"]["composition"] != nil
      assert FakeFacts.get("shelf", "S-1")["values"]["items"] == 1

      # dust reads no tally: no composition record, no write of its own, no input.
      dust = run(c, "S-1", "dust")
      assert %{"state" => "dusty", "status" => "active"} = dust
      refute Map.has_key?(dust["pending"], "composition")
      refute Map.has_key?(dust["pending"], "synthetic")
      assert dust["pending"]["writes"] == []
      refute Map.has_key?(dust["last_input"], "synthetic")

      writes_of_items =
        for w <- FakeFacts.sent(),
            w["key"] == "S-1",
            Map.has_key?(w["values"] || %{}, "items"),
            do: w

      assert length(writes_of_items) == 1
    end

    test "a lost hint or a removed fact is tallied right on the next look; writes are once", c do
      FakeFacts.put("shelf", %{"key" => "S-1", "values" => %{"items" => 0}})
      put("jar", "J-1", "S-2")
      {:ok, _} = reconcile(c)
      assert %{"state" => "empty"} = run(c, "S-1")
      sent = length(FakeFacts.sent())

      # Nothing changed: nothing is written again.
      {:ok, _} = reconcile(c)
      assert length(FakeFacts.sent()) == sent

      # Moved onto S-1 without any hint: the round finds it.
      put("jar", "J-1", "S-1")
      {:ok, _} = reconcile(c)
      assert FakeFacts.get("shelf", "S-1")["values"]["items"] == 1
      assert %{"state" => "stocked"} = run(c, "S-1")
    end
  end

  describe "through the engine" do
    test "a fact that comes to relate to a parent wakes the parent's run, by its hint alone" do
      description = %{
        "entities" => Map.new(~w(shelf jar tin), &{&1, %{"plural" => &1 <> "s"}}),
        "relations" => %{"on_shelf" => %{"from" => ["jar", "tin"], "to" => ["shelf"]}}
      }

      start_supervised!({FakeFacts, description: description})
      FakeFacts.put("shelf", %{"key" => "S-1"})
      config = AtlasFlow.Model.load(AtlasFlow.Shelf, :prod).config
      clock = start_supervised!({AtlasFlow.ManualClock, @now})

      engine =
        start_supervised!(
          {AtlasFlow.Engine,
           every: 3_600_000, clock: {AtlasFlow.ManualClock, clock}, model: AtlasFlow.Shelf}
        )

      AtlasFlow.Engine.round(engine)
      key = Run.key("stock", "shelf", "S-1", 1)
      assert {:ok, %{"state" => "empty"}} = Store.decode(config, FakeFacts.get("cursor", key))

      :ok = AtlasBus.attach("tester-#{System.unique_integer([:positive])}")

      {:stored, _} =
        AtlasFlow.Talk.put("tin", %{
          "op" => "create",
          "key" => "T-1",
          "links" => %{"on_shelf" => ["S-1"]}
        })

      :sys.get_state(engine)
      assert {:ok, %{"state" => "stocked"}} = Store.decode(config, FakeFacts.get("cursor", key))
    end
  end
end
