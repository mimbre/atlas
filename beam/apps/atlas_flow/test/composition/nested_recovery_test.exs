defmodule AtlasFlow.Composition.NestedRecoveryTest do
  use ExUnit.Case, async: false
  alias AtlasFlow.FakeFacts
  alias AtlasFlow.Runs.{Run, Store}
  @now ~U[2026-11-13 00:00:00Z]

  setup do
    start_supervised!(FakeFacts)
    :ok = AtlasBus.attach("flow")

    %{config: config, flows: flows, refusal: nil} =
      AtlasFlow.Model.load(AtlasFlow.Yard.Nested, :prod)

    for {kind, key, links} <- [
          {"basket", "B-1", %{}},
          {"tray", "T-1", %{"in_basket" => ["B-1"]}},
          {"cup", "C-1", %{"on_tray" => ["T-1"]}}
        ] do
      FakeFacts.put(kind, %{
        "key" => key,
        "values" => %{"phase" => "first", "revision" => "r1"},
        "links" => links
      })
    end

    {:ok, known} = Store.reconcile(config, flows, @now)
    %{config: config, flows: flows, known: known}
  end

  defp stored(c, name, kind, key) do
    {:ok, run} = Store.decode(c.config, FakeFacts.get("cursor", Run.key(name, kind, key, 1)))
    run
  end

  test "a failed grandparent read is reported and the next round recovers without double writes",
       c do
    before = length(FakeFacts.sent())
    cup = FakeFacts.get("cup", "C-1")
    FakeFacts.put("cup", put_in(cup, ["values", "level"], "full"))
    GenServer.call(FakeFacts, {:busy, "basket", "B-1"})

    assert {:error, {:subject_unavailable, _}} =
             Store.reconcile_subjects(c.config, c.flows, @now, c.known, [{"cup", "C-1"}])

    assert stored(c, "pour", "cup", "C-1")["status"] == "completed"
    assert stored(c, "fill", "tray", "T-1")["status"] == "completed"
    assert stored(c, "pack", "basket", "B-1")["entry"] == 1

    GenServer.call(FakeFacts, {:free, "basket", "B-1"})
    assert {:ok, _} = Store.reconcile(c.config, c.flows, @now)
    assert stored(c, "pack", "basket", "B-1")["status"] == "completed"
    assert FakeFacts.get("basket", "B-1")["values"]["outcome"] == "full"

    for key <- ["T-1", "B-1"] do
      assert Enum.count(Enum.drop(FakeFacts.sent(), before), fn write ->
               write["key"] == key and Map.has_key?(write["values"] || %{}, "outcome")
             end) == 1
    end
  end

  for mode <- [:round, :hint] do
    test "a leaf's completion reaches its grandparent once in the same #{mode}", c do
      # In a round the basket is visited before the cup and tray. A hint visits only
      # the cup. Neither may rely on another round or a hint for Flow's own writes.
      first = stored(c, "pack", "basket", "B-1")
      assert {first["state"], first["entry"]} == {"waiting", 1}
      before = length(FakeFacts.sent())
      cup = FakeFacts.get("cup", "C-1")
      FakeFacts.put("cup", put_in(cup, ["values", "level"], "full"))

      result =
        case unquote(mode) do
          :round -> Store.reconcile(c.config, c.flows, @now)
          :hint -> Store.reconcile_subjects(c.config, c.flows, @now, c.known, [{"cup", "C-1"}])
        end

      assert {:ok, runs} = result

      basket = stored(c, "pack", "basket", "B-1")
      assert {basket["state"], basket["status"], basket["entry"]} == {"packed", "completed", 2}
      assert FakeFacts.get("basket", "B-1")["values"]["outcome"] == "full"
      assert [%{"child" => "T-1", "entry" => 2}] = basket["last_input"]["sources"]
      assert Enum.find(runs, &(&1["key"] == basket["key"])) == basket
      assert stored(c, "fill", "tray", "T-1")["status"] == "completed"

      # One write of each linked outcome; retries and the next round write none again.
      for key <- ["T-1", "B-1"] do
        assert Enum.count(Enum.drop(FakeFacts.sent(), before), fn write ->
                 write["key"] == key and Map.has_key?(write["values"] || %{}, "outcome")
               end) == 1
      end

      sent = length(FakeFacts.sent())
      assert {:ok, _} = Store.reconcile_subjects(c.config, c.flows, @now, runs, [{"cup", "C-1"}])
      assert {:ok, _} = Store.reconcile(c.config, c.flows, @now)
      assert stored(c, "pack", "basket", "B-1") == basket
      assert length(FakeFacts.sent()) == sent
    end
  end
end
