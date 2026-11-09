defmodule RelaDSL.Description.JsonTest do
  use ExUnit.Case, async: true
  alias RelaDSL.Description.Json

  test "pretty, as Python's json.dumps(indent=2, sort_keys=True, ensure_ascii=False)" do
    value = %{"b" => [1, true, nil], "a" => %{}, "c" => [], "d" => "Hand to… \"x\"\n\\\t\u0001"}

    assert Json.write(value) == ~s"""
           {
             "a": {},
             "b": [
               1,
               true,
               null
             ],
             "c": [],
             "d": "Hand to… \\"x\\"\\n\\\\\\t\\u0001"
           }
           """
  end

  test "ordered objects keep their order; a layout puts a path inline or compact" do
    value =
      {:ordered,
       [
         {"z", {:ordered, [{"one", {:ordered, [{"b", 1}, {"a", [2, 3]}]}}]}},
         {"y", [{:ordered, [{"k", "v"}, {"j", [1]}]}]}
       ]}

    layout = fn
      ["z", "one"] -> :inline
      ["y", 0] -> :compact
      _ -> :pretty
    end

    assert Json.write(value, layout) == """
           {
             "z": {
               "one": {"b": 1, "a": [2, 3]}
             },
             "y": [
               {"k":"v","j":[1]}
             ]
           }
           """
  end
end
