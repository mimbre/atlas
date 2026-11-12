defmodule AtlasFlowContract.Decision do
  @moduledoc "A recorded decider verdict selects who may decide and whether the wait has a limit."
  use AtlasFlowGenerator.Schema, gates: AtlasFlowContract.Gates

  subflow :decide, label: "Decide", subject: :decision do
    run_as "system:atlas-flow"
    owner via: :assignment, relation: :assigned_to, default: {:agent, :coordinator}
    channel :debate
    start :create
    initial :deciding

    state :deciding, label: "Who decides" do
      gate :accept_decision,
        person_always: :for_person_always,
        person: :for_person,
        agent: :for_agent,
        agent_unverified: :for_agent_unverified
    end

    state :for_person_always, label: "A person decides" do
      owner via: :assignment,
            relation: :assigned_to,
            default: {:person, :melle},
            preserve_kind: :person

      wait_for [:principle_authority, :decider],
        on: :status,
        reset: false,
        accepted: :accepted,
        rejected: :rejected

      present(
        expected: "Have a person decide",
        answers: [
          [
            key: "a",
            label: "Accept",
            change: %{self: :decided_by, values: %{status: :accepted, decided_at: "$now"}}
          ],
          [
            key: "f",
            label: "Reject",
            note: true,
            change: %{self: :decided_by, values: %{status: :rejected, decided_at: "$now"}}
          ]
        ],
        why: "a fixed person rule holds",
        instructions:
          "A person accepts or rejects with decided_by and decided_at. A principle names enforced_by. This wait never times out."
      )
    end

    state :for_person, label: "Waiting for a person" do
      owner via: :assignment,
            relation: :assigned_to,
            default: {:person, :melle},
            preserve_kind: :person

      wait_for :decider, on: :status, reset: false, accepted: :accepted, rejected: :rejected
      timer :no_answer, {:gate_limit, :accept_decision}, to: :deciding

      present(
        expected: "Have a person decide",
        deadline: :no_answer,
        answers: [
          [
            key: "a",
            label: "Accept",
            change: %{self: :decided_by, values: %{status: :accepted, decided_at: "$now"}}
          ],
          [
            key: "f",
            label: "Reject",
            note: true,
            change: %{self: :decided_by, values: %{status: :rejected, decided_at: "$now"}}
          ]
        ],
        why: "the decider gate requires a person",
        instructions:
          "Accept or reject with decided_by and decided_at. After the answer limit Flow asks the gate again."
      )
    end

    state :for_agent, label: "An agent may decide" do
      wait_for [:delegate, :decider],
        on: :status,
        reset: false,
        accepted: :accepted,
        rejected: :rejected

      present(
        expected: "Have it decided",
        why: "the recorded gate permits an agent",
        instructions: "Accept or reject with decided_by and decided_at."
      )
    end

    state :for_agent_unverified, label: "Unverified agent decision" do
      set unverified: true

      wait_for [:delegate, :decider],
        on: :status,
        reset: false,
        accepted: :accepted,
        rejected: :rejected

      present(
        expected: "Have it decided (unverified)",
        why: "a person did not answer in time",
        instructions:
          "Accept or reject with decided_by and decided_at. The decision carries a red flag until a person confirms or overrules its gate verdict."
      )
    end

    final :accepted, label: "Accepted"
    final :rejected, label: "Rejected"
  end
end
