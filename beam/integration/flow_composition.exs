# Private neutral model (atlas_flow's test yard: cups on trays), the real Bus and Flow's
# engine and run store, fake Facts and a manual clock. No timer is waited on: each look
# is one synchronous engine round.
# From beam/: MIX_ENV=test mix run integration/flow_composition.exs
#
# This proves Flow's composition (links, counts, the parent's durable writes and its
# synthetic input) on a private contract. It selects no production subflow: the model the
# core runs links or counts nothing until slice 7 selects both ends of a link.
ExUnit.start()

defmodule FlowCompositionProof do
  use ExUnit.Case, async: false
  alias AtlasFlow.{Engine, FakeFacts, ManualClock}
  alias AtlasFlow.Runs.{Run, Store}
  @now ~U[2026-11-13 00:00:00Z]

  @description %{
    "entities" => Map.new(~w(tray cup hand cursor choice), &{&1, %{"plural" => &1 <> "s"}}),
    "relations" => %{"on_tray" => %{"from" => ["cup"], "to" => ["tray"], "max_outgoing" => 1}}
  }

  setup do
    start_supervised!({FakeFacts, description: @description})
    clock = start_supervised!({ManualClock, @now})
    # The engine is the endpoint `flow`; the proof reads the fake store directly.
    %{config: config} = AtlasFlow.Model.load(AtlasFlow.Yard, :prod)
    %{clock: clock, config: config}
  end

  defp engine(c),
    do:
      start_supervised!(
        {Engine, every: 3_600_000, clock: {ManualClock, c.clock}, model: AtlasFlow.Yard}
      )

  # Flow keeps nothing: stop its engine and application, start them again.
  defp restart(c) do
    stop_supervised!(Engine)
    :ok = Application.stop(:atlas_flow)
    {:ok, _} = Application.ensure_all_started(:atlas_flow)
    engine(c)
  end

  defp put(kind, key, values, links \\ %{}),
    do: FakeFacts.put(kind, %{"key" => key, "values" => values, "links" => links})

  defp change(kind, key, values) do
    fact = FakeFacts.get(kind, key)
    FakeFacts.put(kind, Map.update!(fact, "values", &Map.merge(&1, values)))
  end

  defp run(c, name, kind, key) do
    {:ok, run} = Store.decode(c.config, FakeFacts.get("cursor", Run.key(name, kind, key, 1)))
    run
  end

  defp counts(key), do: Map.take(FakeFacts.get("tray", key)["values"], ~w(cups open_cups))

  defp writes(key, field),
    do: for(w <- FakeFacts.sent(), w["key"] == key, Map.has_key?(w["values"] || %{}, field), do: w)

  test "a current child advances its parent once; a replaced child completing late does nothing",
       c do
    e = engine(c)
    put("tray", "T-1", %{"phase" => "first", "revision" => "r1"})
    put("cup", "C-1", %{"phase" => "first", "revision" => "r1"}, %{"on_tray" => ["T-1"]})
    Engine.round(e)
    assert run(c, "fill", "tray", "T-1")["state"] == "waiting"

    # The tray moves to revision r2 and gets a cup poured for it: C-1 is replaced.
    change("tray", "T-1", %{"revision" => "r2"})
    put("cup", "C-2", %{"phase" => "first", "revision" => "r2"}, %{"on_tray" => ["T-1"]})
    Engine.round(e)

    change("cup", "C-1", %{"level" => "full"})
    Engine.round(e)
    assert run(c, "pour", "cup", "C-1")["status"] == "completed"
    assert run(c, "fill", "tray", "T-1")["state"] == "waiting"
    assert writes("T-1", "outcome") == []
    IO.puts("replaced cup C-1 completed late: tray T-1 still waiting, outcome writes=0")

    change("cup", "C-2", %{"level" => "spilt"})
    Engine.round(e)
    fill = run(c, "fill", "tray", "T-1")
    assert {fill["state"], fill["entry"]} == {"spilt", 2}
    assert [%{"child" => "C-2", "current" => "r2"}] = fill["last_input"]["sources"]
    assert [%{"values" => %{"outcome" => "spilt"}}] = writes("T-1", "outcome")

    # Settled: more rounds, a restart and an hour on the manual clock change nothing.
    Engine.round(e)
    e = restart(c)
    ManualClock.advance(c.clock, 3_600_000)
    Engine.round(e)
    assert run(c, "fill", "tray", "T-1") == fill
    assert length(writes("T-1", "outcome")) == 1

    IO.puts(
      "current cup C-2 completed: tray T-1 #{fill["state"]} at entry #{fill["entry"]}, " <>
        "outcome writes=#{length(writes("T-1", "outcome"))} after restart"
    )
  end

  test "counts are rebuilt from the children after a restart, not counted on", c do
    e = engine(c)
    put("tray", "T-1", %{"phase" => "first", "revision" => "r1"})
    put("tray", "T-2", %{"phase" => "first", "revision" => "r1"})

    for key <- ~w(C-1 C-2 C-3),
        do: put("cup", key, %{"phase" => "first", "revision" => key}, %{"on_tray" => ["T-1"]})

    Engine.round(e)
    assert counts("T-1") == %{"cups" => 3, "open_cups" => 3}
    assert counts("T-2") == %{"cups" => 0, "open_cups" => 0}
    assert run(c, "tally", "tray", "T-2")["status"] == "idle"
    IO.puts("before: T-1 #{inspect(counts("T-1"))}, T-2 #{inspect(counts("T-2"))} (empty)")

    # While Flow is down, and without a hint: C-1 is poured, C-2 deleted, C-3 moved to T-2,
    # and T-1's stored counts are wrong.
    stop_supervised!(Engine)
    :ok = Application.stop(:atlas_flow)
    change("cup", "C-1", %{"level" => "full"})
    GenServer.call(FakeFacts, {:drop, "cup", "C-2"})
    FakeFacts.put("cup", put_in(FakeFacts.get("cup", "C-3"), ["links", "on_tray"], ["T-2"]))
    change("tray", "T-1", %{"cups" => 99, "open_cups" => 99})

    {:ok, _} = Application.ensure_all_started(:atlas_flow)
    e = engine(c)
    Engine.round(e)
    assert counts("T-1") == %{"cups" => 1, "open_cups" => 0}
    assert counts("T-2") == %{"cups" => 1, "open_cups" => 1}
    assert run(c, "tally", "tray", "T-1")["state"] == "counted"
    assert run(c, "tally", "tray", "T-2")["state"] == "counting"

    Engine.round(e)
    assert counts("T-1") == %{"cups" => 1, "open_cups" => 0}

    IO.puts(
      "after restart: T-1 #{inspect(counts("T-1"))} (tally counted), " <>
        "T-2 #{inspect(counts("T-2"))} (tally counting)"
    )
  end
end
