defmodule AtlasFlow.Composition.RecoveryTest do
  @moduledoc """
  The composition through the run store and fake Facts (the neutral yard): links,
  counts and the parent writes they owe, across replaced, late, duplicate, removed and
  moved children, an empty aggregate, two subflows on one subject and a restart between
  a child's completion and its parent's write. No timer is waited on: each step is one
  synchronous reconcile.
  """
  use ExUnit.Case, async: false
  alias AtlasFlow.FakeFacts
  alias AtlasFlow.Runs.{Run, Store}
  @now ~U[2026-11-13 00:00:00Z]

  setup do
    start_supervised!(FakeFacts)
    :ok = AtlasBus.attach("flow")
    %{config: config, flows: flows} = AtlasFlow.Model.load(AtlasFlow.Yard, :prod)
    %{config: config, flows: flows}
  end

  defp reconcile(c), do: Store.reconcile(c.config, c.flows, @now)

  defp hint(c, subjects), do: Store.reconcile_subjects(c.config, c.flows, @now, [], subjects)

  defp tray(key, values \\ %{}),
    do:
      FakeFacts.put("tray", %{
        "key" => key,
        "values" => Map.merge(%{"phase" => "first", "revision" => "r1"}, values)
      })

  defp cup(key, tray, values \\ %{}),
    do:
      FakeFacts.put("cup", %{
        "key" => key,
        "values" => Map.merge(%{"phase" => "first", "revision" => "r1"}, values),
        "links" => if(tray, do: %{"on_tray" => [tray]}, else: %{})
      })

  defp pour(key, level) do
    fact = FakeFacts.get("cup", key)
    FakeFacts.put("cup", put_in(fact, ["values", "level"], level))
  end

  defp run(c, name, key, generation \\ 1) do
    kind = c.flows[name].subject()

    case FakeFacts.get("cursor", Run.key(name, kind, key, generation)) do
      nil ->
        nil

      fact ->
        {:ok, run} = Store.decode(c.config, fact)
        run
    end
  end

  defp values(kind, key), do: FakeFacts.get(kind, key)["values"]
  defp cursor(run), do: Map.take(run, ~w(key state entry status entered_at))

  # Every write Flow sent to `key` that set `field`.
  defp writes(key, field),
    do:
      for(w <- FakeFacts.sent(), w["key"] == key, Map.has_key?(w["values"] || %{}, field), do: w)

  test "a current child's completion advances its parent once, with the child as its input", c do
    tray("T-1")
    cup("C-1", "T-1")
    assert {:ok, _} = reconcile(c)
    assert run(c, "fill", "T-1")["state"] == "waiting"
    assert run(c, "pour", "C-1")["state"] == "pouring"
    assert Map.take(values("tray", "T-1"), ~w(cups open_cups)) == %{"cups" => 1, "open_cups" => 1}

    pour("C-1", "full")
    assert {:ok, _} = reconcile(c)

    fill = run(c, "fill", "T-1")
    assert {fill["state"], fill["status"], fill["entry"]} == {"filled", "completed", 2}

    assert [%{"child" => "C-1", "field" => "outcome", "state" => "full", "current" => "r1"}] =
             fill["last_input"]["sources"]

    assert is_binary(fill["last_input"]["synthetic"])
    assert values("tray", "T-1")["outcome"] == "full"
    assert [_] = writes("T-1", "outcome")

    # Duplicate completion: more reconciles and hints apply nothing again.
    sent = length(FakeFacts.sent())
    assert {:ok, _} = reconcile(c)
    assert {:ok, _} = hint(c, [{"cup", "C-1"}, {"tray", "T-1"}])
    assert {:ok, _} = reconcile(c)
    assert length(FakeFacts.sent()) == sent
    assert run(c, "fill", "T-1") == fill
  end

  test "a replaced child that completes late changes nothing; its replacement does", c do
    tray("T-1")
    cup("C-1", "T-1")
    {:ok, _} = reconcile(c)

    # The tray moves to revision r2 and gets a new cup for it: C-1 is replaced.
    FakeFacts.put("tray", put_in(FakeFacts.get("tray", "T-1"), ["values", "revision"], "r2"))
    cup("C-2", "T-1", %{"revision" => "r2"})
    {:ok, _} = reconcile(c)

    pour("C-1", "full")
    {:ok, _} = reconcile(c)
    assert run(c, "pour", "C-1")["status"] == "completed"
    assert run(c, "fill", "T-1")["state"] == "waiting"
    assert writes("T-1", "outcome") == []
    refute Map.has_key?(values("tray", "T-1"), "outcome")

    pour("C-2", "spilt")
    {:ok, _} = reconcile(c)
    fill = run(c, "fill", "T-1")
    assert fill["state"] == "spilt"
    assert [%{"child" => "C-2", "current" => "r2"}] = fill["last_input"]["sources"]
    assert [%{"values" => %{"outcome" => "spilt"}}] = writes("T-1", "outcome")

    # A late result after the parent completed reaches nothing either.
    cup("C-3", "T-1", %{"revision" => "r2", "level" => "full"})
    {:ok, _} = reconcile(c)
    assert run(c, "fill", "T-1") == fill
    assert length(writes("T-1", "outcome")) == 1
  end

  test "two current children are ambiguous: nothing is written until one is removed", c do
    tray("T-1")
    cup("C-1", "T-1")
    cup("C-2", "T-1")
    {:ok, _} = reconcile(c)
    pour("C-1", "full")
    {:ok, _} = reconcile(c)

    fill = run(c, "fill", "T-1")
    assert fill["state"] == "waiting"
    assert fill["pending"]["composition"]["refused"] == %{"outcome" => ["C-1", "C-2"]}
    assert writes("T-1", "outcome") == []

    # C-2 leaves the tray (its link removed): C-1 is the one current cup now.
    cup("C-2", nil)
    {:ok, _} = reconcile(c)
    fill = run(c, "fill", "T-1")
    assert fill["state"] == "filled"
    refute Map.has_key?(fill["pending"]["composition"], "refused")
    assert [%{"values" => %{"outcome" => "full"}}] = writes("T-1", "outcome")
  end

  test "counts are worked out again after a delete, a move or a lost hint; empty is zero", c do
    tray("T-1")
    tray("T-2")
    cup("C-1", "T-1")
    cup("C-2", "T-1")
    {:ok, _} = reconcile(c)
    assert Map.take(values("tray", "T-1"), ~w(cups open_cups)) == %{"cups" => 2, "open_cups" => 2}

    # Empty aggregate: zero, and the tally does not start without cups.
    assert Map.take(values("tray", "T-2"), ~w(cups open_cups)) == %{"cups" => 0, "open_cups" => 0}
    assert run(c, "tally", "T-2")["status"] == "idle"

    # Moved and completed with no hint at all: the next reconcile counts both trays again.
    cup("C-2", "T-2", %{"level" => "full"})
    {:ok, _} = reconcile(c)
    assert Map.take(values("tray", "T-1"), ~w(cups open_cups)) == %{"cups" => 1, "open_cups" => 1}
    assert Map.take(values("tray", "T-2"), ~w(cups open_cups)) == %{"cups" => 1, "open_cups" => 0}

    # Deleted: T-1 is empty again; its tally, started once it had cups, keeps waiting.
    # The deleted cup's run stays as it was and stops no other run.
    orphan = run(c, "pour", "C-1")
    GenServer.call(FakeFacts, {:drop, "cup", "C-1"})
    {:ok, _} = hint(c, [{"tray", "T-1"}])
    assert Map.take(values("tray", "T-1"), ~w(cups open_cups)) == %{"cups" => 0, "open_cups" => 0}
    assert run(c, "tally", "T-1")["state"] == "counting"
    assert {:ok, _} = reconcile(c)
    assert run(c, "pour", "C-1") == orphan
  end

  test "two subflows on one subject keep their own cursors and starts", c do
    tray("T-1")
    {:ok, _} = reconcile(c)
    fill = run(c, "fill", "T-1")
    tally = run(c, "tally", "T-1")
    refute fill["key"] == tally["key"]
    assert {fill["status"], fill["state"]} == {"active", "waiting"}
    # The tally starts on its own predicate (cups > 0), not on create.
    assert tally["status"] == "idle" and tally["state"] in ["", nil]

    cup("C-1", "T-1")
    {:ok, _} = reconcile(c)
    assert cursor(run(c, "fill", "T-1")) == cursor(fill)
    tally = run(c, "tally", "T-1")
    assert {tally["status"], tally["state"], tally["entry"]} == {"active", "counting", 1}

    # The cup's completion moves both: the fill by its link, the tally by its count, each
    # once, from one write of each value.
    pour("C-1", "full")
    {:ok, _} = reconcile(c)
    assert run(c, "fill", "T-1")["state"] == "filled"
    assert run(c, "tally", "T-1")["state"] == "counted"
    assert length(writes("T-1", "outcome")) == 1
    # Each change of the aggregate is written once: empty, one open cup, none open.
    assert Enum.map(writes("T-1", "open_cups"), & &1["values"]) == [
             %{"cups" => 0, "open_cups" => 0},
             %{"cups" => 1, "open_cups" => 1},
             %{"open_cups" => 0}
           ]

    assert run(c, "fill", "T-1")["entry"] == 2 and run(c, "tally", "T-1")["entry"] == 2
  end

  test "a restart between the child's completion and the parent's write writes once", c do
    tray("T-1")
    cup("C-1", "T-1")
    {:ok, _} = reconcile(c)

    # The child completes on the hint about it; its parent cannot be read, so the
    # parent's write is not made yet.
    GenServer.call(FakeFacts, {:busy, "tray", "T-1"})
    pour("C-1", "full")
    assert {:error, _} = hint(c, [{"cup", "C-1"}])
    assert run(c, "pour", "C-1")["status"] == "completed"
    assert run(c, "fill", "T-1")["state"] == "waiting"
    assert writes("T-1", "outcome") == []

    # Restart Flow (it keeps nothing): the parent's intent is stored, then its write is
    # committed and its answer lost, and Flow restarts again before it clears the intent.
    restart_flow()
    GenServer.call(FakeFacts, {:free, "tray", "T-1"})
    FakeFacts.lose_ack("tray")
    assert {:error, {:pending, _}} = reconcile(c)
    assert [_] = writes("T-1", "outcome")

    stored = run(c, "fill", "T-1")["pending"]["writes"]
    assert Enum.any?(stored, &(&1["content"]["values"] == %{"outcome" => "full"}))

    restart_flow()
    assert {:ok, _} = reconcile(c)
    fill = run(c, "fill", "T-1")
    assert {fill["state"], fill["entry"]} == {"filled", 2}
    assert fill["pending"]["writes"] == []
    # The replay of the stored intent was answered from Facts' ledger: one write.
    assert [_] = writes("T-1", "outcome")
  end

  test "Flow refuses a composition it cannot apply, and applies none it does not select" do
    base = AtlasFlow.Yard.composition()

    load = fn composition, selection ->
      module = Module.concat(__MODULE__, "M#{System.unique_integer([:positive])}")

      Module.create(
        module,
        quote do
          @behaviour AtlasFlow.Model
          defdelegate subflows(env), to: AtlasFlow.Yard
          defdelegate legacy(), to: AtlasFlow.Yard
          defdelegate runs(), to: AtlasFlow.Yard
          defdelegate migrations(), to: AtlasFlow.Yard
          defdelegate actors(), to: AtlasFlow.Yard
          defdelegate relations(), to: AtlasFlow.Yard
          defdelegate turn(), to: AtlasFlow.Yard
          def composition, do: unquote(Macro.escape(composition))

          def selection(name),
            do:
              Map.get_lazy(unquote(Macro.escape(selection)), name, fn ->
                AtlasFlow.Yard.selection(name)
              end)
        end,
        Macro.Env.location(__ENV__)
      )

      AtlasFlow.Model.load(module, :prod)
    end

    assert %{refusal: {:unsupported_composition, 2}} = load.(Map.put(base, "version", 2), %{})

    unsafe = update_in(base, ["links"], fn [l] -> [Map.put(l, "current", nil)] end)
    assert %{refusal: {:unsupported_link, "pour"}} = load.(unsafe, %{})

    # The cup's subflow not selected: no link or count of it is applied, so nothing refuses.
    assert %{refusal: nil, config: config} = load.(unsafe, %{"pour" => nil})
    assert config["composition"] == %{"links" => [], "counts" => []}
  end

  defp restart_flow do
    :ok = Application.stop(:atlas_flow)
    {:ok, _} = Application.ensure_all_started(:atlas_flow)
  end
end
