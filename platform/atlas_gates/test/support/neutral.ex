defmodule AtlasGates.Neutral do
  @moduledoc """
  The neutral model Gates' tests are wired to (`AtlasGates.Model`): its gates, as data in
  the shape a model compiles them: whether a crate ships (every condition holds), and how
  a parcel is routed (ordered cases). What either cannot settle is asked (`ask`).
  """
  @behaviour AtlasGates.Model

  @gates %{
    "dispatch" => %{
      "version" => 1,
      "flavor" => "rule",
      "purpose" => "flow",
      "evidence" => ["seal", "packed", "loaded"],
      "rule" => %{"all" => [["equals", "seal", "intact"], ["same", "packed", "loaded"]]},
      "verdicts" => ["ship", "hold", "ask"],
      "decide" => %{
        "pass" => "ship",
        "changes_required" => "hold",
        "uncertain" => "ask",
        "error" => "ask"
      },
      "policy" => %{}
    },
    "route" => %{
      "version" => 2,
      "flavor" => "rule",
      "purpose" => "flow",
      "evidence" => ["weight", "zones", "express"],
      "rule" => %{
        "first" => [
          %{"when" => [["equals", "express", true]], "then" => "air"},
          %{
            "when" => [["in", "zones", ["north", "south"]], ["at_least", "weight", 20]],
            "then" => "road"
          }
        ],
        "otherwise" => "post"
      },
      "verdicts" => ["air", "road", "post", "ask"],
      "decide" => %{
        "air" => "air",
        "road" => "road",
        "post" => "post",
        "uncertain" => "ask",
        "error" => "ask"
      },
      "policy" => %{}
    }
  }

  @impl true
  def gates, do: @gates

  @doc "How a ruling's key is made: RU- and the next number, three digits."
  @impl true
  def ids, do: %{"ruling" => %{"prefix" => "RU-", "digits" => 3, "prefixes" => ["RU-"]}}
end
