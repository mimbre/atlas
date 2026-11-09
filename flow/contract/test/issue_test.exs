defmodule AtlasFlowContract.IssueTest do
  use ExUnit.Case, async: true

  alias AtlasFlowContract.Issue

  # The Issue subflow as the design describes it (input-definitions/issue.flows.yaml for
  # the Rela side; the mechanism on each state for the Atlas side). Lines are left out.
  @flow %{
    name: :issue,
    label: "Issue",
    subject: :issue,
    run_as: "system:sf-flow",
    per_subject: :one,
    owner: %{via: :assignment, relation: :assigned_to},
    channel: :work,
    start: [%{on: :predicate, when: "entity.stage == 'development'", permission: nil, every: nil}]
  }

  test "the header" do
    assert [flow] = Issue.__flows__()
    assert Map.take(flow, Map.keys(@flow)) == @flow
    assert flow.initial == :author
    assert String.ends_with?(flow.file, "lib/issue.ex")
  end

  test "10 states and 27 transitions" do
    [flow] = Issue.__flows__()
    assert length(flow.states) == 10
    assert Enum.sum(Enum.map(flow.states, &(length(&1.branches) + length(&1.timers)))) == 27
  end

  test "each state, its mechanism, reset, branches and timers" do
    [flow] = Issue.__flows__()
    assert Enum.map(flow.states, &Map.delete(&1, :line)) == expected_states()
  end

  test "the two gates it names are defined with their versions" do
    assert [
             %{name: :delivery_evidence, version: 1, verdicts: [:review, :rework, :person]},
             %{name: :review, version: 1, verdicts: [:ready, :rework, :person]}
           ] = AtlasFlowContract.Gates.__gates__()
  end

  defp expected_states do
    runtime_wait = &timer(:runtime_wait, "2d", "The owner's Runtime did not finish the #{&1}")
    no_decision = timer(:no_decision, "1h", "No gate decision within an hour")

    [
      state(:author, "Author pass",
        mechanism:
          {:pass,
           %{
             profile: :developer,
             mode: :author,
             folder: {:materialize, :target},
             permissions: :materialized_folder,
             freeze: :packet
           }},
        set: [pass_result: :none],
        branches: [
          flow(:delivery_gate, :pass_result, :delivered),
          flow(:needs_person, :pass_result, :failed)
        ],
        timers: [runtime_wait.("pass")]
      ),
      state(:delivery_gate, "Delivery-evidence gate",
        mechanism: {:gate, %{gate: :delivery_evidence, version: 1}},
        set: [gate_result: :none],
        branches: [
          flow(:review, :gate_result, :review),
          flow(:rework, :gate_result, :rework),
          flow(:needs_person, :gate_result, :person)
        ],
        timers: [no_decision]
      ),
      state(:review, "Review pass",
        mechanism:
          {:pass,
           %{
             profile: :developer,
             mode: :review,
             folder: {:packet, :last},
             permissions: :review_packet,
             diversity: :other_vendor,
             findings: :required
           }},
        set: [pass_result: :none],
        branches: [
          flow(:review_gate, :pass_result, :delivered),
          flow(:needs_person, :pass_result, :failed)
        ],
        timers: [runtime_wait.("review")]
      ),
      state(:review_gate, "Review gate",
        mechanism: {:gate, %{gate: :review, version: 1}},
        set: [gate_result: :none],
        branches: [
          flow(:publish, :gate_result, :ready),
          flow(:rework, :gate_result, :rework),
          flow(:needs_person, :gate_result, :person)
        ],
        timers: [no_decision]
      ),
      state(:rework, "Rework pass",
        mechanism:
          {:pass,
           %{
             profile: :developer,
             mode: :rework,
             folder: {:continue, :author},
             permissions: :materialized_folder,
             input: {:channel, :newest_since_last_pass},
             freeze: :packet
           }},
        set: [pass_result: :none],
        branches: [
          flow(:delivery_gate, :pass_result, :delivered),
          flow(:needs_person, :pass_result, :failed)
        ],
        timers: [runtime_wait.("rework")]
      ),
      state(:publish, "Create or update the PR",
        mechanism:
          {:effect,
           %{
             action: :publish_review,
             field: :effect_result,
             service: :code,
             fingerprint: {:approved_by, :review_gate},
             submit: {:from, :packet},
             records: {:pull_request, :in_issue},
             also: [pr_outcome: :open]
           }},
        set: [effect_result: :none],
        branches: [
          flow(:in_pr, :effect_result, :done),
          flow(:needs_person, :effect_result, :refused)
        ],
        timers: [timer(:no_effect, "1h", "Code did not answer within an hour")]
      ),
      state(:in_pr, "In pull request",
        awaits: [:pr_outcome],
        branches: [
          flow(:rework, :pr_outcome, :changes_requested),
          flow(:done, :pr_outcome, :integrated),
          flow(:closed, :pr_outcome, :closed)
        ]
      ),
      state(:needs_person, "A person decides",
        status: :input_required,
        waiting_for: ["maintainer"],
        set: [gate_result: :none],
        branches: [
          person(:review, :review),
          person(:rework, :rework),
          person(:publish, :ready),
          person(:closed, :close)
        ]
      ),
      state(:done, "Integrated", final: true),
      state(:closed, "Closed", final: true, status: :cancelled)
    ]
  end

  defp state(name, label, fields) do
    Map.merge(
      %{
        name: name,
        label: label,
        status: nil,
        final: false,
        mechanism: nil,
        waiting_for: [],
        awaits: [],
        set: [],
        creates: [],
        branches: [],
        timers: []
      },
      Map.new(fields)
    )
  end

  # A branch the flow framework takes when it writes `field`.
  defp flow(to, field, value), do: branch(to, ["atlas-flow"], field, value)
  # A branch a maintainer takes from their inbox.
  defp person(to, value), do: branch(to, ["maintainer"], :gate_result, value)

  defp branch(to, roles, field, value),
    do: %{to: to, roles: roles, when: "entity.#{field} == '#{value}'", label: nil}

  defp timer(name, period, label),
    do: %{name: name, period: period, to: :needs_person, since: nil, label: label}
end
