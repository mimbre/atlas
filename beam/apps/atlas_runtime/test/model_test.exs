defmodule AtlasRuntime.ModelTest do
  use ExUnit.Case, async: true

  alias AtlasRuntime.{Guidance, Model, TestModel}

  defmodule Partial do
    @moduledoc false
    def turn, do: nil
  end

  test "a model that implements every callback is the one Runtime runs" do
    assert Model.check!(TestModel) == TestModel
  end

  test "a missing model, or a module that is none, refuses the start" do
    assert_raise ArgumentError, fn -> Model.check!(nil) end
    assert_raise ArgumentError, fn -> Model.check!(:"Elixir.NoSuchModule") end
    assert_raise ArgumentError, ~r/agent\/0/, fn -> Model.check!(Partial) end

    assert_raise ArgumentError, fn ->
      AtlasRuntime.Engine.init(machine: "here", model: Partial)
    end
  end

  test "the model gives the turn's names and the facts a turn works on" do
    turn = TestModel.turn()
    assert turn["kind"] == "run" and turn["on_kinds"] == ["card"]
    assert [%{"kind" => "card", "owner_relation" => "owned_by"}] = turn["items"]
    assert TestModel.agent() == %{"kind" => "clerk", "cannot_run" => "stuck"}
    assert TestModel.guidance() == nil
  end

  test "guidance records without the turn's attempt are refused; none means no guidance" do
    turn = %{names: %{attempt: nil}}
    assert Guidance.register(Map.put(turn, :guidance_mapping, nil)) == {:ok, nil}

    assert Guidance.register(
             Map.put(turn, :guidance_mapping, %{"execution" => %{"kind" => "log"}})
           ) == {:error, :invalid_guidance_mapping}
  end
end
