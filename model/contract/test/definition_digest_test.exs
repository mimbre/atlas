defmodule Model.DefinitionDigestTest do
  use ExUnit.Case, async: true
  alias RelaDSL.DefinitionDigest

  test "published decide pair has approved canonical bytes and explicit legacy re-keys" do
    migrations =
      "../../rela/flow-runtime.json"
      |> File.read!()
      |> JSON.decode!()
      |> get_in(["flow_runtime", "selection", "decide", "migrations"])

    for {target, env, old, new} <- [
          {"atlas", "prod", "118c1cf31028979df064344d708a59f8ee19ad97493b47d66ac2d66cbb8dbb00",
           "d9aadf74d08e0fb4ee4ada4d17980c10aafd4424f251061779cbd61b1c01c7aa"},
          {"test/atlas", "test",
           "77f00aa4ea2f8ec4ff3620b590794b6aabeedd8ce435a9e4a635e909d7d40b93",
           "e2d4c41b758cb858aa40b2835c703f2c42f60039471f855fa7e2df0dbf171b4b"}
        ] do
      flow =
        File.read!("../targets/#{target}/flows.json")
        |> JSON.decode!()
        |> get_in(["flows", "decide"])

      old_flow = JSON.decode!(File.read!("test/golden/decide-#{env}.canonical.json"))
      assert DefinitionDigest.of(old_flow) == new
      assert Map.drop(flow, ["states"]) == Map.drop(old_flow, ["states"])

      for {state, data} <- flow["states"] do
        assert Map.drop(data, ["owner", "present"]) ==
                 Map.drop(old_flow["states"][state], ["owner", "present"])
      end

      migration =
        Enum.find(migrations, &(&1["from"] == new and &1["to"] == DefinitionDigest.of(flow)))

      assert migration["preserve_entry"] == true
      assert migration["states"] == Map.new(flow["states"], fn {s, _} -> {s, s} end)

      assert Base.encode16(:crypto.hash(:sha256, :erlang.term_to_binary(old_flow)), case: :lower) ==
               old

      mapping = Enum.find(migrations, &(&1["from"] == old and &1["to"] == new))
      assert mapping["rekey"] == true
      assert mapping["states"] == Map.new(flow["states"], fn {s, _} -> {s, s} end)
    end
  end
end
