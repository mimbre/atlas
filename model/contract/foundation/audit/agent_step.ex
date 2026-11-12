defmodule Model.AgentStep do
  @moduledoc "One step of a request's plan."
  use RelaDSL

  type(:agent_step_state,
    values: [:stored, :refused, :dropped, :not_run],
    labels: [stored: "Stored", refused: "Refused", dropped: "Dropped", not_run: "Not run"]
  )

  entity :agent_step,
    label: "Agent step",
    plural: "agent_steps",
    aliases: ["st"],
    id_type: :manual,
    id_prefix: "ST-",
    description: """
    One step of a request's plan: the form it filled, with what values, and
    what became of it, with the key of the item it made, changed or deleted.
    """ do
    field(:title, :string, required: true, description: "The title of the form it filled")
    field(:n, :integer, description: "Its number in the plan")
    field(:tool, :string, description: "put, set or delete")
    field(:state, :agent_step_state, description: "What became of it")
    field(:detail, :string, description: "The id it stored, or why it was refused")

    field(:made, :string,
      description: "The key of the item it made, changed or deleted",
      cause: "What the agent did here"
    )

    field(:values, :string, description: "The values it gave, as JSON", multiline: true)

    field(:was, :string,
      description: "For a change: the values it replaced, as JSON",
      multiline: true
    )

    agent(:step)
    by_hand(false)
    action(key: "x", label: "Overrule", to: "agent:overrule", when: [state: [:stored]])
    create(ask: [:title, :n, :tool, :state, :detail, :made, :values, :was])
  end

  relation(:in_request,
    label: "in request",
    description: "A step belongs to the request whose plan it was part of.",
    from: [:agent_step],
    to: [:agent_request],
    max_outgoing: 1,
    inverse: {:steps, "steps"},
    parent: true,
    add: false
  )
end
