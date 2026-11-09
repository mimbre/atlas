defmodule Model.RuntimeTest do
  use ExUnit.Case, async: true

  alias Model.AtlasEyra

  @committed "../../rela/atlas.json" |> File.read!() |> JSON.decode!()
  @selection ("../../rela/flow-runtime.json"
              |> File.read!()
              |> JSON.decode!())["flow_runtime"][
               "selection"
             ]

  # What Runtime works on: the facts the selected subflows present their work on (their
  # projection's `on`'s one kind), owned through its owner relation, once each (slice 13:
  # whether one is open and free to start on, Facts' presentation of it says); the kinds
  # the turn's `on` and `by` lead to.
  defp relations, do: AtlasEyra.__rela__(:description).schema["relations"]

  defp written(selection) do
    for {_name, %{"projection" => %{"owner_relation" => relation} = p}} <- Enum.sort(selection),
        is_binary(relation),
        [kind] <- [relations()[p["on"]]["to"]],
        uniq: true,
        do: %{"kind" => kind, "owner_relation" => relation}
  end

  test "the turn, its agent and the guidance records are the committed description's" do
    names = @committed["runtime"]["turn"]
    turn = AtlasEyra.turn()

    assert Map.drop(turn, ["items", "on_kinds"]) == names
    assert turn["on_kinds"] == relations()[names["on"]]["to"]
    assert turn["items"] == written(@selection)

    assert AtlasEyra.agent() == %{
             "kind" => hd(relations()[names["by"]]["to"]),
             "cannot_run" => @committed["runtime"]["agent"]["cannot_run"]
           }

    assert AtlasEyra.guidance() == @committed["guidance"]
  end

  test "every composition gives Runtime what it runs" do
    for model <- [AtlasEyra, Model.Profiles.Foundation, Model.Profiles.Incident] do
      assert AtlasRuntime.Model.check!(model) == model
      assert %{"kind" => _, "items" => items} = model.turn()
      assert is_list(items)
      assert %{"execution" => %{"kind" => _}} = model.guidance()
    end
  end

  test "what a worker reads first: the decisions its work is based on, and the standing ones" do
    decisions = [
      %{
        "key" => "D-0001",
        "values" => %{
          "title" => "Never break it",
          "force" => "principle",
          "status" => "accepted",
          "decision" => "It holds."
        },
        "links" => %{}
      },
      %{
        "key" => "D-0002",
        "values" => %{"title" => "Go there", "force" => "direction", "status" => "accepted"},
        "links" => %{"follows_from" => ["D-0001"]}
      }
    ]

    lookup = fn
      "decision", %{"key" => key} -> %{"fact" => Enum.find(decisions, &(&1["key"] == key))}
      "decision", %{"linked" => %{}} -> %{"facts" => decisions}
    end

    text =
      AtlasEyra.read_first(%{"key" => "SC-1", "links" => %{"based_on" => ["D-0002"]}}, lookup)

    lines = String.split(text, "\n")

    assert Enum.any?(lines, &String.starts_with?(&1, "- D-0002 Go there"))
    assert Enum.any?(lines, &String.starts_with?(&1, "  follows from D-0001"))
    # A standing principle that is also an anchor's ground is shown once.
    assert length(Enum.filter(lines, &(&1 =~ "D-0001"))) == 1
    # Values are shown by their labels where their type has them.
    assert text =~ "(direction, Accepted)"

    assert AtlasEyra.read_first(%{"key" => "SC-1", "links" => %{}}, fn _, _ ->
             %{"facts" => []}
           end) ==
             nil
  end
end
