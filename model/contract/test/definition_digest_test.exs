defmodule Model.DefinitionDigestTest do
  use ExUnit.Case, async: true
  alias RelaDSL.DefinitionDigest

  test "published decide pair has approved canonical bytes and explicit legacy re-keys" do
    migrations =
      "../../rela/flow-runtime.json"
      |> File.read!()
      |> JSON.decode!()
      |> get_in(["flow_runtime", "selection", "decide", "migrations"])

    # Per environment: the term digest, the canonical digest before owner answers, and the
    # digest with owner answers and deadline (#109) that slice 7 re-keys.
    for {target, env, old, new, answered} <- [
          {"atlas", "prod", "118c1cf31028979df064344d708a59f8ee19ad97493b47d66ac2d66cbb8dbb00",
           "d9aadf74d08e0fb4ee4ada4d17980c10aafd4424f251061779cbd61b1c01c7aa",
           "bfd535ea5c570cc586c606825745a7f767bf138a5f5289093f629a99e06fb042"},
          {"test/atlas", "test",
           "77f00aa4ea2f8ec4ff3620b590794b6aabeedd8ce435a9e4a635e909d7d40b93",
           "e2d4c41b758cb858aa40b2835c703f2c42f60039471f855fa7e2df0dbf171b4b",
           "b4a73029ce91d1bb1727498feb0c4b277315956c8b1ac547f15d1454eb5ccae8"}
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

      same = Map.new(flow["states"], fn {s, _} -> {s, s} end)
      answers = Enum.find(migrations, &(&1["from"] == new and &1["to"] == answered))
      assert answers["preserve_entry"] == true
      assert answers["states"] == same

      # Slice 7: the person waits name the configured decider; a re-key keeps every state.
      decider =
        Enum.find(migrations, &(&1["from"] == answered and &1["to"] == DefinitionDigest.of(flow)))

      assert decider["rekey"] == true
      assert decider["states"] == same

      for state <- ~w(for_person for_person_always),
          do:
            assert(
              flow["states"][state]["owner"]["default"] == %{
                "kind" => "person",
                "config" => "decider"
              }
            )

      assert Base.encode16(:crypto.hash(:sha256, :erlang.term_to_binary(old_flow)), case: :lower) ==
               old

      mapping = Enum.find(migrations, &(&1["from"] == old and &1["to"] == new))
      assert mapping["rekey"] == true
      assert mapping["states"] == Map.new(flow["states"], fn {s, _} -> {s, s} end)
    end
  end

  # What Flow runs is the compiled model: each subflow's digest/0 is the identity of the
  # committed flows.<env>.json entry, so live runs keep theirs (no migration, no re-key).
  test "each compiled subflow's digest is that of its committed entry, per environment" do
    for {env, target} <- [prod: "atlas", test: "test/atlas"] do
      committed = JSON.decode!(File.read!("../targets/#{target}/flows.json"))["flows"]
      compiled = Model.AtlasEyra.subflows(env)
      assert Enum.map(compiled, & &1.name()) == Enum.sort(Map.keys(committed))

      for subflow <- compiled do
        definition = committed[subflow.name()]
        assert subflow.digest() == DefinitionDigest.of(definition), "#{env} #{subflow.name()}"
        assert subflow.states() == Enum.sort(Map.keys(definition["states"]))
        assert subflow.subject() == definition["subject"]
      end
    end
  end

  test "the compiled decide has the slice 7 digests, each declared from the live one" do
    decide = fn env -> Enum.find(Model.AtlasEyra.subflows(env), &(&1.name() == "decide")) end
    migrations = Model.AtlasEyra.selection("decide")["migrations"]

    for {env, live, now} <- [
          {:prod, "bfd535ea5c570cc586c606825745a7f767bf138a5f5289093f629a99e06fb042",
           "06d957cd558f2e2957c4b0542bbef040876a5d426b245537eeedcf4aaa1a04b6"},
          {:test, "b4a73029ce91d1bb1727498feb0c4b277315956c8b1ac547f15d1454eb5ccae8",
           "ab9c1bdf9b947e32b98bd41dd0ddf3341101f2b4aeab76a3960d0a5ebd5104ae"}
        ] do
      assert decide.(env).digest() == now

      assert [%{"rekey" => true}] =
               Enum.filter(migrations, &(&1["from"] == live and &1["to"] == now))
    end
  end

  test "the compiled run selection and migrations are the committed flow-runtime.json's" do
    committed = JSON.decode!(File.read!("../../rela/flow-runtime.json"))["flow_runtime"]

    for {name, selection} <- committed["selection"],
        do: assert(Model.AtlasEyra.selection(name) == selection, name)

    assert Model.AtlasEyra.runs() == Map.take(committed, ~w(kind fields writer inputs))

    assert Model.AtlasEyra.gates() ==
             JSON.decode!(File.read!("../targets/atlas/flows.json"))["gates"]
  end
end
