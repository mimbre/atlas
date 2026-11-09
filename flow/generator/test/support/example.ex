defmodule AtlasFlowGenerator.Example.Gates do
  @moduledoc "Gates of the neutral example: one smart, one rule."
  use AtlasFlowGenerator.Schema

  defgate :proofread,
    version: 2,
    flavor: :smart,
    advice: :checker,
    evidence: [:draft],
    verdicts: [:send, :redo, :person],
    decide: [pass: :send, changes_required: :redo, uncertain: :person, error: :person],
    policy: [max_rounds: 2]

  defgate :size_limit, version: 1, flavor: :rule, verdicts: [:fits, :person]
end

defmodule AtlasFlowGenerator.Example do
  @moduledoc "A neutral subflow that uses every macro once: a letter, written, checked and posted."
  use AtlasFlowGenerator.Schema, gates: AtlasFlowGenerator.Example.Gates

  subflow :letter, label: "Letter", subject: :letter do
    run_as "system:post"
    owner via: :desk, relation: :held_by
    channel :mail
    per_subject :one
    start :create
    start :predicate, when: "entity.kind == 'reply'"
    initial :draft

    state :draft, label: "Write the draft" do
      pass :writer, mode: :draft, on: [delivered: :proofread, failed: :stuck]
      timer :slow, "1d", to: :stuck, label: "The writer did not finish"
    end

    state :proofread do
      gate :proofread, send: :post, redo: :draft, person: :stuck
    end

    state :post, label: "Post it" do
      effect :post_letter,
        service: :mail,
        field: :post_result,
        also: [reply: :none],
        on: [done: :sent, refused: :stuck]

      create :receipt, properties: [title: "Receipt"], relate: :receipt_of
    end

    state :sent, label: "Sent" do
      branch to: :answered, by: :atlas, when: "entity.urgent == true"
      await :reply, received: :answered, lost: :stuck
    end

    state :stuck, label: "Someone decides" do
      wait_for [:editor], on: :choice, retry: :draft, drop: :dropped
      branch to: :dropped, roles: [:admin], when: "entity.choice == 'drop'"
    end

    final :answered, label: "Answered" do
      set archived: true
    end

    final :dropped, status: :cancelled
  end
end
