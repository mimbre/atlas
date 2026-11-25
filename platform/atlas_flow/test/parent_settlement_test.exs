defmodule AtlasFlow.ParentSettlementTest do
  use ExUnit.Case, async: false

  alias AtlasBus.Envelope
  alias AtlasFlow.{Engine, FakeFacts, ManualClock, Settled, Talk}
  alias AtlasFlow.Runs.Store

  defmodule Nested do
    @behaviour AtlasFlow.Model
    def subflows(env),
      do: Enum.reject(AtlasFlow.Yard.Nested.subflows(env), &(&1.name() == "tally"))

    defdelegate runs(), to: AtlasFlow.Yard.Nested
    defdelegate composition(), to: AtlasFlow.Yard.Nested
    defdelegate actors(), to: AtlasFlow.Yard.Nested
    defdelegate turn(), to: AtlasFlow.Yard.Nested

    # Composition relations need not be presentation parents. Only Store
    # discovers these ancestors.
    def relations do
      Map.new(AtlasFlow.Yard.Nested.relations(), fn {name, relation} ->
        {name, Map.delete(relation, "parent")}
      end)
    end

    def selection(name) do
      AtlasFlow.Yard.Nested.selection(name)
      |> Map.put("projection", %{"field" => "todo", "state_field" => "projected"})
    end
  end

  defmodule Carded do
    use AtlasFlow.TestModel,
      subflows: Nested.subflows(:test),
      runs: Nested.runs(),
      composition: Nested.composition(),
      selection:
        Map.new(~w(pour fill pack), fn name ->
          {name,
           Nested.selection(name)
           |> update_in(["projection"], &Map.put(&1, "on", "card"))}
        end),
      relations:
        Map.put(Nested.relations(), "card", %{
          "from" => ~w(basket tray cup),
          "to" => ["card"],
          "component" => %{}
        })
  end

  setup do
    Application.put_env(:atlas_bus, :store, "parents-#{System.unique_integer([:positive])}")
    :ok = AtlasBus.attach("parent-tester")
    clock = start_supervised!({ManualClock, ~U[2026-11-14 00:00:00Z]})
    %{clock: clock}
  end

  defp description(kinds),
    do: %{"entities" => Map.new(kinds, &{&1, %{"plural" => &1 <> "s"}})}

  defp ask(position) do
    request = %{Envelope.new("request", "_settled") | address: "flow"}
    :ok = AtlasBus.send(request, %{"position" => position})
    request.id
  end

  defp answered(id, position) do
    assert_receive {:atlas_bus, %Envelope{id: ^id, class: "answer"}, %{"settled" => settled}},
                   1_000

    assert settled >= position
  end

  for {level, parent_state, ancestor_state} <- [
        {"full", "filled", "packed"},
        {"spilt", "spilt", "spilt"}
      ],
      failure <- [false, :parent, :ancestor] do
    test "a #{level} cup projects parent and ancestor cards before settlement; failure=#{failure}",
         c do
      start_supervised!(
        {FakeFacts, description: description(~w(basket tray cup hand cursor choice card))}
      )

      FakeFacts.put("hand", %{"key" => "ada"})

      for {kind, key, links} <- [
            {"basket", "B-1", %{}},
            {"tray", "T-1", %{"in_basket" => ["B-1"]}},
            {"cup", "C-1", %{"on_tray" => ["T-1"]}}
          ] do
        FakeFacts.put(kind, %{
          "key" => key,
          "values" => %{"phase" => "first", "revision" => "r1"},
          "links" => Map.put(links, "card", ["card-" <> key])
        })

        FakeFacts.put("card", %{"key" => "card-" <> key})
      end

      engine =
        start_supervised!(
          {Engine, model: Carded, every: 3_600_000, clock: {ManualClock, c.clock}}
        )

      Engine.round(engine)
      assert FakeFacts.get("card", "card-T-1")["values"]["projected"] == "waiting"
      assert FakeFacts.get("card", "card-B-1")["values"]["projected"] == "waiting"
      config = :sys.get_state(engine).runner.config
      assert {:ok, parent_before} = Store.latest(config, "fill", "tray", "T-1")
      assert {:ok, ancestor_before} = Store.latest(config, "pack", "basket", "B-1")
      # No hint: only the leaf completion recursive reconciliation can repair this.
      card = FakeFacts.get("card", "card-B-1")
      FakeFacts.put("card", put_in(card, ["values", "todo"], "stale"))
      failed_card = if unquote(failure) == :ancestor, do: "card-B-1", else: "card-T-1"

      if unquote(failure),
        do: GenServer.call(FakeFacts, {:refuse_write, "card", failed_card})

      {:stored, p} =
        Talk.put("cup", %{
          "op" => "change",
          "key" => "C-1",
          "values" => %{"level" => unquote(level)}
        })

      id = ask(p)
      state = :sys.get_state(engine)

      assert {:ok, child} = Store.latest(config, "pour", "cup", "C-1")
      assert {child["state"], child["status"]} == {unquote(level), "completed"}
      assert {:ok, parent} = Store.latest(config, "fill", "tray", "T-1")
      assert {parent["state"], parent["status"]} == {unquote(parent_state), "completed"}
      assert parent["entry"] == parent_before["entry"] + 1
      assert {:ok, ancestor} = Store.latest(config, "pack", "basket", "B-1")
      assert {ancestor["state"], ancestor["status"]} == {unquote(ancestor_state), "completed"}
      assert ancestor["entry"] == ancestor_before["entry"] + 1
      assert FakeFacts.get("tray", "T-1")["values"]["outcome"] == unquote(level)
      assert FakeFacts.get("basket", "B-1")["values"]["outcome"] == unquote(level)

      if unquote(failure) do
        assert Settled.value(state.settled) < p
        refute_received {:atlas_bus, %Envelope{id: ^id}, _}

        if unquote(failure) == :ancestor do
          assert FakeFacts.get("card", "card-B-1")["values"]["todo"] == "stale"
        else
          assert FakeFacts.get("card", "card-T-1")["values"]["projected"] == "waiting"
        end

        Engine.round(engine)
        assert Settled.value(:sys.get_state(engine).settled) < p
        refute_received {:atlas_bus, %Envelope{id: ^id}, _}
        GenServer.call(FakeFacts, {:allow_write, "card", failed_card})
        Engine.round(engine)
      end

      answered(id, p)

      for key <- ["card-T-1", "card-B-1"] do
        values = FakeFacts.get("card", key)["values"]
        assert values["projected"] == nil
        assert values["todo"] in [nil, ""]
      end

      for key <- ["T-1", "B-1"] do
        assert Enum.count(FakeFacts.sent(), fn write ->
                 write["key"] == key and Map.has_key?(write["values"] || %{}, "outcome")
               end) == 1
      end

      writes = FakeFacts.sent()
      Engine.round(engine)
      assert FakeFacts.sent() == writes
    end
  end

  for failure <- [false, true] do
    test "all nested composition ancestors project before settlement; grandparent failure=#{failure}",
         c do
      start_supervised!(
        {FakeFacts, description: description(~w(basket tray cup hand cursor choice))}
      )

      FakeFacts.put("hand", %{"key" => "ada"})

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

      engine =
        start_supervised!(
          {Engine, model: Nested, every: 3_600_000, clock: {ManualClock, c.clock}}
        )

      Engine.round(engine)
      assert FakeFacts.get("basket", "B-1")["values"]["projected"] == "waiting"
      assert FakeFacts.get("tray", "T-1")["values"]["projected"] == "waiting"
      read = %{"key" => "B-1", "incoming" => false}
      if unquote(failure), do: GenServer.call(FakeFacts, {:block_read, "basket", read})

      {:stored, p} =
        Talk.put("cup", %{"op" => "change", "key" => "C-1", "values" => %{"level" => "full"}})

      id = ask(p)
      state = :sys.get_state(engine)

      assert {:ok, %{"state" => "packed"}} =
               Store.latest(state.runner.config, "pack", "basket", "B-1")

      assert {:ok, %{"state" => "filled"}} =
               Store.latest(state.runner.config, "fill", "tray", "T-1")

      if unquote(failure) do
        assert Settled.value(state.settled) < p
        refute_received {:atlas_bus, %Envelope{id: ^id}, _}
        Engine.round(engine)
        assert Settled.value(:sys.get_state(engine).settled) < p
        refute_received {:atlas_bus, %Envelope{id: ^id}, _}
        assert FakeFacts.get("basket", "B-1")["values"]["projected"] == "waiting"
        GenServer.call(FakeFacts, {:allow_read, "basket", read})
        Engine.round(engine)
      end

      answered(id, p)
      assert FakeFacts.get("tray", "T-1")["values"]["projected"] == nil
      assert FakeFacts.get("basket", "B-1")["values"]["projected"] == nil
      writes = FakeFacts.sent()
      Engine.round(engine)
      assert FakeFacts.sent() == writes
    end
  end
end
