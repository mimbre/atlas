defmodule Model.Agent do
  @moduledoc "An agent that works with Atlas."
  use RelaDSL

  entity :agent,
    label: "Agent",
    plural: "agents",
    id_type: :manual,
    description: """
    An agent that works with Atlas. The id is short and lower case, made from the
    name, e.g. coordinator.
    """ do
    field(:name, :string, required: true, description: "As it is shown")

    field(:cannot_run, :string,
      description:
        "Where and since when it cannot run, and why (3 crashes in 10 minutes); Runtime writes and clears it (IS-Atlas-18)",
      set_by: [:runtime],
      label: "Cannot run"
    )

    top(false)
    counts(relation: :assigned_to, text: "{count} assigned")
    primary(:name)

    create(
      ask: [:name],
      id: [
        from: :name,
        pattern: "^\\s*([A-Za-z][A-Za-z0-9]*)",
        template: "{1}",
        lower: true,
        error: "name must start with a letter, e.g. Coordinator"
      ]
    )
  end
end
