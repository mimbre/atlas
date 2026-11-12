defmodule AtlasControl.ModelTest do
  use ExUnit.Case, async: true

  alias AtlasControl.{Model, Shop}

  defmodule Partial do
    @moduledoc false
    def kinds, do: []
    def turn, do: nil
  end

  test "a model that implements every callback is the one Control serves" do
    assert Model.check!(Shop) == Shop

    assert %{module: Shop, kinds: %{"widget" => _}, relations: %{"of_widget" => _}} =
             Model.catalog(Shop)
  end

  test "a missing model, or a module that is none, refuses the start" do
    assert_raise ArgumentError, fn -> Model.check!(nil) end
    assert_raise ArgumentError, fn -> Model.check!(:"Elixir.NoSuchModule") end
    assert_raise ArgumentError, ~r/shell\/1/, fn -> Model.check!(Partial) end
    # What Control calls of the turn's component counts too.
    assert_raise ArgumentError, ~r/read_first\/2/, fn -> Model.check!(Partial) end

    assert {:error, {{%ArgumentError{}, _}, _}} =
             start_supervised({AtlasControl.Gateway, port: 0, name: :partial, model: Partial})
  end

  test "the environment adds tabs to the model's shell, after its own" do
    tab = %{"id" => "workers", "label" => "Workers", "to" => "/workers"}
    assert Shop.Shelled.shell(%{}) == Shop.Shelled.shell(nil)
    assert %{"tabs" => tabs} = Shop.Shelled.shell(%{"tabs" => [tab]})
    assert List.last(tabs) == tab and length(tabs) == 3
    assert Shop.shell(%{"tabs" => [tab]}) == nil
  end
end
