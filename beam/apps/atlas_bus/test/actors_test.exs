defmodule AtlasBus.ActorsTest do
  use ExUnit.Case, async: true

  alias AtlasBus.Actors

  test "each role a model names is filled by the settings, with its kind" do
    assert Actors.resolve([checker: "clerk", sender: "team"], %{
             "checker" => "ada",
             "sender" => "desk",
             "unused" => "bob"
           }) ==
             {:ok,
              %{
                "checker" => %{"kind" => "clerk", "key" => "ada"},
                "sender" => %{"kind" => "team", "key" => "desk"}
              }}

    assert Actors.resolve([checker: "clerk"], %{checker: "ada"}) ==
             {:ok, %{"checker" => %{"kind" => "clerk", "key" => "ada"}}}

    assert Actors.resolve([], nil) == {:ok, %{}}
  end

  test "a role the settings do not fill is refused, and says what to set" do
    for configured <- [nil, %{}, %{"checker" => ""}, %{"checker" => 7}] do
      assert {:error, why} = Actors.resolve([checker: "clerk"], configured)
      assert why =~ "the environment's settings give no actors.checker"
      assert why =~ "the key of the clerk the model's owners name as checker"
    end
  end
end
