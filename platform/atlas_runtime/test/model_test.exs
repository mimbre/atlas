defmodule AtlasRuntime.ModelTest do
  use ExUnit.Case, async: true

  alias AtlasRuntime.{Model, TestModel}

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
  end

  test "the model gives the turn's names and the facts a turn works on" do
    turn = TestModel.turn()
    assert turn["kind"] == "run" and turn["on_kinds"] == ["card"]
    assert [%{"kind" => "card", "owner_relation" => "owned_by"}] = turn["items"]
    assert TestModel.agent() == %{"kind" => "clerk", "cannot_run" => "stuck"}
    assert TestModel.guidance() == nil
  end
end
