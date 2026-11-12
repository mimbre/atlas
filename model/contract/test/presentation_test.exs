defmodule Model.PresentationTest do
  use ExUnit.Case, async: true

  # A component reading the committed target, as a running one would.
  defmodule Committed do
    use RelaDSL.Runtime, target: "../../targets/atlas/flows.json"
  end

  # The v1 flows of the description (design, section 9), as the committed atlas.json holds them. Each type's entry is
  # deleted at its cutover; until then its text must reach the Atlas target unchanged.
  @v1 "../../rela/atlas.json"
  @external_resource @v1

  # Where each v1 state went: {v1 flow, v1 state} => [{subflow, state}]. A v1 state that
  # is done has nothing to present and is not listed.
  @moved %{
    {"test_and_accept", "rework"} => [{"test_and_accept_scene", "rework"}],
    {"test_and_accept", "to_test"} => [{"test_and_accept_scene", "to_test"}],
    {"test_and_accept", "break_down"} => [{"test_and_accept_scene", "break_down"}],
    {"test_and_accept", "building"} => [{"test_and_accept_scene", "building"}],
    # v1's one design state, writing and changes requested, is the design pass and its rework.
    {"design_and_accept", "design"} => [
      {"design_and_accept", "designing"},
      {"design_and_accept", "redesign"}
    ],
    {"design_and_accept", "design_review"} => [{"design_and_accept", "design_review"}],
    {"design_and_accept", "rework"} => [{"test_and_accept_use_case", "rework"}],
    {"design_and_accept", "to_test"} => [{"test_and_accept_use_case", "to_test"}],
    {"design_and_accept", "break_down"} => [{"test_and_accept_use_case", "break_down"}],
    {"design_and_accept", "building"} => [{"test_and_accept_use_case", "building"}],
    # v1's one manual state became passes, gates and the publish effect; it begins with the author pass.
    {"build_and_merge", "building"} => [{"issue", "author"}],
    {"review_and_merge", "open"} => [{"pull_request", "checking"}]
  }

  # Open v1 states with no state in the subflows yet: `decide` ends when it is accepted,
  # so "carry it out" has no state to be presented in. Named, so it is not lost silently.
  @not_moved [{"decide", "waiting"}, {"decide", "proposed"}]

  defp v1, do: JSON.decode!(File.read!(@v1))["flows"]

  defp open_states do
    for {flow, %{"states" => states}} <- v1(),
        s <- states,
        s["done"] != true,
        do: {{flow, s["name"]}, s}
  end

  test "every open v1 state is moved, or named as not moved" do
    assert Enum.sort(Enum.map(open_states(), &elem(&1, 0))) ==
             Enum.sort(Map.keys(@moved) ++ @not_moved)
  end

  test "the v1 expected, why and todo of each state appear unchanged in the Atlas target" do
    for {at, s} <- open_states(), {subflow, state} <- Map.get(@moved, at, []) do
      present = get_in(Committed.flows(), [subflow, "states", state, "present"])

      assert present == Map.take(s, ["expected", "why", "todo"]),
             "#{inspect(at)} -> #{subflow}.#{state}: #{inspect(present)}"
    end
  end

  test "a subflow that takes over a v1 flow has that flow's owner as its default" do
    owners =
      for {at, s} <- open_states(), {subflow, _} <- Map.get(@moved, at, []), uniq: true do
        {subflow, s["owner"]}
      end

    # A person in v1 is a role now (wait_for); v1's architect is the profile of the design
    # passes, routed to the owner; every other v1 owner is the default.
    for {subflow, %{"kind" => kind} = owner} <- owners,
        kind == "agent",
        owner["key"] != "architect" do
      assert get_in(Committed.flows(), [subflow, "owner", "default"]) == owner, subflow
    end

    # Every subflow that takes over a v1 flow names a default owner.
    for {subflow, _} <- owners,
        do: assert(get_in(Committed.flows(), [subflow, "owner", "default"]), subflow)
  end
end
