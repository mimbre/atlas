defmodule AtlasLearn.Observations.DecisionsTest do
  use ExUnit.Case, async: true
  alias AtlasLearn.Fixtures
  alias AtlasLearn.Observations.Decisions

  test "reads the caller's kind through the atlas client on the chosen environment" do
    observation =
      Decisions.observe(Fixtures.window(),
        kind: "ledger",
        env: "test",
        client: Fixtures.atlas_client()
      )

    assert_received {:atlas, ["list", "ledger", "--env", "test", "--json"]}
    assert_received {:atlas, ["get", "D-0030", "--env", "test", "--json"]}
    assert observation.status == :read
    assert Enum.map(observation.records, & &1.id) == ["D-0030", "D-0032"]
    assert Enum.map(observation.context, & &1.id) == ["D-0003", "D-0031"]
  end

  test "keeps only links to facts of the same kind" do
    observation =
      Decisions.observe(Fixtures.window(),
        kind: "ledger",
        env: "prod",
        client: Fixtures.atlas_client()
      )

    assert_received {:atlas, ["list", "ledger", "--env", "prod", "--json"]}
    accepted = Enum.find(observation.records, &(&1.id == "D-0030"))
    assert accepted.links == [%{list: "supersedes", key: "D-0003"}]
  end

  test "without a kind nothing is asked; a bad environment or a failing client is reported" do
    window = Fixtures.window()
    assert Decisions.observe(window, env: "test").status == :not_asked
    assert {:unavailable, _} = Decisions.observe(window, kind: "ledger", env: "staging").status

    failing = fn _args -> {:error, "atlas list failed: Control is not running"} end

    assert {:unavailable, "atlas list failed: Control is not running"} =
             Decisions.observe(window, kind: "ledger", env: "test", client: failing).status
  end
end
