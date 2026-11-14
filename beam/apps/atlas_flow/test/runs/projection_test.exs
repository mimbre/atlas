defmodule AtlasFlow.Runs.ProjectionTest do
  @moduledoc """
  What the engine writes of what a run presents (`AtlasFlow.Runs.Projection`), on a
  selected two-state sort (`AtlasFlow.Sorts.Handover`: bob packs a box, ada checks it):
  what is expected, the state, and the owner, with the owner rules: an owner set by hand
  stays while the state stays, an owner that does not exist yet waits, nothing is written
  half when Facts does not answer, and a handover waits while the current owner's turn
  runs on the box, across a full restart. Settlement requests wait for completed Bus
  hints; `:sys.get_state/1` only reads engine state.
  """
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias AtlasFlow.{Engine, FakeFacts, Sorts, Talk}

  # A turn runs on a box (`work`) by a clerk: an owner is not handed over while it runs.
  defmodule Handed do
    use AtlasFlow.TestModel,
      subflows: [AtlasFlow.Sorts.Handover],
      selection: %{
        "sort" => %{
          "subject" => "box",
          "projection" => %{
            "field" => "todo",
            "state_field" => "step",
            "handover_field" => "later",
            "owner_relation" => "owned_by"
          },
          "admission" => %{},
          "imports" => [],
          "migrations" => []
        }
      },
      relations:
        Map.put(AtlasFlow.Depot.relations(), "work", %{"from" => ["run"], "to" => ["box"]}),
      turn: %{
        "kind" => "run",
        "on" => "work",
        "by" => "worker",
        "state" => "status",
        "running" => "going"
      }
  end

  # The same, written on the box's card (a component), which turns work on.
  defmodule Carded do
    use AtlasFlow.TestModel,
      subflows: [AtlasFlow.Sorts.Handover],
      selection: %{
        "sort" => %{
          "subject" => "box",
          "projection" => %{
            "on" => "card",
            "field" => "todo",
            "handover_field" => "later",
            "owner_relation" => "owned_by"
          },
          "admission" => %{},
          "imports" => [],
          "migrations" => []
        }
      },
      relations:
        AtlasFlow.Depot.relations()
        |> Map.put("card", %{"from" => ["box"], "to" => ["card"], "component" => %{}})
        |> Map.put("owned_by", %{"from" => ["box", "card"], "to" => ["clerk"]})
        |> Map.put("work", %{"from" => ["run"], "to" => ["card"]}),
      turn: %{
        "kind" => "run",
        "on" => "work",
        "by" => "worker",
        "state" => "status",
        "running" => "going"
      }
  end

  setup do
    Application.put_env(:atlas_bus, :store, "projection-#{System.unique_integer([:positive])}")
    start_supervised!(FakeFacts)
    FakeFacts.set_description(put_in(FakeFacts.description(), ["entities", "run"], %{}))
    for key <- ["ada", "bob"], do: FakeFacts.put("clerk", %{"key" => key})
    :ok = AtlasBus.attach("tester-#{System.unique_integer([:positive])}")
    :ok
  end

  defp engine, do: start_supervised!({Engine, every: 3_600_000, model: Handed}, id: Engine)

  defp expected(state), do: Sorts.Handover.present(state, %{})["expected"]
  defp box(key), do: FakeFacts.get("box", key)
  defp owners(key), do: box(key)["links"]["owned_by"]
  defp later(key), do: box(key)["values"]["later"]

  # What Flow sent for the box: its changes, not the run's cursor.
  defp sent(key), do: for(%{"key" => ^key} = c <- FakeFacts.sent(), do: c)

  defp change(kind, key, values \\ %{}) do
    {:stored, _} = Talk.put(kind, %{"op" => "change", "key" => key, "values" => values})
  end

  defp ask(position) do
    request = %{AtlasBus.Envelope.new("request", "_settled") | address: "flow"}
    :ok = AtlasBus.send(request, %{"position" => position})
    request.id
  end

  defp pending(server, position, id) do
    barrier = ask(0)
    assert_receive {:atlas_bus, %AtlasBus.Envelope{id: ^barrier, class: "answer"}, _}, 1_000
    refute_received {:atlas_bus, %AtlasBus.Envelope{id: ^id}, _}
    assert AtlasFlow.Settled.value(:sys.get_state(server).settled) < position
  end

  test "a failed component reverse lookup holds its input, while an empty lookup settles" do
    FakeFacts.set_description(put_in(FakeFacts.description(), ["entities", "card"], %{}))
    FakeFacts.put("box", %{"key" => "B-1", "links" => %{"card" => ["C-1"]}})
    FakeFacts.put("card", %{"key" => "C-1"})
    server = start_supervised!({Engine, model: Carded, every: 3_600_000})
    Engine.round(server)
    read = %{"linked" => %{"card" => "C-1"}}
    GenServer.call(FakeFacts, {:block_read, "box", read})

    {:stored, p} =
      Talk.put("card", %{"op" => "change", "key" => "C-1", "values" => %{"todo" => "stale"}})

    id = ask(p)
    pending(server, p, id)
    assert FakeFacts.get("card", "C-1")["values"]["todo"] == "stale"
    GenServer.call(FakeFacts, {:allow_read, "box", read})
    Engine.round(server)

    assert_receive {:atlas_bus, %AtlasBus.Envelope{id: ^id, class: "answer"},
                    %{"settled" => settled}},
                   1_000

    assert settled >= p
    assert FakeFacts.get("card", "C-1")["values"]["todo"] == expected("packing")

    {:stored, q} = Talk.put("card", %{"op" => "create", "key" => "C-orphan"})
    id = ask(q)

    assert_receive {:atlas_bus, %AtlasBus.Envelope{id: ^id, class: "answer"}, %{"settled" => ^q}},
                   1_000
  end

  test "what the run presents is written in one change, with its cause; again, nothing" do
    FakeFacts.put("box", %{"key" => "B-1"})
    server = engine()
    Engine.round(server)

    assert [
             %{
               "op" => "change",
               "values" => %{"todo" => todo, "step" => "packing"},
               "links" => %{"owned_by" => ["bob"]},
               "by" => "flow",
               "cause" => cause
             }
           ] = sent("B-1")

    assert todo == expected("packing") and is_binary(cause)

    # Projected again, as it is: safe to repeat.
    Engine.round(server)
    change("crate", "C-1")
    :sys.get_state(server)
    assert length(sent("B-1")) == 1
  end

  test "an owner set by hand stays while the state stays; a new state moves it" do
    FakeFacts.put("clerk", %{"key" => "cy"})

    FakeFacts.put("box", %{
      "key" => "B-1",
      "values" => %{"todo" => expected("packing"), "step" => "packing"},
      "links" => %{"owned_by" => ["cy"]},
      "origins" => %{"owned_by" => %{"keys" => ["cy"], "by" => "ada", "cause" => "cy packs"}}
    })

    server = engine()
    Engine.round(server)
    # Packing still: cy, whom ada chose, stays.
    assert sent("B-1") == []
    assert owners("B-1") == ["cy"]

    # All in it is packed: a new state, and its owner.
    change("box", "B-1", %{"stage" => "check"})
    :sys.get_state(server)
    assert owners("B-1") == ["ada"]
    assert box("B-1")["values"]["todo"] == expected("check")
    assert box("B-1")["values"]["step"] == "check"
  end

  test "handed over before Flow's first look: the first projection writes what is expected only" do
    FakeFacts.put("clerk", %{"key" => "cy"})

    FakeFacts.put("box", %{
      "key" => "B-1",
      "links" => %{"owned_by" => ["cy"]},
      "origins" => %{"owned_by" => %{"keys" => ["cy"], "by" => "ada", "cause" => "handed"}}
    })

    Engine.round(engine())
    assert [sent] = sent("B-1")
    refute Map.has_key?(sent, "links")
    assert owners("B-1") == ["cy"]
  end

  test "an owner Flow, a migration or nobody set follows the state" do
    for {key, origin} <- [
          {"B-1", %{"by" => "migration"}},
          {"B-2", %{"by" => "flow"}},
          {"B-3", nil}
        ] do
      FakeFacts.put("box", %{
        "key" => key,
        "values" => %{"todo" => expected("packing"), "step" => "packing"},
        "links" => %{"owned_by" => ["ada"]},
        "origins" => if(origin, do: %{"owned_by" => origin}, else: %{})
      })
    end

    Engine.round(engine())

    for key <- ["B-1", "B-2", "B-3"] do
      assert [%{"values" => values, "links" => %{"owned_by" => ["bob"]}}] = sent(key)
      assert values == %{}
    end
  end

  test "an owner that does not exist yet: what is expected is written, the owner waits" do
    GenServer.call(FakeFacts, {:drop, "clerk", "bob"})
    FakeFacts.put("box", %{"key" => "B-1"})
    server = engine()
    Engine.round(server)
    assert [sent] = sent("B-1")
    assert sent["values"]["todo"] == expected("packing")
    refute Map.has_key?(sent, "links")

    # Once the owner is made, the box gets it at once.
    FakeFacts.put("clerk", %{"key" => "bob"})
    {:stored, p} = Talk.put("clerk", %{"op" => "create", "key" => "bob", "values" => %{}})
    id = ask(p)

    assert_receive {:atlas_bus, %AtlasBus.Envelope{id: ^id, class: "answer"},
                    %{"settled" => settled}},
                   1_000

    assert settled >= p
    assert owners("B-1") == ["bob"]
  end

  test "Facts does not answer whether the owner exists: nothing is written, not half" do
    GenServer.call(FakeFacts, {:busy, "clerk", "bob"})
    FakeFacts.put("box", %{"key" => "B-1"})
    server = engine()
    Engine.round(server)
    assert sent("B-1") == []

    # Facts answers again: the next projection writes both, in one change.
    GenServer.call(FakeFacts, {:free, "clerk", "bob"})
    change("box", "B-1")
    :sys.get_state(server)

    assert [%{"values" => %{"todo" => _}, "links" => %{"owned_by" => ["bob"]}}] =
             Enum.filter(sent("B-1"), &(&1["by"] == "flow"))
  end

  test "a required component read holds the Bus waiter until recovery writes its work" do
    FakeFacts.put("card", %{"key" => "C-1"})
    server = start_supervised!({Engine, every: 3_600_000, model: Carded})
    Engine.round(server)
    read = %{"key" => "C-1", "plain" => true}
    GenServer.call(FakeFacts, {:block_read, "card", read})

    {:stored, p} =
      Talk.put("box", %{"op" => "create", "key" => "B-1", "links" => %{"card" => ["C-1"]}})

    request = %{AtlasBus.Envelope.new("request", "_settled") | address: "flow"}
    :ok = AtlasBus.send(request, %{"position" => p})
    id = request.id
    :sys.get_state(server)
    refute_received {:atlas_bus, %AtlasBus.Envelope{id: ^id}, _}
    Engine.round(server)
    :sys.get_state(server)
    refute_received {:atlas_bus, %AtlasBus.Envelope{id: ^id}, _}
    assert FakeFacts.get("card", "C-1")["values"]["todo"] == nil
    GenServer.call(FakeFacts, {:allow_read, "card", read})
    Engine.round(server)

    assert_receive {:atlas_bus, %AtlasBus.Envelope{id: ^id, class: "answer"},
                    %{"settled" => settled}},
                   1_000

    assert settled >= p
    assert FakeFacts.get("card", "C-1")["values"]["todo"] == expected("packing")
    assert FakeFacts.get("card", "C-1")["links"]["owned_by"] == ["bob"]
  end

  test "an unavailable turn read holds the Bus waiter and preserves the current owner" do
    FakeFacts.put("box", %{"key" => "B-1"})
    server = engine()
    Engine.round(server)
    read = %{"linked" => %{"work" => "B-1"}, "plain" => true}
    GenServer.call(FakeFacts, {:block_read, "run", read})

    {:stored, p} =
      Talk.put("box", %{"op" => "change", "key" => "B-1", "values" => %{"stage" => "check"}})

    request = %{AtlasBus.Envelope.new("request", "_settled") | address: "flow"}
    :ok = AtlasBus.send(request, %{"position" => p})
    id = request.id
    :sys.get_state(server)
    refute_received {:atlas_bus, %AtlasBus.Envelope{id: ^id}, _}
    assert owners("B-1") == ["bob"]
    Engine.round(server)
    :sys.get_state(server)
    refute_received {:atlas_bus, %AtlasBus.Envelope{id: ^id}, _}
    GenServer.call(FakeFacts, {:allow_read, "run", read})
    Engine.round(server)

    assert_receive {:atlas_bus, %AtlasBus.Envelope{id: ^id, class: "answer"},
                    %{"settled" => settled}},
                   1_000

    assert settled >= p
    assert owners("B-1") == ["ada"]
    assert box("B-1")["values"]["todo"] == expected("check")
  end

  describe "a handover deferred while a turn runs" do
    # Bob packs B-1 and his turn runs on it; it is all packed now, so ada is to check it.
    defp deferred do
      FakeFacts.put("box", %{
        "key" => "B-1",
        "values" => %{"todo" => expected("packing"), "stage" => "check"},
        "links" => %{"owned_by" => ["bob"]},
        "origins" => %{"owned_by" => %{"by" => "human", "position" => 1}}
      })

      FakeFacts.put("run", %{
        "key" => "R-1",
        "values" => %{"status" => "going"},
        "links" => %{"work" => ["B-1"], "worker" => ["bob"]}
      })

      server = engine()
      Engine.round(server)
      assert box("B-1")["values"]["todo"] == expected("check")
      assert owners("B-1") == ["bob"]
      assert later("B-1") != nil
      server
    end

    defp end_turn(server) do
      FakeFacts.put("run", put_in(FakeFacts.get("run", "R-1"), ["values", "status"], "over"))
      change("run", "R-1")
      :sys.get_state(server)
    end

    test "an unavailable ended-turn discovery read holds settlement through failed recovery" do
      server = deferred()
      read = %{"key" => "R-1", "plain" => true}
      GenServer.call(FakeFacts, {:block_read, "run", read})

      {:stored, p} =
        Talk.put("run", %{"op" => "change", "key" => "R-1", "values" => %{"status" => "over"}})

      id = ask(p)
      pending(server, p, id)
      assert owners("B-1") == ["bob"]
      assert later("B-1") != nil
      GenServer.call(FakeFacts, {:allow_read, "run", read})

      # Discovery recovery alone cannot release the input while its projection fails.
      GenServer.call(FakeFacts, {:busy, "clerk", "ada"})
      Engine.round(server)
      pending(server, p, id)
      assert owners("B-1") == ["bob"]
      GenServer.call(FakeFacts, {:free, "clerk", "ada"})
      Engine.round(server)

      assert_receive {:atlas_bus, %AtlasBus.Envelope{id: ^id, class: "answer"},
                      %{"settled" => settled}},
                     1_000

      assert settled >= p
      assert owners("B-1") == ["ada"]
      assert later("B-1") == nil
    end

    test "it survives a full restart, then moves once the turn ended" do
      server = deferred()
      stop_supervised!(Engine)
      assert server |> Process.alive?() |> Kernel.not()

      server = engine()
      Engine.round(server)
      assert owners("B-1") == ["bob"]
      assert later("B-1") != nil

      end_turn(server)
      assert owners("B-1") == ["ada"]
      assert later("B-1") == nil
    end

    test "it also waits for the next owner to exist" do
      GenServer.call(FakeFacts, {:drop, "clerk", "ada"})
      server = deferred()
      end_turn(server)
      assert owners("B-1") == ["bob"]
      assert later("B-1") != nil

      FakeFacts.put("clerk", %{"key" => "ada"})
      {:stored, _} = Talk.put("clerk", %{"op" => "create", "key" => "ada", "values" => %{}})
      :sys.get_state(server)
      assert owners("B-1") == ["ada"]
      assert later("B-1") == nil
    end

    test "a human handover cancels it" do
      server = deferred()
      FakeFacts.put("clerk", %{"key" => "carol"})

      FakeFacts.put(
        "box",
        box("B-1")
        |> put_in(["links", "owned_by"], ["carol"])
        |> put_in(["origins", "owned_by"], %{"by" => "human", "position" => 2})
      )

      change("box", "B-1")
      :sys.get_state(server)
      assert later("B-1") == nil
      assert owners("B-1") == ["carol"]
    end

    test "on a component, the turn on the component holds it" do
      FakeFacts.put("box", %{
        "key" => "B-1",
        "values" => %{"stage" => "check"},
        "links" => %{"card" => ["C-1"]}
      })

      FakeFacts.put("card", %{
        "key" => "C-1",
        "values" => %{"todo" => expected("packing")},
        "links" => %{"owned_by" => ["bob"]},
        "origins" => %{"owned_by" => %{"by" => "human", "position" => 1}}
      })

      FakeFacts.put("run", %{
        "key" => "R-1",
        "values" => %{"status" => "going"},
        "links" => %{"work" => ["C-1"], "worker" => ["bob"]}
      })

      server = start_supervised!({Engine, every: 3_600_000, model: Carded}, id: Engine)
      Engine.round(server)
      card = FakeFacts.get("card", "C-1")
      assert card["values"]["todo"] == expected("check")
      assert card["links"]["owned_by"] == ["bob"]
      assert card["values"]["later"] != nil

      end_turn(server)
      assert FakeFacts.get("card", "C-1")["links"]["owned_by"] == ["ada"]
      assert FakeFacts.get("card", "C-1")["values"]["later"] == nil
    end

    test "the turn's end projects its own box, not every other" do
      FakeFacts.put("box", %{"key" => "B-2"})
      server = deferred()
      assert box("B-2")["values"]["todo"] == expected("packing")
      FakeFacts.put("box", put_in(box("B-2"), ["values", "todo"], "untouched"))

      end_turn(server)
      assert owners("B-1") == ["ada"]
      assert box("B-2")["values"]["todo"] == "untouched"
    end
  end
end
