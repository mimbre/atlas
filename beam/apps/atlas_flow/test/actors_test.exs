defmodule AtlasFlow.ActorsTest do
  # The actors the model's owners name (`config: role`): the environment's settings fill
  # each role (`actors:` here), and Flow writes that one as the owner. A role the settings
  # do not fill refuses the start; an actor whose fact does not exist yet only waits.
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias AtlasFlow.{Engine, FakeFacts}

  # The depot's pack, checked by whoever the environment configures as its checker.
  defmodule Checked do
    use AtlasFlow.TestModel, legacy: [AtlasFlow.Packs.Checked], actors: [checker: "clerk"]
  end

  setup do
    Application.put_env(:atlas_bus, :store, "state-#{System.unique_integer([:positive])}")
    # A fresh supervisor for the facts' processes, as AtlasFlowTest does.
    :ok = Supervisor.terminate_child(AtlasFlow.Root, AtlasFlow.Supervisor)
    {:ok, _} = Supervisor.restart_child(AtlasFlow.Root, AtlasFlow.Supervisor)

    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(AtlasFlow.Supervisor),
          do: DynamicSupervisor.terminate_child(AtlasFlow.Supervisor, pid)
    end)

    start_supervised!(FakeFacts)
    for key <- ["ada", "bob"], do: FakeFacts.put("clerk", %{"key" => key})
    # A box all packed: it is to be checked.
    key = "B-#{System.unique_integer([:positive])}"
    FakeFacts.put("box", %{"key" => key, "values" => %{}, "progress" => %{"value" => "check"}})
    %{box: key}
  end

  defp start(actors),
    do: start_supervised({Engine, every: 3_600_000, model: Checked, actors: actors})

  # The engine looks at every fact now; the box's process has had its first look.
  defp round(engine, box) do
    Engine.round(engine)

    case Registry.lookup(AtlasFlow.Items, {"box", box}) do
      [{pid, _}] -> :sys.get_state(pid) && pid
      [] -> nil
    end
  end

  test "a state's configured owner is the actor the settings name", %{box: box} do
    {:ok, engine} = start(%{"checker" => "ada"})
    assert round(engine, box)
    assert FakeFacts.get("box", box)["links"]["owned_by"] == ["ada"]
    assert FakeFacts.get("box", box)["values"]["todo"] == "Check it"
  end

  test "Flow does not start when the settings do not fill a role its owners name" do
    for actors <- [nil, %{}, %{"checker" => ""}, %{"other" => "ada"}] do
      assert {:error, {{%ArgumentError{message: why}, _}, _}} = start(actors)
      assert why =~ "Flow does not start: the environment's settings give no actors.checker"
    end
  end

  test "a configured actor that does not exist yet: Flow runs, and the owner waits for it",
       %{box: box} do
    {:ok, engine} = start(%{"checker" => "zed"})

    log = ExUnit.CaptureLog.capture_log(fn -> assert round(engine, box) end)
    assert log =~ "flow: clerk zed does not exist; the owner waits for it"
    # What is expected is written; the owner is not, until it exists.
    assert FakeFacts.get("box", box)["values"]["todo"] == "Check it"
    assert FakeFacts.get("box", box)["links"]["owned_by"] == nil

    # Made later, through Facts: the next look hands the box to it.
    FakeFacts.put("clerk", %{"key" => "zed"})
    [{pid, _}] = Registry.lookup(AtlasFlow.Items, {"box", box})
    DynamicSupervisor.terminate_child(AtlasFlow.Supervisor, pid)
    assert round(engine, box)
    assert FakeFacts.get("box", box)["links"]["owned_by"] == ["zed"]
  end
end
