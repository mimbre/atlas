defmodule AtlasFlowGenerator.DeciderTest do
  use ExUnit.Case, async: true

  @fixed """
  defrules :person_always do
    rule :protected, when: [{:includes, :tags, "protected"}], decision: "POL-1"
  end
  """
  @options [
    version: 1,
    flavor: :rule,
    purpose: :decider,
    fixed: :person_always,
    evidence: [tags: {:field, :tags}, expired: {:constant, false}, score: {:field, :score}],
    rule: [
      first: [
        [when: [{:equals, :expired, true}], then: :agent_unverified],
        [when: [{:at_least, :score, 10}], then: :person],
        [when: [{:in, :tags, ["open"]}], then: :agent]
      ],
      otherwise: :advise
    ],
    verdicts: [:person_always, :person, :agent, :agent_unverified],
    decide: [
      person_always: :person_always,
      person: :person,
      agent: :agent,
      agent_unverified: :agent_unverified,
      advise: :person,
      uncertain: :person,
      error: :person
    ],
    answer_within: [test: "5m", prod: "48h"]
  ]

  defp compile(opts, fixed \\ @fixed) do
    mod = Module.concat(__MODULE__, "Fixture#{System.unique_integer([:positive])}")

    source =
      "defmodule #{inspect(mod)} do\nuse AtlasFlowGenerator.Schema\n" <>
        fixed <> "defgate :g, " <> inspect(opts, limit: :infinity) <> "\nend"

    Code.compile_string(source, "decider_fixture.ex")
    mod
  end

  defp refused(opts, message, fixed \\ @fixed, line \\ nil) do
    error = assert_raise CompileError, fn -> compile(opts, fixed) end
    assert error.file == "decider_fixture.ex"
    assert error.line == (line || 2 + length(String.split(fixed, "\n")))
    assert error.description =~ message
  end

  test "fixed cases are expanded before tunable cases and survive the writer" do
    [gate] = compile(@options).__gates__()
    assert [fixed | rest] = gate.rule[:first]
    assert fixed[:then] == :person_always
    assert fixed[:decision] == "POL-1"
    assert hd(rest)[:then] == :agent_unverified
    data = JSON.decode!(AtlasFlowGenerator.Atlas.flows_json([], [gate], "hash"))["gates"]["g"]
    assert data["fixed_rules"] == Enum.take(data["rule"]["first"], 1)
    assert data["answer_within"] == %{"test" => "5m", "prod" => "48h"}
    assert data["evidence"]["tags"] == ["field", "tags"]
  end

  test "a decider must name the fixed person rules" do
    refused(Keyword.delete(@options, :fixed), "needs fixed: :person_always")
  end

  test "a decider has exactly the four verdicts" do
    refused(Keyword.update!(@options, :verdicts, &(&1 ++ [:extra])), "verdicts must be exactly")
  end

  for outcome <- [:uncertain, :error, :advise] do
    test "a decider sends #{outcome} to person" do
      opts = Keyword.update!(@options, :decide, &Keyword.put(&1, unquote(outcome), :agent))
      refused(opts, "#{unquote(outcome)}")
    end
  end

  test "each fixed rule cites a decision" do
    refused(@options, "needs decision:", String.replace(@fixed, ~s|, decision: "POL-1"|, ""), 4)
  end

  test "a fixed ruleset must exist" do
    refused(Keyword.put(@options, :fixed, :missing), "unknown defrules")
  end

  test "fixed rules require ordered cases" do
    refused(
      Keyword.put(@options, :rule, all: [{:equals, :expired, false}]),
      "fixed needs an ordered first/otherwise rule"
    )
  end

  test "empty and duplicate rulesets are refused" do
    refused(@options, "needs at least one rule", "defrules :person_always do\nend\n", 3)
    refused(@options, "defined twice", @fixed <> @fixed, 3)
  end

  test "fixed rule names are valid" do
    refused(@options, "needs a valid name", String.replace(@fixed, ":protected", ":Bad"), 4)
  end

  test "ordered rules need cases, conditions, outcomes and a fallback" do
    for rule <- [
          [first: [[when: [], then: :agent]], otherwise: :advise],
          [first: [[when: [{:equals, :expired, true}]]], otherwise: :advise],
          [first: [[when: [{:equals, :expired, true}], then: :agent]]]
        ] do
      refused(Keyword.put(@options, :rule, rule), "rule")
    end
  end

  test "ordered outcomes must all be mapped" do
    refused(
      Keyword.update!(@options, :decide, &Keyword.delete(&1, :agent)),
      "does not cover"
    )
  end

  test "new operators validate their operands and declared evidence" do
    for condition <- [{:in, :score, 1}, {:at_least, :score, "10"}, {:includes, :missing, "x"}] do
      rule = [first: [[when: [condition], then: :agent]], otherwise: :advise]
      refused(Keyword.put(@options, :rule, rule), "rule")
    end
  end
end
