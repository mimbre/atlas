defmodule AtlasFlow.HintsTest do
  # What a hint reaches (AtlasFlow.Engine): the processes and runs of the facts it is
  # about, read around those facts only; everything else is the round's. No time passes
  # but the manual clock's.
  use ExUnit.Case, async: false

  alias AtlasFlow.{Engine, FakeFacts, ManualClock, Settled, Talk, TestModel}
  alias AtlasFlow.Runs.{Run, Store}

  @every 3_600_000

  setup do
    Application.put_env(:atlas_bus, :store, "hints-#{System.unique_integer([:positive])}")
    :ok = Supervisor.terminate_child(AtlasFlow.Root, AtlasFlow.Supervisor)
    {:ok, _} = Supervisor.restart_child(AtlasFlow.Root, AtlasFlow.Supervisor)
    :ok = AtlasBus.attach("tester-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(AtlasFlow.Supervisor),
          do: DynamicSupervisor.terminate_child(AtlasFlow.Supervisor, pid)
    end)

    :ok
  end

  # The workshop: a widget is open until completed, and its maker mia tends it.
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
    settle(engine)
    %{engine: engine, clock: clock}
  end

  defp widget(key),
    do: FakeFacts.put("widget", %{"key" => key, "values" => %{"title" => key}})

  defp item(kind, key) do
    case Registry.lookup(AtlasFlow.Items, {kind, key}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp items,
    do: for({_, pid, _, _} <- DynamicSupervisor.which_children(AtlasFlow.Supervisor), do: pid)

  # Every process handled what it was sent (twice: a first look, then what it wrote), and
  # the engine what they reported.
  defp settle(engine) do
    for _ <- 1..2 do
      for pid <- items(), do: :sys.get_state(pid)
      :sys.get_state(engine)
    end
  end

  # The pokes are handled (each poked process scheduled its look), then the looks run.
  defp look(c) do
    :sys.get_state(c.engine)
    for pid <- items(), do: :sys.get_state(pid)
    ManualClock.advance(c.clock, 50)
    settle(c.engine)
  end

  # The processes the last hint poked: they hold its ticket until they look.
  defp poked(engine), do: Map.keys(:sys.get_state(engine).settled.tickets)

  # One hint and every look it causes: `{reads, facts read}` by Flow meanwhile.
  defp cost(c, fun) do
    {reads, _} = FakeFacts.reads()
    facts = FakeFacts.facts_read()
    fun.()
    look(c)
    assert :sys.get_state(c.engine).settled.tickets == %{}
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
    settle(c.engine)
    assert length(items()) == 200

    many = cost(c, fn -> part.("P-2", "W-2") end)
    assert many == few
  end

  test "a delete pokes what was above the fact it removed, from its links, and nothing else" do
    c = workshop(["W-1", "W-2"])

    {:stored, _} =
      Talk.put("part", %{"op" => "create", "key" => "P-1", "links" => %{"of_widget" => ["W-1"]}})

    look(c)

    {:stored, p} = Talk.put("part", %{"op" => "delete", "key" => "P-1"})
    assert poked(c.engine) == [item("widget", "W-1")]

    look(c)
    assert Settled.value(:sys.get_state(c.engine).settled) >= p
  end

  test "a new owner pokes only the processes that wait for it" do
    c = workshop(["W-1", "W-2"], maker: false)
    waiting = Enum.sort([item("widget", "W-1"), item("widget", "W-2")])

    assert Enum.sort(
             for {pid, _} <- Registry.lookup(AtlasFlow.Waiting, {"maker", "mia"}), do: pid
           ) ==
             waiting

    # Another maker: nobody waits for it.
    {:stored, _} = Talk.put("maker", %{"op" => "create", "key" => "bob"})
    assert poked(c.engine) == []

    {:stored, _} = Talk.put("maker", %{"op" => "create", "key" => "mia"})
    assert Enum.sort(poked(c.engine)) == waiting

    look(c)
    assert FakeFacts.get("widget", "W-1")["links"]["tended_by"] == ["mia"]
    assert Registry.lookup(AtlasFlow.Waiting, {"maker", "mia"}) == []
  end

  test "a fact changed without a hint is still found by the round" do
    c = workshop(["W-1"])
    widget("W-9")
    :sys.get_state(c.engine)
    assert item("widget", "W-9") == nil

    ManualClock.advance(c.clock, @every)
    settle(c.engine)
    assert is_pid(item("widget", "W-9"))
    assert FakeFacts.get("widget", "W-9")["values"]["todo"] == "Tend it"
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
    settle(engine)
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
