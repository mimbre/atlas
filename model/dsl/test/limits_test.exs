defmodule RelaDSL.LimitsTest do
  use ExUnit.Case, async: true
  alias RelaDSL.{Atlas, Limits, Rela}

  defp flows do
    [flow] = RelaDSL.Example.__flows__()
    [first | rest] = flow.states

    first = %{
      first
      | timers: [
          %{name: :late, period: {:gate_limit, :allocate}, to: :stuck, since: nil, label: nil}
        ]
    }

    [%{flow | states: [first | rest]}]
  end

  test "each environment has concrete periods and hashes its own immutable pair" do
    gates = [%{name: :allocate, answer_within: [test: "5m", prod: "48h"]}]

    for {env, period} <- [test: "5m", prod: "48h"] do
      [resolved] = Limits.resolve(flows(), gates, env)
      assert hd(hd(resolved.states).timers).period == period
      yaml = Rela.flows_yaml([resolved])
      assert yaml =~ "period: #{period}"

      assert Atlas.sha256(yaml) !=
               Atlas.sha256(
                 Rela.flows_yaml(flows(), gates, if(env == :test, do: :prod, else: :test))
               )
    end

    assert hd(hd(hd(flows()).states).timers).period == {:gate_limit, :allocate}
  end

  test "missing gates, environments and invalid limits refuse generation" do
    for gates <- [
          [],
          [%{name: :allocate}],
          [%{name: :allocate, answer_within: [prod: "48h"]}],
          [%{name: :allocate, answer_within: [test: "0m"]}]
        ] do
      assert_raise ArgumentError, fn -> Limits.resolve(flows(), gates, :test) end
    end
  end

  test "the schema refuses a timer on a fixed-verdict destination and unknown gate limits" do
    source = ~S"""
    use RelaDSL.Schema
    defrules :person_always do
      rule :fixed, when: [{:equals, :flag, true}], cites: "P-1"
    end
    defgate :allocate, version: 1, flavor: :rule, purpose: :decider,
      fixed: :person_always, evidence: [:flag],
      rule: [first: [[when: [{:equals, :flag, false}], then: :person]], otherwise: :advise],
      verdicts: [:person_always, :person, :agent, :agent_unverified],
      decide: [person_always: :person_always, person: :person, advise: :person, uncertain: :person, error: :person],
      answer_within: [test: "5m", prod: "48h"]
    subflow :route, subject: :parcel do
      run_as "system:route"
      owner default: {:team, :desk}
      start :create
      initial :routing
      state :routing do
        gate :allocate, person_always: :waiting, person: :done, agent: :done, agent_unverified: :done
      end
      state :waiting do
        timer :late, "5m", to: :done
      end
      final :done
    end
    """

    for {text, message} <- [
          {source, "person_always destination cannot have a timer"},
          {String.replace(source, ~s(timer :late, "5m"), "timer :late, {:gate_limit, :missing}"),
           "invalid period or gate limit"}
        ] do
      module = "LimitFixture#{System.unique_integer([:positive])}"

      assert_raise CompileError, ~r/#{message}/, fn ->
        Code.compile_string("defmodule #{module} do\n#{text}\nend")
      end
    end
  end
end
