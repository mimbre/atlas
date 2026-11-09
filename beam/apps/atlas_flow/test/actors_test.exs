defmodule AtlasFlow.ActorsTest do
  # The actors the model's owners name (`config: role`): the environment's settings fill
  # each role (`actors:` here), and Flow writes that one as the owner. A role the settings
  # do not fill refuses the start; an actor whose fact does not exist yet only waits.
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias AtlasFlow.{Engine, FakeFacts}

  # The depot's sort, checked by whoever the environment configures as its checker.
  defmodule Checked do
    use AtlasFlow.TestModel,
      subflows: [AtlasFlow.Sorts.Checked],
      actors: [checker: "clerk"],
      selection: %{
        "sort" => %{
          "subject" => "box",
          "projection" => %{"field" => "todo", "owner_relation" => "owned_by"},
          "admission" => %{},
          "imports" => [],
          "migrations" => []
        }
      }
  end

  setup do
    Application.put_env(:atlas_bus, :store, "state-#{System.unique_integer([:positive])}")
    start_supervised!(FakeFacts)
    for key <- ["ada", "bob"], do: FakeFacts.put("clerk", %{"key" => key})
    key = "B-#{System.unique_integer([:positive])}"
    FakeFacts.put("box", %{"key" => key, "values" => %{}})
    %{box: key}
  end

  defp start(actors),
    do: start_supervised({Engine, every: 3_600_000, model: Checked, actors: actors})

  test "a state's configured owner is the actor the settings name", %{box: box} do
    {:ok, engine} = start(%{"checker" => "ada"})
    Engine.round(engine)
    assert FakeFacts.get("box", box)["links"]["owned_by"] == ["ada"]
    assert FakeFacts.get("box", box)["values"]["todo"] == "Check it"
  end

  test "Flow does not start when the settings do not fill a role its owners name" do
    for actors <- [nil, %{}, %{"checker" => ""}, %{"other" => "ada"}] do
      assert {:error, {{%AtlasFlow.Model.MissingActor{role: "checker"}, _}, _}} = start(actors)
    end
  end

  test "a configured actor that does not exist yet: Flow runs, and the owner waits for it",
       %{box: box} do
    {:ok, engine} = start(%{"checker" => "zed"})
    Engine.round(engine)

    # What is expected is written; the owner is not, until it exists.
    assert FakeFacts.get("box", box)["values"]["todo"] == "Check it"
    assert FakeFacts.get("box", box)["links"]["owned_by"] == nil

    # Made later, through Facts: the next round hands the box to it.
    FakeFacts.put("clerk", %{"key" => "zed"})
    Engine.round(engine)
    assert FakeFacts.get("box", box)["links"]["owned_by"] == ["zed"]
  end
end
