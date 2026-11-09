defmodule RelaDSL.DefinitionDigestTest do
  use ExUnit.Case, async: true
  alias RelaDSL.DefinitionDigest

  test "canonical bytes preserve strings, numbers and array order, sorting every object" do
    data = %{
      "z" => [true, nil, 9_007_199_254_740_993, 1.25, "é\n\""],
      "a" => %{"y" => 2, "b" => 1}
    }

    assert DefinitionDigest.canonical(data) ==
             ~S({"a":{"b":1,"y":2},"z":[true,null,9007199254740993,1.25,"é\n\""]})
  end

  test "map representation and insertion order cannot affect identity" do
    data = Map.new(for n <- 1..40, do: {"key-#{n}", %{"z" => n, "a" => "text"}})
    rebuilt = data |> Enum.reverse() |> Map.new()
    # Crossing the small-map threshold changes the VM's representation, not the JSON.
    rebuilt = rebuilt |> Map.put("temporary", nil) |> Map.delete("temporary")
    assert DefinitionDigest.of(data) == DefinitionDigest.of(rebuilt)
    assert DefinitionDigest.of(data) == DefinitionDigest.of(JSON.decode!(JSON.encode!(data)))
  end

  test "state, transition, timer and gate data each contribute to identity" do
    data = %{
      "states" => %{
        "waiting" => %{
          "label" => "Waiting",
          "branches" => [%{"to" => "done", "when" => "entity.ready == true"}],
          "timers" => [%{"name" => "slow", "period" => "1h", "to" => "done"}],
          "spec" => %{"gate" => "check", "version" => 1}
        },
        "done" => %{"final" => true}
      }
    }

    for changed <- [
          put_in(data, ["states", "waiting", "label"], "Ready"),
          put_in(data, ["states", "waiting", "branches"], []),
          put_in(data, ["states", "waiting", "timers"], []),
          put_in(data, ["states", "waiting", "spec", "version"], 2)
        ] do
      refute DefinitionDigest.of(data) == DefinitionDigest.of(changed)
    end
  end
end
