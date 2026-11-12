defmodule AtlasFlowTest do
  use ExUnit.Case, async: false

  alias AtlasFlow.{Engine, FakeFacts, Legacy, Packs}

  # The depot's legacy flow, as the model compiled it.
  @pack AtlasFlow.Depot.Legacy.Pack

  defmodule Later do
    use AtlasFlow.TestModel, legacy: [AtlasFlow.Packs.Later]
  end

  defmodule Carded do
    use AtlasFlow.TestModel, legacy: [AtlasFlow.Packs.Carded]
  end

  defmodule Stepped do
    use AtlasFlow.TestModel, legacy: [AtlasFlow.Packs.Stepped]
  end

  defmodule Labelled do
    use AtlasFlow.TestModel, legacy: [AtlasFlow.Packs.Labelled]
  end

  setup do
    Application.put_env(:atlas_bus, :store, "state-#{System.unique_integer([:positive])}")

    # A fresh supervisor for the facts' processes: none is left from another test, and one
    # killed in an earlier test does not count against the restarts it allows.
    :ok = Supervisor.terminate_child(AtlasFlow.Root, AtlasFlow.Supervisor)
    {:ok, _} = Supervisor.restart_child(AtlasFlow.Root, AtlasFlow.Supervisor)
    # Registry drops a stopped process's name a moment later; till then the engine finds it.
    eventually(fn -> Registry.count(AtlasFlow.Items) == 0 end)

    # None is left for another test either: a later test that looks at every process in the
    # supervisor, or starts one under the same name, finds only its own. Stopping is
    # synchronous; a name the Registry still holds for a stopped process can be taken.
    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(AtlasFlow.Supervisor),
          do: DynamicSupervisor.terminate_child(AtlasFlow.Supervisor, pid)
    end)

    start_supervised!(FakeFacts)
    # Who can own, as facts: the owners the definition names must exist.
    for key <- ["ada", "bob"], do: FakeFacts.put("clerk", %{"key" => key})
    :ok
  end

  defp engine(model \\ AtlasFlow.Depot),
    do: start_supervised!({Engine, every: 3_600_000, model: model})

  defp alive(key), do: Registry.lookup(AtlasFlow.Items, {"box", key}) != []

  defp eventually(fun, tries \\ 150) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("did not happen")
      true -> Process.sleep(20) && eventually(fun, tries - 1)
    end
  end

  defp deferred_setup do
    description = FakeFacts.description()
    description = put_in(description, ["entities", "run"], %{})

    description =
      put_in(description, ["relations", "work"], %{"from" => ["run"], "to" => ["box"]})

    description =
      Map.put(description, "runtime", %{
        "turn" => %{
          "kind" => "run",
          "on" => "work",
          "by" => "worker",
          "state" => "status",
          "running" => "going"
        }
      })

    FakeFacts.set_description(description)

    FakeFacts.put("box", %{
      "key" => "B-1",
      "values" => %{"todo" => "Pack it"},
      "links" => %{"owned_by" => ["bob"]},
      "origins" => %{"owned_by" => %{"by" => "human", "position" => 1}},
      "progress" => %{"value" => "check"}
    })

    FakeFacts.put("run", %{
      "key" => "R-1",
      "values" => %{"status" => "going"},
      "links" => %{"work" => ["B-1"], "worker" => ["bob"]}
    })

    pid = engine(Later)
    AtlasBus.attach("observer-#{System.unique_integer([:positive])}")
    eventually(fn -> FakeFacts.get("box", "B-1")["values"]["later"] != nil end)
    pid
  end

  test "deferred ownership survives process restart, then moves after the running turn ends" do
    engine_pid = deferred_setup()
    fact = FakeFacts.get("box", "B-1")
    assert fact["values"]["todo"] == "Check it"
    assert fact["links"]["owned_by"] == ["bob"]
    [{pid, _}] = Registry.lookup(AtlasFlow.Items, {"box", "B-1"})
    DynamicSupervisor.terminate_child(AtlasFlow.Supervisor, pid)
    Engine.round(engine_pid)
    eventually(fn -> alive("B-1") end)
    assert FakeFacts.get("box", "B-1")["links"]["owned_by"] == ["bob"]
    run = FakeFacts.get("run", "R-1") |> put_in(["values", "status"], "over")
    FakeFacts.put("run", run)
    AtlasFlow.Talk.put("run", %{"op" => "change", "key" => "R-1", "values" => %{}})
    eventually(fn -> FakeFacts.get("box", "B-1")["links"]["owned_by"] == ["ada"] end)
    assert FakeFacts.get("box", "B-1")["values"]["later"] == nil
  end

  test "a deferred handover also waits for the next owner to exist" do
    GenServer.call(FakeFacts, {:drop, "clerk", "ada"})
    deferred_setup()
    assert FakeFacts.get("box", "B-1")["links"]["owned_by"] == ["bob"]
    run = FakeFacts.get("run", "R-1") |> put_in(["values", "status"], "over")
    FakeFacts.put("run", run)
    AtlasFlow.Talk.put("run", %{"op" => "change", "key" => "R-1", "values" => %{}})
    [{pid, _}] = Registry.lookup(AtlasFlow.Items, {"box", "B-1"})
    send(pid, :look)
    :sys.get_state(pid)
    assert FakeFacts.get("box", "B-1")["values"]["later"] != nil
    FakeFacts.put("clerk", %{"key" => "ada"})
    AtlasFlow.Talk.put("clerk", %{"op" => "create", "key" => "ada", "values" => %{}})
    eventually(fn -> FakeFacts.get("box", "B-1")["links"]["owned_by"] == ["ada"] end)
  end

  test "a turn end wakes its own fact without reconciling unrelated open facts" do
    FakeFacts.put("box", %{"key" => "B-2"})
    deferred_setup()
    eventually(fn -> FakeFacts.get("box", "B-2")["values"]["todo"] == "Pack it" end)
    other = FakeFacts.get("box", "B-2") |> put_in(["values", "todo"], "not poked")
    FakeFacts.put("box", other)
    run = FakeFacts.get("run", "R-1") |> put_in(["values", "status"], "over")
    FakeFacts.put("run", run)
    AtlasFlow.Talk.put("run", %{"op" => "change", "key" => "R-1", "values" => %{}})
    eventually(fn -> FakeFacts.get("box", "B-1")["links"]["owned_by"] == ["ada"] end)
    Process.sleep(100)
    assert FakeFacts.get("box", "B-2")["values"]["todo"] == "not poked"
  end

  test "a human handover cancels the deferred automatic move" do
    deferred_setup()
    for key <- ["carol"], do: FakeFacts.put("clerk", %{"key" => key})

    fact =
      FakeFacts.get("box", "B-1")
      |> put_in(["links", "owned_by"], ["carol"])
      |> put_in(["origins", "owned_by"], %{"by" => "human", "position" => 2})

    FakeFacts.put("box", fact)
    AtlasFlow.Talk.put("box", %{"op" => "change", "key" => "B-1", "values" => %{}})
    eventually(fn -> FakeFacts.get("box", "B-1")["values"]["later"] == nil end)
    assert FakeFacts.get("box", "B-1")["links"]["owned_by"] == ["carol"]
  end

  test "a component hint does not restart completed work to remove a historical owner" do
    description = FakeFacts.description()

    description =
      put_in(description, ["relations", "card"], %{
        "from" => ["box"],
        "to" => ["card"],
        "component" => %{}
      })

    FakeFacts.set_description(put_in(description, ["entities", "card"], %{}))

    FakeFacts.put("box", %{
      "key" => "B-done",
      "completion" => %{"done" => true},
      "links" => %{"card" => ["C-done"]}
    })

    FakeFacts.put("card", %{
      "key" => "C-done",
      "links" => %{"owned_by" => ["ada"]},
      "origins" => %{"owned_by" => %{"by" => "migration"}}
    })

    server = engine(Carded)
    Engine.round(server)
    AtlasBus.attach("observer-#{System.unique_integer([:positive])}")
    {reads, _} = FakeFacts.reads()
    AtlasFlow.Talk.put("card", %{"op" => "change", "key" => "C-done", "values" => %{}})
    eventually(fn -> elem(FakeFacts.reads(), 0) > reads end)
    :sys.get_state(server)
    Process.sleep(150)
    refute alive("B-done")
    assert FakeFacts.get("card", "C-done")["links"]["owned_by"] == ["ada"]
    refute Enum.any?(FakeFacts.sent(), &(&1["by"] == "flow"))
  end

  describe "the state a fact is in (the compiled legacy flow)" do
    test "the first state that holds; the last when none other does" do
      name = fn fact, children -> elem(@pack.state(fact, children, ["in_box"], []), 0) end

      assert name.(%{"completion" => %{"done" => true}}, []) == "done"
      assert name.(%{"progress" => %{"value" => "check"}}, []) == "check"
      assert name.(%{"progress" => %{"value" => "draft"}}, []) == "packing"
      assert name.(%{}, []) == "packing"
    end

    test "reopened: the newest fact removed the link, and nothing came under it since" do
      fact = %{
        "progress" => %{"value" => "check"},
        "origins" => %{"signed_by" => %{"keys" => [], "position" => 40, "cause" => "a crack"}}
      }

      older = %{"origins" => %{"in_box" => %{"position" => 12}}}
      newer = %{"origins" => %{"in_box" => %{"position" => 41}}}

      assert {"again", vars} = @pack.state(fact, [older], ["in_box"], [])
      assert @pack.expected("again", vars) == "Again: a crack"
      assert @pack.owner("again") == %{"kind" => "clerk", "key" => "bob"}

      # A crate came under it since: the work goes on as usual.
      assert {"check", _} = @pack.state(fact, [older, newer], ["in_box"], [])

      signed = put_in(fact, ["origins", "signed_by"], %{"keys" => ["ada"], "position" => 40})
      assert {"check", _} = @pack.state(signed, [], ["in_box"], [])
    end

    test "empty: nothing under it through a relation its kind has things under through" do
      name = fn children, parents -> elem(Packs.Split.state(%{}, children, parents, []), 0) end

      assert name.([], ["in_box"]) == "split"
      assert name.([%{"links" => %{"in_box" => ["B-1"]}}], ["in_box"]) == "packing"
      # A kind nothing belongs under through it is never empty through it.
      assert name.([], ["in_crate"]) == "packing"
    end

    test "done: nobody owns it and nothing is expected" do
      assert @pack.done?("done")
      assert @pack.owner("done") == nil
      assert @pack.expected("done", %{}) == nil
      assert @pack.expected("again", %{"note" => ""}) == "Again"
    end

    test "a flow Facts found problems in is not run" do
      flows = AtlasFlow.Depot.legacy()
      assert Legacy.kinds(Legacy.runnable(flows, FakeFacts.description())) == ["box"]
      assert Legacy.runnable(flows, FakeFacts.description(["x has no owner"])) == []
    end

    test "briefed by the empty state until something is under it, then by the next" do
      briefing = fn children ->
        {state, vars} = Packs.Filled.state(%{}, children, ["in_box"], [])
        {state, Packs.Filled.expected(state, vars), Packs.Filled.owner(state)["key"]}
      end

      assert briefing.([]) == {"fill", "Fill it with crates", "ada"}
      assert briefing.([%{"links" => %{"in_box" => ["B-1"]}}]) == {"packing", "Pack it", "ada"}
    end

    test "empty through an association that ends at its kind: nothing points at it yet" do
      # A tag labels a box (an association, not a parent relation).
      sealed = %{"values" => %{"sealed" => true}}

      name = fn children, pointing ->
        elem(Packs.Labelled.state(sealed, children, [], pointing), 0)
      end

      assert name.([], ["labels"]) == "wait"
      assert name.([%{"links" => %{"labels" => ["B-1"]}}], ["labels"]) == "done"
      # An association Flow does not read for this kind is never empty.
      assert name.([], []) == "done"

      description = %{
        "relations" => %{
          "labels" => %{"from" => ["tag"], "to" => ["box"]},
          "in_box" => %{"from" => ["crate"], "to" => ["box"], "parent" => true}
        }
      }

      assert Legacy.pointing(Packs.Labelled, description, "box") == ["labels"]
      assert Legacy.pointing(Packs.Labelled, description, "tag") == []
    end

    test "what is expected may name the fact's own fields; a condition's note wins" do
      fact = %{"values" => %{"notes" => "fragile", "note" => "own"}}
      {state, vars} = Packs.Noted.state(fact, [], [], [])
      assert Packs.Noted.expected(state, vars) == "Label it: fragile (own)"

      reopened =
        put_in(fact, ["origins"], %{
          "signed_by" => %{"keys" => [], "position" => 3, "cause" => "torn"}
        })

      {state, vars} = Packs.Reopened.state(reopened, [], [], [])
      assert Packs.Reopened.expected(state, vars) == "Label it: fragile (torn)"
    end

    test "a field the text names that the fact does not have leaves its place empty" do
      # Its place is empty and a trailing colon goes; the name in braces never shows.
      {state, vars} = Packs.Labelled.state(%{"values" => %{"sealed" => true}}, [], [], ["labels"])
      assert state == "wait"
      assert Packs.Labelled.expected(state, vars) == "Label it"
    end
  end

  describe "one process per open fact" do
    test "at boot, a process for every open fact; it writes owner and expected, with the cause" do
      FakeFacts.put("box", %{"key" => "B-1", "progress" => %{"value" => "check"}})
      FakeFacts.put("box", %{"key" => "B-2", "completion" => %{"done" => true}})
      engine()

      eventually(fn -> FakeFacts.get("box", "B-1")["values"]["todo"] == "Check it" end)
      assert alive("B-1")
      refute alive("B-2")

      assert [
               %{
                 "op" => "change",
                 "key" => "B-1",
                 "values" => %{"todo" => "Check it"},
                 "links" => %{"owned_by" => ["ada"]},
                 "by" => "flow",
                 "cause" => "Flow pack: all in it is packed → ada"
               }
             ] = FakeFacts.sent()

      # Starting a second process for the same fact fails.
      assert {:error, {:already_started, _}} =
               DynamicSupervisor.start_child(
                 AtlasFlow.Supervisor,
                 {AtlasFlow.Item, {"box", "B-1", every: 60_000}}
               )
    end

    test "on a hint it looks again at once; once done it clears what was expected and stops" do
      FakeFacts.put("box", %{"key" => "B-1", "progress" => %{"value" => "check"}})
      engine()
      eventually(fn -> FakeFacts.get("box", "B-1")["values"]["todo"] == "Check it" end)

      # Signed off: the fact is completed. A hint of any kind pokes it.
      FakeFacts.put(
        "box",
        Map.merge(FakeFacts.get("box", "B-1"), %{"completion" => %{"done" => true}})
      )

      FakeFacts.put("crate", %{"key" => "C-1", "links" => %{"in_box" => ["B-1"]}})
      :ok = AtlasBus.attach("tester-#{System.unique_integer([:positive])}")

      {:stored, _} =
        AtlasFlow.Talk.put("crate", %{"op" => "change", "key" => "C-1", "values" => %{}})

      eventually(fn -> not alive("B-1") end)
      fact = FakeFacts.get("box", "B-1")
      refute Map.has_key?(fact["values"], "todo")
      assert fact["links"]["owned_by"] == []
      assert List.last(FakeFacts.sent())["cause"] == "Flow pack: done"
    end

    test "nothing is written when the stored owner and expected already fit (safe to repeat)" do
      FakeFacts.put("box", %{
        "key" => "B-1",
        "values" => %{"todo" => "Pack it"},
        "links" => %{"owned_by" => ["bob"]}
      })

      server = engine()
      :ok = Engine.round(server)
      Process.sleep(100)
      assert FakeFacts.sent() == []
      assert alive("B-1")
    end

    test "the hint of Flow's own write is passed over; a walk up reads plainly" do
      FakeFacts.put("box", %{"key" => "B-1", "progress" => %{"value" => "check"}})
      FakeFacts.put("crate", %{"key" => "C-1", "links" => %{"in_box" => ["B-1"]}})
      server = engine()
      eventually(fn -> FakeFacts.get("box", "B-1")["values"]["todo"] == "Check it" end)
      # The write was Flow's last read or write; the engine has its hint by now.
      _ = :sys.get_state(server)
      {settled, _} = FakeFacts.reads()

      # Flow's own write came back as a hint: nothing read again for it, not even after a
      # poke's settle time (50 ms).
      Process.sleep(150)
      assert {^settled, _} = FakeFacts.reads()

      # Someone else's change to the crate walks up to the box, reading the crate plainly.
      :ok = AtlasBus.attach("tester-#{System.unique_integer([:positive])}")

      {:stored, _} =
        AtlasFlow.Talk.put("crate", %{"op" => "change", "key" => "C-1", "values" => %{}})

      eventually(fn -> elem(FakeFacts.reads(), 1) >= 2 end)
    end

    test "an owner set by hand stays while the state stays; a new state moves it" do
      FakeFacts.put("clerk", %{"key" => "cy"})

      FakeFacts.put("box", %{
        "key" => "B-1",
        "values" => %{"todo" => "Pack it"},
        "links" => %{"owned_by" => ["cy"]},
        "origins" => %{"owned_by" => %{"keys" => ["cy"], "by" => "ada", "cause" => "cy packs"}}
      })

      engine()
      Process.sleep(200)
      # Packing still: cy, whom ada chose, stays.
      assert FakeFacts.sent() == []

      # All in it is packed: a new state, and its owner.
      FakeFacts.put(
        "box",
        Map.put(FakeFacts.get("box", "B-1"), "progress", %{"value" => "check"})
      )

      :ok = AtlasBus.attach("tester-#{System.unique_integer([:positive])}")

      {:stored, _} =
        AtlasFlow.Talk.put("box", %{"op" => "change", "key" => "B-1", "values" => %{}})

      eventually(fn -> FakeFacts.get("box", "B-1")["links"]["owned_by"] == ["ada"] end)
    end

    test "with a state field, the state's name is written; alone it moves no owner" do
      FakeFacts.put("clerk", %{"key" => "cy"})

      FakeFacts.put("box", %{
        "key" => "B-1",
        "values" => %{"todo" => "Pack it"},
        "links" => %{"owned_by" => ["cy"]},
        "origins" => %{"owned_by" => %{"keys" => ["cy"], "by" => "ada", "cause" => "cy packs"}}
      })

      engine(Stepped)
      eventually(fn -> FakeFacts.get("box", "B-1")["values"]["step"] == "packing" end)
      # Only the name: what is expected was right, and cy, whom ada chose, stays.
      assert [%{"values" => %{"step" => "packing"}} = sent] = FakeFacts.sent()
      refute Map.has_key?(sent, "links")
      assert FakeFacts.get("box", "B-1")["links"]["owned_by"] == ["cy"]
    end

    test "handed over before Flow's first look: the first look writes what is expected only" do
      FakeFacts.put("clerk", %{"key" => "cy"})

      # Made a moment ago, nothing expected yet, and already handed to cy by ada.
      FakeFacts.put("box", %{
        "key" => "B-1",
        "links" => %{"owned_by" => ["cy"]},
        "origins" => %{"owned_by" => %{"keys" => ["cy"], "by" => "ada", "cause" => "handed"}}
      })

      engine()
      eventually(fn -> FakeFacts.get("box", "B-1")["values"]["todo"] == "Pack it" end)
      assert [%{"values" => %{"todo" => "Pack it"}} = sent] = FakeFacts.sent()
      refute Map.has_key?(sent, "links")
      assert FakeFacts.get("box", "B-1")["links"]["owned_by"] == ["cy"]
    end

    test "an owner Flow, a migration or nobody set follows the state" do
      FakeFacts.put("box", %{
        "key" => "B-1",
        "values" => %{"todo" => "Pack it"},
        "links" => %{"owned_by" => ["ada"]},
        "origins" => %{"owned_by" => %{"keys" => ["ada"], "by" => "migration"}}
      })

      engine()
      eventually(fn -> FakeFacts.get("box", "B-1")["links"]["owned_by"] == ["bob"] end)
      assert [%{"values" => values, "links" => %{"owned_by" => ["bob"]}}] = FakeFacts.sent()
      assert values == %{}
    end

    test "an owner that does not exist yet: what is expected is written, the owner waits" do
      FakeFacts.put("box", %{"key" => "B-1", "progress" => %{"value" => "check"}})
      GenServer.call(FakeFacts, {:drop, "clerk", "ada"})
      engine()
      eventually(fn -> FakeFacts.get("box", "B-1")["values"]["todo"] == "Check it" end)
      assert [%{"values" => %{"todo" => "Check it"}} = sent] = FakeFacts.sent()
      refute Map.has_key?(sent, "links")

      # Once the owner is made, the fact gets it at once.
      FakeFacts.put("clerk", %{"key" => "ada"})
      :ok = AtlasBus.attach("tester-#{System.unique_integer([:positive])}")

      {:stored, _} =
        AtlasFlow.Talk.put("clerk", %{"op" => "create", "key" => "ada", "values" => %{}})

      eventually(fn -> FakeFacts.get("box", "B-1")["links"]["owned_by"] == ["ada"] end)
    end

    test "Facts does not answer whether the owner exists: nothing is written, not half" do
      FakeFacts.put("box", %{"key" => "B-1", "progress" => %{"value" => "check"}})
      GenServer.call(FakeFacts, {:busy, "clerk", "ada"})
      engine()
      eventually(fn -> elem(FakeFacts.reads(), 1) >= 1 and alive("B-1") end)
      Process.sleep(200)
      assert FakeFacts.sent() == []

      # Facts answers again: the next look writes both, in one change.
      GenServer.call(FakeFacts, {:free, "clerk", "ada"})
      :ok = AtlasBus.attach("tester-#{System.unique_integer([:positive])}")

      {:stored, _} =
        AtlasFlow.Talk.put("box", %{"op" => "change", "key" => "B-1", "values" => %{}})

      eventually(fn -> FakeFacts.get("box", "B-1")["links"]["owned_by"] == ["ada"] end)

      assert [%{"values" => %{"todo" => "Check it"}, "links" => %{"owned_by" => ["ada"]}}] =
               Enum.filter(FakeFacts.sent(), &(&1["by"] == "flow"))
    end

    test "a fact made later gets its process from its hint" do
      engine()
      FakeFacts.put("box", %{"key" => "B-7"})
      :ok = AtlasBus.attach("tester-#{System.unique_integer([:positive])}")

      {:stored, _} =
        AtlasFlow.Talk.put("box", %{"op" => "change", "key" => "B-7", "values" => %{}})

      eventually(fn -> FakeFacts.get("box", "B-7")["values"]["todo"] == "Pack it" end)
      assert alive("B-7")
    end

    test "a crashed process is started again and goes on from Facts" do
      FakeFacts.put("box", %{"key" => "B-1"})
      engine()
      eventually(fn -> alive("B-1") end)
      [{pid, _}] = Registry.lookup(AtlasFlow.Items, {"box", "B-1"})
      Process.exit(pid, :kill)

      eventually(fn ->
        match?([{other, _}] when other != pid, Registry.lookup(AtlasFlow.Items, {"box", "B-1"}))
      end)
    end

    test "a fact that waits until something points at it through an association" do
      description =
        FakeFacts.description()
        |> put_in(["entities", "tag"], %{"plural" => "tags"})
        |> put_in(["relations", "labels"], %{"from" => ["tag"], "to" => ["box"]})

      FakeFacts.set_description(description)

      # Sealed by itself (done, were nothing read), but nothing labels it: open work.
      FakeFacts.put("box", %{
        "key" => "B-1",
        "values" => %{"sealed" => true, "notes" => "fragile"}
      })

      engine(Labelled)
      eventually(fn -> FakeFacts.get("box", "B-1")["values"]["todo"] == "Label it: fragile" end)
      assert FakeFacts.get("box", "B-1")["links"]["owned_by"] == ["ada"]

      # A tag now labels it: the tag's hint wakes the box, which is done and stops.
      FakeFacts.put("tag", %{"key" => "T-1", "links" => %{"labels" => ["B-1"]}})
      :ok = AtlasBus.attach("tester-#{System.unique_integer([:positive])}")

      {:stored, _} =
        AtlasFlow.Talk.put("tag", %{"op" => "change", "key" => "T-1", "values" => %{}})

      eventually(fn -> not alive("B-1") end)
      refute Map.has_key?(FakeFacts.get("box", "B-1")["values"], "todo")
    end
  end
end
