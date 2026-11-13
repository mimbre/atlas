defmodule Model.IssueTest do
  use ExUnit.Case, async: true

  alias Model.Issue

  # The Issue subflow as slice 9 runs it: v1 build_and_merge's one state, for its owner
  # and what the owner sees, waiting for its pull request's outcome (the composition's
  # link). Its passes, gates and publish effect wait for what runs them (the moduledoc
  # says what each needs). Lines are left out.
  @flow %{
    name: :issue,
    label: "Issue",
    subject: :issue,
    run_as: "system:sf-flow",
    per_subject: :one,
    owner: %{
      via: :assignment,
      relation: :assigned_to,
      default: %{kind: :agent, key: :coordinator}
    },
    channel: :work,
    start: [%{on: :create, when: nil, permission: nil, every: nil}]
  }

  test "the header: it starts when the issue is created, whatever its stage" do
    assert [flow] = Issue.__flows__()
    assert Map.take(flow, Map.keys(@flow)) == @flow
    assert flow.initial == :author
    assert String.ends_with?(flow.file, "software/issue.ex")
  end

  test "2 states and 3 transitions" do
    [flow] = Issue.__flows__()
    assert length(flow.states) == 2
    assert Enum.sum(Enum.map(flow.states, &(length(&1.branches) + length(&1.timers)))) == 3
  end

  test "each state, its mechanism, reset, branches and timers" do
    [flow] = Issue.__flows__()
    assert Enum.map(flow.states, &Map.delete(&1, :line)) == expected_states()
  end

  test "the two gates it will name again are still defined with their versions" do
    gates = Map.new(Model.AtlasEyra.__rela__(:gates), &{&1.name, &1})

    assert %{version: 1, purpose: :flow, verdicts: [:review, :rework, :person]} =
             gates.delivery_evidence

    assert %{version: 1, purpose: :flow, verdicts: [:ready, :rework, :person]} = gates.review
  end

  defp expected_states do
    [
      state(:author, "Building",
        awaits: [:pr_outcome],
        branches: [
          flow(:author, :pr_outcome, :changes_requested),
          flow(:done, :pr_outcome, :integrated),
          flow(:author, :pr_outcome, :closed)
        ],
        present: %{
          expected: "Build it",
          why: "its pull request is not merged",
          instructions:
            "Build it in one pull request and get that merged; link the pull request to it.",
          section: nil,
          answers: []
        }
      ),
      state(:done, "Integrated", final: true)
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
        timers: [],
        present: nil,
        owner: nil
      },
      Map.new(fields)
    )
  end

  # A branch the flow framework takes when it writes `field`.
  defp flow(to, field, value),
    do: %{to: to, roles: ["atlas-flow"], when: "entity.#{field} == '#{value}'", label: nil}
end
