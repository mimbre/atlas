defmodule AtlasBFFContract.ChoiceActionTest do
  use ExUnit.Case, async: true
  alias AtlasBFFContract.Console

  test "direct actions submit declared calls, never inferred labels or arbitrary endpoints" do
    call = %{
      "endpoint" => "answer",
      "params" => %{
        "kind" => "decision",
        "key" => "D-private",
        "answer" => "option-exact-revision-files"
      }
    }

    assert Console.operation?(%{"name" => "invoke", "call" => call})

    refute Console.operation?(%{
             "name" => "invoke",
             "call" => Map.put(call, "endpoint", "unknown")
           })

    refute Console.operation?(%{
             "name" => "invoke",
             "call" => put_in(call, ["params", "answer"], "")
           })

    refute Console.operation?(%{
             "name" => "invoke",
             "call" => put_in(call, ["params", "number"], "0")
           })

    refute Console.operation?(%{
             "name" => "invoke",
             "call" => Map.put(call, "authority", "recommended")
           })
  end
end
