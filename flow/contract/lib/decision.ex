defmodule AtlasFlowContract.Decision do
  @moduledoc """
  The decision subflow: a proposed decision in the ledger is accepted or rejected.

  Who may accept follows the ledger design's table, as one branch per row, in that
  order: a principle needs the principle authority; any other decision a decider; a
  delegated agent may accept or reject only a `two_way` decision outside the
  `product` and `security` categories. The subflow writes `status`; people and
  agents write `verdict`.
  """
  use AtlasFlowGenerator.Schema

  @delegable "entity.reversibility == 'two_way' and entity.category ~= 'product' and " <>
               "entity.category ~= 'security'"

  subflow :decide, label: "Decide", subject: :decision do
    run_as "system:sf-flow"
    owner via: :assignment, relation: :assigned_to, default: {:agent, :coordinator}
    channel :debate
    start :create
    initial :proposed

    state :proposed, label: "Proposed" do
      present(
        expected: "Have it decided",
        why: "it is proposed",
        instructions:
          "Have it accepted or rejected, with decided_by and decided_at. A person accepts a product, security, one-way or principle decision; any other a person, or an agent under delegated_by. A principle names its enforced_by."
      )

      set status: :proposed
      wait_for [:decider], on: :verdict

      branch to: :accepted,
             roles: [:principle_authority],
             when: "entity.verdict == 'accept' and entity.force == 'principle'"

      branch to: :accepted,
             roles: [:decider],
             when: "entity.verdict == 'accept' and entity.force ~= 'principle'"

      branch to: :accepted,
             roles: [:delegate],
             when: "entity.verdict == 'accept' and entity.force ~= 'principle' and " <> @delegable

      branch to: :rejected,
             roles: [:decider, :principle_authority],
             when: "entity.verdict == 'reject'"

      branch to: :rejected,
             roles: [:delegate],
             when: "entity.verdict == 'reject' and " <> @delegable
    end

    final :accepted, label: "Accepted" do
      set status: :accepted
    end

    final :rejected, label: "Rejected" do
      set status: :rejected
    end
  end
end
