defmodule AtlasFlow.HintsTest do
  # What a hint reaches (AtlasFlow.Engine): the runs and the presentation of the facts it
  # is about, read around those facts only; everything else is the round's. Settlement
  # requests wait for completed Bus hints; `:sys.get_state/1` only reads engine state.
  # No time passes but the manual clock's.
  use ExUnit.Case, async: false

  alias AtlasFlow.{Engine, FakeFacts, ManualClock, Settled, Talk, TestModel}
  alias AtlasFlow.Runs.{Run, Store}

  @every 3_600_000

  setup do
    Application.put_env(:atlas_bus, :store, "hints-#{System.unique_integer([:positive])}")
    :ok = AtlasBus.attach("tester-#{System.unique_integer([:positive])}")
    :ok
  end

  defp ask(position) do
    request = %{AtlasBus.Envelope.new("request", "_settled") | address: "flow"}
    :ok = AtlasBus.send(request, %{"position" => position})
    request.id
  end

  # A Bus barrier makes the no-answer check deterministic: Flow must process both
  # requests, and the Router must deliver any earlier answer before this one.
  defp pending(engine, position, id) do
    barrier = ask(0)
    assert_receive {:atlas_bus, %AtlasBus.Envelope{id: ^barrier, class: "answer"}, _}, 1_000
    refute_received {:atlas_bus, %AtlasBus.Envelope{id: ^id}, _}
    assert Settled.value(:sys.get_state(engine).settled) < position
  end

  defp settled(position) do
    id = ask(position)

    assert_receive {:atlas_bus, %AtlasBus.Envelope{id: ^id, class: "answer"},
                    %{"settled" => settled}},
                   1_000

    assert settled >= position
  end

  defp shelves(kind) do
    start_supervised!(
      {FakeFacts, description: %{"entities" => Map.new(~w(shelf jar tin), &{&1, %{}})}}
    )

    for key <- ["S-1", "S-2"], do: FakeFacts.put("shelf", %{"key" => key})
    FakeFacts.put(kind, %{"key" => "child", "links" => %{"on_shelf" => ["S-1"]}})
    engine = start_supervised!({Engine, model: AtlasFlow.Shelf, every: @every})
    Engine.round(engine)
    assert FakeFacts.get("shelf", "S-1")["values"]["items"] == 1
    assert FakeFacts.get("shelf", "S-2")["values"]["items"] == 0
    engine
  end

  defp shelf_run(key) do
    config = TestModel.config(AtlasFlow.Shelf)
    Store.decode(config, FakeFacts.get("cursor", Run.key("stock", "shelf", key, 1)))
  end

  for {action, targets} <- [{"move", ["S-2"]}, {"unlink", []}], kind <- ~w(jar tin) do
    test "a #{kind} #{action} tallies both parents before Bus settlement" do
      shelves(unquote(kind))
      # The hint must not need a dataset scan, even to find the former parent.
      GenServer.call(FakeFacts, {:block_read, "shelf", %{}})

      {:stored, p} =
        Talk.put(unquote(kind), %{
          "op" => "change",
          "key" => "child",
          "links" => %{"on_shelf" => unquote(targets)}
        })

      settled(p)
      assert FakeFacts.get("shelf", "S-1")["values"]["items"] == 0
      assert FakeFacts.get("shelf", "S-2")["values"]["items"] == length(unquote(targets))
      assert {:ok, %{"state" => "stocked", "status" => "completed"}} = shelf_run("S-1")
      state = if unquote(targets) == [], do: "empty", else: "stocked"
      assert {:ok, %{"state" => ^state}} = shelf_run("S-2")
    end
  end

  for {action, targets} <- [{"move", ["S-2"]}, {"unlink", []}],
      {phase, read} <- [
        {"discovery", %{"key" => "S-1", "plain" => true}},
        {"projection", %{"key" => "S-1", "incoming" => false}}
      ] do
    test "a #{action} holds its origin through unavailable former-parent #{phase} and recovery" do
      engine = shelves("jar")
      read = unquote(Macro.escape(read))
      GenServer.call(FakeFacts, {:block_read, "shelf", read})

      {:stored, p} =
        Talk.put("jar", %{
          "op" => "change",
          "key" => "child",
          "links" => %{"on_shelf" => unquote(targets)}
        })

      id = ask(p)
      pending(engine, p, id)

      if unquote(phase) == "discovery" do
        assert FakeFacts.get("shelf", "S-1")["values"]["items"] == 1
        assert FakeFacts.get("shelf", "S-2")["values"]["items"] == 0
      end

      {:stored, _} = Talk.put("tin", %{"op" => "create", "key" => "unrelated"})
      pending(engine, p, id)
      # A round reads subjects through its scan and projection rather than the
      # hint's plain lookup. Fail that required read too, so recovery is incomplete.
      projection = %{"key" => "S-1", "incoming" => false}
      GenServer.call(FakeFacts, {:block_read, "shelf", projection})
      Engine.round(engine)
      pending(engine, p, id)
      GenServer.call(FakeFacts, {:allow_read, "shelf", read})
      GenServer.call(FakeFacts, {:allow_read, "shelf", projection})
      Engine.round(engine)

      assert_receive {:atlas_bus, %AtlasBus.Envelope{id: ^id, class: "answer"},
                      %{"settled" => settled}},
                     1_000

      assert settled >= p
      assert FakeFacts.get("shelf", "S-1")["values"]["items"] == 0
      assert FakeFacts.get("shelf", "S-2")["values"]["items"] == length(unquote(targets))
      assert {:ok, %{"state" => "stocked"}} = shelf_run("S-1")
      state = if unquote(targets) == [], do: "empty", else: "stocked"
      assert {:ok, %{"state" => ^state}} = shelf_run("S-2")
    end
  end

  test "former tally targets may be absent, and irrelevant kinds and relations are ignored" do
    engine = shelves("jar")
    FakeFacts.put("jar", %{"key" => "absent", "links" => %{"on_shelf" => ["S-absent"]}})

    {:stored, p} =
      Talk.put("jar", %{"op" => "change", "key" => "absent", "links" => %{"on_shelf" => []}})

    settled(p)
    read = %{"key" => "S-unavailable", "plain" => true}
    GenServer.call(FakeFacts, {:block_read, "shelf", read})

    # on_shelf counts jars and tins, never shelves; another relation counts neither.
    for {kind, relation} <- [{"shelf", "on_shelf"}, {"jar", "unrelated"}] do
      FakeFacts.put(kind, %{"key" => "irrelevant", "links" => %{relation => ["S-unavailable"]}})

      {:stored, q} =
        Talk.put(kind, %{"op" => "change", "key" => "irrelevant", "links" => %{relation => []}})

      settled(q)
    end

    assert FakeFacts.get("shelf", "S-1")["values"]["items"] == 1
    assert FakeFacts.get("shelf", "S-2")["values"]["items"] == 0
    assert :sys.get_state(engine).reconciled
  end

  test "an unavailable tally-child discovery read holds the Bus input until complete recovery" do
    start_supervised!(
      {FakeFacts, description: %{"entities" => Map.new(~w(shelf jar tin), &{&1, %{}})}}
    )

    FakeFacts.put("shelf", %{"key" => "S-1"})
    engine = start_supervised!({Engine, model: AtlasFlow.Shelf, every: @every})
    Engine.round(engine)
    config = TestModel.config(AtlasFlow.Shelf)
    key = Run.key("stock", "shelf", "S-1", 1)
    read = %{"key" => "J-1", "plain" => true}
    GenServer.call(FakeFacts, {:block_read, "jar", read})

    {:stored, p} =
      Talk.put("jar", %{"op" => "create", "key" => "J-1", "links" => %{"on_shelf" => ["S-1"]}})

    id = ask(p)
    pending(engine, p, id)
    assert FakeFacts.get("shelf", "S-1")["values"]["items"] == 0
    assert {:ok, %{"state" => "empty"}} = Store.decode(config, FakeFacts.get("cursor", key))

    # An unrelated later hint must not pass the held input.
    {:stored, _} = Talk.put("tin", %{"op" => "create", "key" => "T-unrelated"})
    pending(engine, p, id)
    GenServer.call(FakeFacts, {:allow_read, "jar", read})

    # The round can recover by scanning all subjects, but cannot release on a failed
    # scan even when its run reconciliation has already succeeded.
    GenServer.call(FakeFacts, {:block_read, "shelf", %{}})
    Engine.round(engine)
    pending(engine, p, id)
    GenServer.call(FakeFacts, {:allow_read, "shelf", %{}})
    Engine.round(engine)

    assert_receive {:atlas_bus, %AtlasBus.Envelope{id: ^id, class: "answer"},
                    %{"settled" => settled}},
                   1_000

    assert settled >= p
    assert FakeFacts.get("shelf", "S-1")["values"]["items"] == 1

    assert {:ok, %{"state" => "stocked", "status" => "completed"}} =
             Store.decode(config, FakeFacts.get("cursor", key))
  end

  test "an unavailable recursive parent lookup holds the hint instead of applying a partial set" do
    c = workshop(["W-1"])
    stale("W-1")
    read = %{"key" => "W-1", "plain" => true}
    GenServer.call(FakeFacts, {:block_read, "widget", read})

    {:stored, p} =
      Talk.put("part", %{
        "op" => "create",
        "key" => "P-recursive",
        "links" => %{"of_widget" => ["W-1"]}
      })

    id = ask(p)
    pending(c.engine, p, id)
    assert todo("W-1") == "stale"
    GenServer.call(FakeFacts, {:allow_read, "widget", read})
    Engine.round(c.engine)

    assert_receive {:atlas_bus, %AtlasBus.Envelope{id: ^id, class: "answer"},
                    %{"settled" => settled}},
                   1_000

    assert settled >= p
    assert todo("W-1") == "Tend it"
  end

  test "an explicitly absent parent and an unrelated hint settle without recovery" do
    c = workshop(["W-1"])
    stale("W-1")

    {:stored, p} =
      Talk.put("part", %{
        "op" => "create",
        "key" => "P-absent",
        "links" => %{"of_widget" => ["W-absent"]}
      })

    id = ask(p)

    assert_receive {:atlas_bus, %AtlasBus.Envelope{id: ^id, class: "answer"}, %{"settled" => ^p}},
                   1_000

    {:stored, q} = Talk.put("maker", %{"op" => "change", "key" => "mia", "values" => %{}})
    id = ask(q)

    assert_receive {:atlas_bus, %AtlasBus.Envelope{id: ^id, class: "answer"}, %{"settled" => ^q}},
                   1_000

    assert todo("W-1") == "stale"
    :sys.get_state(c.engine)
  end

  test "a failed recursive lookup through a deletion's former links holds its input" do
    c = workshop(["W-1"])

    {:stored, created} =
      Talk.put("part", %{
        "op" => "create",
        "key" => "P-delete",
        "links" => %{"of_widget" => ["W-1"]}
      })

    ready = ask(created)
    assert_receive {:atlas_bus, %AtlasBus.Envelope{id: ^ready, class: "answer"}, _}, 1_000
    stale("W-1")
    read = %{"key" => "W-1", "plain" => true}
    GenServer.call(FakeFacts, {:block_read, "widget", read})
    {:stored, p} = Talk.put("part", %{"op" => "delete", "key" => "P-delete"})
    id = ask(p)
    pending(c.engine, p, id)
    assert FakeFacts.get("part", "P-delete") == nil
    assert todo("W-1") == "stale"
    GenServer.call(FakeFacts, {:allow_read, "widget", read})
    Engine.round(c.engine)

    assert_receive {:atlas_bus, %AtlasBus.Envelope{id: ^id, class: "answer"},
                    %{"settled" => settled}},
                   1_000

    assert settled >= p
    assert todo("W-1") == "Tend it"
  end

  test "relinking and unlinking project both parents and deletion uses the stored former links" do
    workshop(["W-1", "W-2"])

    {:stored, created} =
      Talk.put("part", %{
        "op" => "create",
        "key" => "P-move",
        "links" => %{"of_widget" => ["W-1"]}
      })

    settled(created)
    stale("W-1")
    stale("W-2")

    {:stored, p} =
      Talk.put("part", %{
        "op" => "change",
        "key" => "P-move",
        "links" => %{"of_widget" => ["W-2"]}
      })

    id = ask(p)

    assert_receive {:atlas_bus, %AtlasBus.Envelope{id: ^id, class: "answer"},
                    %{"settled" => settled}},
                   1_000

    assert settled >= p
    assert todo("W-1") == "Tend it"
    assert todo("W-2") == "Tend it"
    stale("W-1")
    stale("W-2")

    {:stored, unlinked} =
      Talk.put("part", %{"op" => "change", "key" => "P-move", "links" => %{"of_widget" => []}})

    settled(unlinked)
    assert todo("W-1") == "stale"
    assert todo("W-2") == "Tend it"

    {:stored, relinked} =
      Talk.put("part", %{
        "op" => "change",
        "key" => "P-move",
        "links" => %{"of_widget" => ["W-2"]}
      })

    settled(relinked)
    stale("W-2")
    {:stored, q} = Talk.put("part", %{"op" => "delete", "key" => "P-move"})
    id = ask(q)

    assert_receive {:atlas_bus, %AtlasBus.Envelope{id: ^id, class: "answer"},
                    %{"settled" => deleted}},
                   1_000

    assert deleted >= q
    assert todo("W-2") == "Tend it"
  end

  # The workshop: a widget is open until done, and its maker mia tends it.
  defp workshop(widgets, opts \\ []) do
    start_supervised!({FakeFacts, description: AtlasFlow.Workshop.description()})
    if Keyword.get(opts, :maker, true), do: FakeFacts.put("maker", %{"key" => "mia"})
    for key <- widgets, do: widget(key)
    clock = start_supervised!({ManualClock, ~U[2026-11-12 00:00:00Z]})

    engine =
      start_supervised!(
        {Engine, every: @every, clock: {ManualClock, clock}, model: AtlasFlow.Workshop}
      )

    Engine.round(engine)
    %{engine: engine, clock: clock}
  end

  defp widget(key),
    do: FakeFacts.put("widget", %{"key" => key, "values" => %{"title" => key}})

  defp todo(key), do: FakeFacts.get("widget", key)["values"]["todo"]

  defp stale(key) do
    FakeFacts.put("widget", put_in(FakeFacts.get("widget", key), ["values", "todo"], "stale"))
  end

  # One hint and everything it causes: `{reads, facts read}` by Flow meanwhile.
  defp cost(c, fun) do
    {reads, _} = FakeFacts.reads()
    facts = FakeFacts.facts_read()
    fun.()
    :sys.get_state(c.engine)
    {after_reads, _} = FakeFacts.reads()
    {after_reads - reads, FakeFacts.facts_read() - facts}
  end

  test "a hint reads around the facts it is about, as much with 200 facts as with 10" do
    c = workshop(for n <- 1..10, do: "W-#{n}")

    # A part made under a widget that had none: the same hint, whatever else exists.
    part = fn key, widget ->
      Talk.put("part", %{"op" => "create", "key" => key, "links" => %{"of_widget" => [widget]}})
    end

    few = cost(c, fn -> part.("P-1", "W-1") end)
    for n <- 11..200, do: widget("W-#{n}")
    Engine.round(c.engine)
    assert todo("W-200") == "Tend it"

    many = cost(c, fn -> part.("P-2", "W-2") end)
    assert many == few
  end

  test "a delete reaches what was above the fact it removed, from its links, and nothing else" do
    c = workshop(["W-1", "W-2"])

    {:stored, _} =
      Talk.put("part", %{"op" => "create", "key" => "P-1", "links" => %{"of_widget" => ["W-1"]}})

    :sys.get_state(c.engine)
    stale("W-1")
    stale("W-2")

    {:stored, p} = Talk.put("part", %{"op" => "delete", "key" => "P-1"})
    state = :sys.get_state(c.engine)
    assert todo("W-1") == "Tend it"
    assert todo("W-2") == "stale"
    assert Settled.value(state.settled) >= p
  end

  test "a new owner projects again only the facts that wait for it" do
    c = workshop(["W-1", "W-2"], maker: false)
    assert todo("W-1") == "Tend it"
    assert FakeFacts.get("widget", "W-1")["links"]["tended_by"] == nil

    assert :sys.get_state(c.engine).waiting == %{
             {"maker", "mia"} => MapSet.new([{"widget", "W-1"}, {"widget", "W-2"}])
           }

    # Another maker: nobody waits for it.
    {:stored, _} = Talk.put("maker", %{"op" => "create", "key" => "bob"})
    :sys.get_state(c.engine)
    assert FakeFacts.get("widget", "W-1")["links"]["tended_by"] == nil

    {:stored, _} = Talk.put("maker", %{"op" => "create", "key" => "mia"})
    state = :sys.get_state(c.engine)
    assert FakeFacts.get("widget", "W-1")["links"]["tended_by"] == ["mia"]
    assert FakeFacts.get("widget", "W-2")["links"]["tended_by"] == ["mia"]
    assert state.waiting == %{}
  end

  test "a fact changed without a hint is still found by the round" do
    c = workshop(["W-1"])
    widget("W-9")
    :sys.get_state(c.engine)
    assert todo("W-9") == nil

    ManualClock.advance(c.clock, @every)
    :sys.get_state(c.engine)
    assert todo("W-9") == "Tend it"
  end

  test "a hint reconciles the run of the fact it is about, and no other run" do
    start_supervised!(FakeFacts)
    for key <- ["ada", "bob"], do: FakeFacts.put("clerk", %{"key" => key})

    for key <- ["B-1", "B-2"],
        do: FakeFacts.put("box", %{"key" => key, "values" => %{"phase" => "first"}})

    clock = start_supervised!({ManualClock, ~U[2026-11-12 00:00:00Z]})

    engine =
      start_supervised!(
        {Engine, every: @every, clock: {ManualClock, clock}, model: AtlasFlow.Depot}
      )

    Engine.round(engine)
    config = TestModel.config()

    run = fn key ->
      Store.decode(config, FakeFacts.get("cursor", Run.key("sort", "box", key, 1)))
    end

    {:ok, other} = run.("B-2")

    {:stored, _} =
      Talk.put("box", %{
        "op" => "change",
        "key" => "B-1",
        "values" => %{"phase" => "first", "result" => "ok"}
      })

    :sys.get_state(engine)
    assert {:ok, %{"status" => "completed"}} = run.("B-1")
    assert run.("B-2") == {:ok, other}
  end
end
