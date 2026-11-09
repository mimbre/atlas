defmodule AtlasFlow.Runs.ReactionTest do
  @moduledoc """
  One reaction of a run to one input is stored once (`AtlasFlow.Runs.Store`): the
  transitions it takes in memory are written in one versioned write, and sooner only where
  something outside the run must see the stored cursor first (its pending writes, an
  activity, a consume, its inputs once its cursor moved). Counted through the engine, on
  hints, against fake Facts, with a manual clock: a new parent made and counted, a
  hand's choice, and a child's completion that moves its parent on. A crash between the
  writes of one reaction recovers to the same end, with each subject write made once.
  """
  use ExUnit.Case, async: false

  alias AtlasFlow.{Engine, FakeFacts, ManualClock, Talk}
  alias AtlasFlow.Runs.{Run, Store}

  @every 3_600_000

  defmodule Written do
    @moduledoc """
    A tray gathers its cups: it starts on create and is taken over in its work (an open
    tray, by its import row); its count of cups moves it between sorting, working and
    checking (`by: :atlas`); a hand's choice checks it.
    """
    use RelaDSL.Schema

    subflow :gather, label: "Gather", subject: :tray do
      run_as("system:yard")
      owner(default: {:hand, :ada})
      start(:create)
      initial(:sorting)

      state :sorting, label: "Sort its cups" do
        branch(to: :working, by: :atlas, when: "entity.cups > 0")
      end

      state :working, label: "Work its cups" do
        branch(to: :sorting, by: :atlas, when: "entity.cups == 0")
        branch(to: :checking, by: :atlas, when: "entity.open_cups == 0")
      end

      state :checking, label: "Check it" do
        set(verdict: "none")
        wait_for([:hand], on: :verdict, reset: false, yes: :checked)
        branch(to: :working, by: :atlas, when: "entity.open_cups > 0")
      end

      final(:checked, label: "Checked")
    end
  end

  defmodule Gather do
    use AtlasFlow.Sorts, from: Written, subflow: :gather
  end

  defmodule Gathering do
    use AtlasFlow.TestModel,
      legacy: [],
      subflows: [
        AtlasFlow.Runs.ReactionTest.Gather,
        Enum.find(AtlasFlow.Yard.subflows(:prod), &(&1.name() == "pour"))
      ],
      runs: AtlasFlow.Yard.runs(),
      relations: AtlasFlow.Yard.relations(),
      composition: Map.put(AtlasFlow.Yard.composition(), "links", []),
      selection: %{
        "gather" => %{
          "subject" => "tray",
          "choices" => ["verdict"],
          "choice_states" => ["checking"],
          "admission" => %{"phase" => ["first"]},
          "imports" => [%{"completed" => false, "state" => "working"}],
          "migrations" => []
        },
        "pour" => AtlasFlow.Yard.selection("pour")
      }
  end

  @description %{
    "entities" => Map.new(~w(tray cup hand cursor choice), &{&1, %{"plural" => &1 <> "s"}}),
    "relations" => %{
      "on_tray" => %{"from" => ["cup"], "to" => ["tray"], "max_outgoing" => 1}
    }
  }

  setup do
    Application.put_env(:atlas_bus, :store, "reaction-#{System.unique_integer([:positive])}")
    :ok = Supervisor.terminate_child(AtlasFlow.Root, AtlasFlow.Supervisor)
    {:ok, _} = Supervisor.restart_child(AtlasFlow.Root, AtlasFlow.Supervisor)

    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(AtlasFlow.Supervisor),
          do: DynamicSupervisor.terminate_child(AtlasFlow.Supervisor, pid)
    end)

    start_supervised!({FakeFacts, description: @description})
    FakeFacts.put("hand", %{"key" => "ada"})
    clock = start_supervised!({ManualClock, ~U[2026-11-13 00:00:00Z]})

    engine =
      start_supervised!({Engine, every: @every, clock: {ManualClock, clock}, model: Gathering})

    Engine.round(engine)
    :ok = AtlasBus.attach("hand-#{System.unique_integer([:positive])}")
    %{engine: engine, config: AtlasFlow.TestModel.config(Gathering)}
  end

  # What Flow wrote while the engine took one hint, and how many facts it sent (each
  # attempt and replay): `{[{op, :run | key}], round trips}`.
  defp written(c, fun) do
    sent = length(FakeFacts.stored_from_flow())
    puts = FakeFacts.puts()
    fun.()
    :sys.get_state(c.engine)
    runs = runs(c)

    writes =
      for w <- Enum.drop(FakeFacts.stored_from_flow(), sent),
          do: {w["op"], if(w["key"] in runs, do: :run, else: w["key"])}

    {writes, FakeFacts.puts() - puts}
  end

  defp runs(_c), do: for({{"cursor", key}, _} <- facts(), do: key)
  defp facts, do: :sys.get_state(FakeFacts).facts

  defp run(c, name, kind, key) do
    {:ok, run} = Store.decode(c.config, FakeFacts.get("cursor", Run.key(name, kind, key, 1)))
    run
  end

  defp tray(key),
    do:
      Talk.put("tray", %{
        "op" => "create",
        "key" => key,
        "values" => %{"phase" => "first", "revision" => "r1"}
      })

  defp cup(key, tray),
    do:
      Talk.put("cup", %{
        "op" => "create",
        "key" => key,
        "values" => %{"phase" => "first", "revision" => "r1"},
        "links" => %{"on_tray" => [tray]}
      })

  defp pour(key),
    do: Talk.put("cup", %{"op" => "change", "key" => key, "values" => %{"level" => "full"}})

  # A hand checks the tray: its choice, submitted to the run's current entry.
  defp check(c, key) do
    run = run(c, "gather", "tray", key)

    Talk.put("choice", %{
      "op" => "submit",
      "key" => "I-#{key}",
      "values" => %{
        "run" => run["key"],
        "entry" => run["entry"],
        "roles" => ["hand"],
        "changed_fields" => %{"verdict" => "yes"}
      }
    })
  end

  # One fact put, and the hint of it taken by the engine.
  defp put(c, {:stored, _}), do: :sys.get_state(c.engine)

  defp at(run), do: {run["state"], run["entry"], run["status"], run["pending"]["writes"]}

  test "a new parent: made, counted and moved on in three writes", c do
    {writes, puts} = written(c, fn -> {:stored, _} = tray("T-1") end)

    # The run is made with its count's write pending, the count is written, and the run
    # stored once where the count left it: imported into its work, back to sorting.
    assert writes == [{"create", :run}, {"change", "T-1"}, {"change", :run}]
    assert puts == 3
    assert at(run(c, "gather", "tray", "T-1")) == {"sorting", 2, "active", []}

    assert Map.take(FakeFacts.get("tray", "T-1")["values"], ~w(cups open_cups)) ==
             %{"cups" => 0, "open_cups" => 0}
  end

  test "a hand's choice: the run stored once, then the input consumed", c do
    put(c, tray("T-1"))
    put(c, cup("C-1", "T-1"))
    put(c, pour("C-1"))
    assert at(run(c, "gather", "tray", "T-1")) == {"checking", 4, "active", []}

    {writes, puts} = written(c, fn -> {:stored, _} = check(c, "T-1") end)

    # Facts consumes only the input the stored run accepted: two writes, neither can wait.
    assert writes == [{"change", :run}, {"consume", "I-T-1"}]
    assert puts == 2
    assert at(run(c, "gather", "tray", "T-1")) == {"checked", 5, "completed", []}
  end

  test "a child's completion: its run, then its parent counted and moved on", c do
    put(c, tray("T-1"))
    put(c, cup("C-1", "T-1"))
    assert at(run(c, "gather", "tray", "T-1")) == {"working", 3, "active", []}

    {writes, puts} = written(c, fn -> {:stored, _} = pour("C-1") end)

    # The cup's run completes; the tray's count is stored and written, and the entry it
    # leads to (checking, which resets the verdict) is stored and written; then the run
    # once more where the count's offer of that entry left it.
    assert writes == [
             {"change", :run},
             {"change", :run},
             {"change", "T-1"},
             {"change", :run},
             {"change", "T-1"},
             {"change", :run}
           ]

    assert puts == 6
    assert at(run(c, "gather", "tray", "T-1")) == {"checking", 4, "active", []}
    assert at(run(c, "pour", "cup", "C-1")) == {"full", 2, "completed", []}
  end
end
