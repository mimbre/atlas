defmodule Model.Turn do
  @moduledoc "One stretch in which an agent acts on one item, and how Runtime keeps it."
  use RelaDSL

  type(:turn_state, values: [:running, :ended], labels: [running: "Running", ended: "Ended"])

  entity :turn,
    label: "Turn",
    plural: "turns",
    id_type: :manual,
    id_prefix: "TU-",
    description: """
    One stretch in which an agent acts on one item: started by Runtime for the item's
    owner, kept while the agent shows activity (its lease), ended when the agent ends
    it, goes silent, crashes, runs too long, or no longer owns the item.
    """ do
    field(:state, :turn_state,
      required: true,
      description: "Running or ended",
      set_by: [:runtime]
    )

    field(:machine, :string,
      required: true,
      description: "The machine whose Runtime runs it",
      set_by: [:runtime]
    )

    field(:lease_until, :datetime,
      description:
        "Until when the turn holds its lease: the agent's last activity plus the silence limit",
      set_by: [:runtime],
      label: "Lease until"
    )

    field(:activity, :string,
      description: "The agent's last activity Runtime saw",
      set_by: [:runtime]
    )

    field(:why, :string, description: "Why it ended", set_by: [:runtime])

    field(:ended_at, :datetime,
      description: "When it ended",
      set_by: [:runtime],
      label: "Ended at"
    )

    field(:outcome, :string,
      description: "The agent's fact about what it did; Runtime reads it and ends the turn",
      set_by: [:turn_owner],
      multiline: true
    )

    field(:attempt, :string,
      description: "Runtime execution fence; a new attempt never inherits old guidance.",
      set_by: [:runtime]
    )

    field(:title, :string,
      description:
        "What the turn is about when it has no item: the first heading and line of what the agent was asked, shortened",
      set_by: [:runtime]
    )

    field(:model, :string,
      description:
        "The model the agent runs: the one its harness reports, else the one Runtime asked for",
      set_by: [:runtime]
    )

    top(false)
    by_hand(false)
    order(:newest)
  end

  relation(:turn_on,
    label: "on",
    description: "The item the turn acts on.",
    from: [:turn],
    to: [:assignment],
    max_outgoing: 1,
    inverse: {:turns, "turns"}
  )

  relation(:turn_by,
    label: "by",
    description: "The agent that acts in the turn.",
    from: [:turn],
    to: [:agent],
    max_outgoing: 1,
    inverse: {:turns_by, "turns"}
  )

  runtime(
    turn: [
      kind: :turn,
      key: "TU-{on}-{n}",
      on: :turn_on,
      by: :turn_by,
      state: :state,
      running: :running,
      ended: :ended,
      machine: :machine,
      lease: :lease_until,
      activity: :activity,
      why: "why",
      ended_at: :ended_at,
      outcome: :outcome,
      attempt: :attempt,
      title: :title,
      model: :model
    ],
    agent: [cannot_run: :cannot_run]
  )
end
