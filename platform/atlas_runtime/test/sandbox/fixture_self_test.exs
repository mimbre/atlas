defmodule AtlasRuntime.Sandbox.FixtureSelfTest do
  # S6 package F: the Elixir builder must produce the tree (or the refusal) that the Go builder
  # recorded in _self/expect.json for every _self row (host/internal/s6fixture,
  # TestS6FixtureSelfTest). expect.json is written from Go only (B2).
  use ExUnit.Case, async: true

  alias AtlasRuntime.S6Fixture

  @self Path.join(S6Fixture.dir(), "_self")
  @external_resource Path.join(@self, "rows.json")
  @external_resource Path.join(@self, "expect.json")
  @rows S6Fixture.load_table!(Path.join(@self, "rows.json"))["rows"]

  setup_all do
    expect = S6Fixture.read_json!(Path.join(@self, "expect.json"))
    %{expect: expect["rows"]}
  end

  test "expect.json holds a result for exactly the self-test rows", %{expect: expect} do
    assert Enum.sort(Map.keys(expect)) == Enum.sort(Enum.map(@rows, & &1["id"]))
  end

  for row <- @rows do
    @row row
    test "self-test row #{row["id"]}", %{expect: expect} do
      root = S6Fixture.new_root!()
      places = S6Fixture.default_places(root)
      result = S6Fixture.result(root, places, Map.get(@row, "fs", []))

      result =
        if Map.has_key?(@row, "input"),
          do:
            Map.put(
              result,
              "input",
              S6Fixture.abstract_value(places, S6Fixture.substitute_value(places, @row["input"]))
            ),
          else: result

      refute JSON.encode!(result) =~ root
      assert result == expect[@row["id"]]
    end
  end
end
