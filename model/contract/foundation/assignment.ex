defmodule Model.Assignment do
  @moduledoc "What belongs to being assigned, for one fact; who is next, what is expected and the start page that shows it."
  use RelaDSL

  entity :assignment,
    label: "Assignment",
    plural: "assignments",
    id_type: :manual,
    id_prefix: "AS-",
    description: """
    What belongs to being assigned, for one fact: who it is assigned to and what
    they are expected to do. Made and deleted with the fact; its id is AS- and the
    fact's, e.g. AS-UC-Atlas-01.
    """ do
    field(:of, :string, required: true, description: "The key of the fact it belongs to")

    field(:expected, :string,
      description: "What its owner is expected to do next; Flow writes it (IS-Atlas-53)",
      set_by: [:flow, :migration]
    )

    field(:deadline, :datetime,
      description: "When it should be done by; optional, it only marks it late (IS-Atlas-14)"
    )

    field(:handover, :string,
      description:
        "A deferred automatic handover; Flow keeps it until the running owner ends its turn",
      set_by: [:flow]
    )

    field(:flow_state, :string,
      description: "The state of its flow it is in; Flow writes it (IS-Atlas-54)"
    )

    top(false)
    by_hand(:update)
    late(after: :deadline, while: :expected, label: "late")
    primary(:of)

    create(
      ask: [:of],
      id: [
        from: :of,
        pattern: "^(.+)$",
        template: "AS-{1}",
        error: "of must be the key of the fact it belongs to"
      ]
    )
  end

  relation(:assigned_to,
    label: "assigned to",
    description: "Who is next in line to do something with it; one, a person or an agent.",
    from: [:assignment],
    to: [:person, :agent],
    max_outgoing: 1,
    inverse: {:assignments, "assignments"},
    actions: [
      change: [label: "Hand to…", key: "h", with: [:deadline], cause: "handed to {to} by {by}"]
    ]
  )

  todo_words(title: "What to do", why: "Why", instructions: "How", answers: "Answers")

  start_page(
    assigned: [relation: :assigned_to, title: "Assigned to you", count: "{count} assigned to you"],
    open: [
      title: "Open work",
      empty: "Nothing is open: no fact is assigned to anyone, and nothing is expected."
    ]
  )
end
