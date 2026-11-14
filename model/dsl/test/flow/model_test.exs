defmodule RelaDSL.Flow.ModelTest do
  use ExUnit.Case, async: true

  alias RelaDSL.Flow.Model

  # What `owner` gives a subflow and its states (as data).
  defp subflow(owner, states), do: %{owner: owner, states: Enum.map(states, &%{owner: &1})}
  defp configured(kind, role), do: %{default: %{kind: kind, config: role}}

  test "every role an owner names as its default is a configured actor of the model" do
    flows = [
      subflow(%{default: %{kind: :team, key: :desk}}, [nil, configured(:clerk, :approver)]),
      subflow(configured(:clerk, :approver), [configured(:team, :dispatcher)])
    ]

    assert Model.actors(flows) == [approver: "clerk", dispatcher: "team"]
    assert Model.actors([subflow(%{default: %{kind: :team, key: :desk}}, [])]) == []
  end

  test "a role names one kind of fact" do
    flows = [subflow(configured(:clerk, :approver), [configured(:team, :approver)])]

    assert_raise ArgumentError, ~r/approver is named as a clerk and as a team/, fn ->
      Model.actors(flows)
    end
  end
end
