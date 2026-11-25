defmodule Model.Machinery do
  @moduledoc """
  A machinery assignee: the Runtimes of the human supervisor of a flow (decision
  2026-11-17 §5.6; first the Flow Engine plan, §3.1). An Assignment may be assigned to
  it (`assigned_to`), next to a person or an agent; that assignment stays the trigger
  for Flow's tasks (E1). Which Runtime does the work is not chosen here: Runtimes pull
  it, and only those whose credential's person is the run's human supervisor
  (`supervised_by`) may; a run without one waits. The credentials (Runtime → person)
  are in Flow's configuration, never in Facts.

  The name is not `runtime`, so it is not mistaken for the `set_by` role `:runtime`,
  the Runtime writer. Flow writes it (`set_by: [:flow]`).

  Its Runtime's configuration (IS-Atlas-27): a person sets `configuration` through
  Control (the Console or `atlas set`), the whole `policy.json` of the Runtime; Flow's
  work source serves it to the Runtime whose id is this fact's key, and writes back what
  the Runtime did with it (`applied_version`, `refused_version`, `refused_reason`). So a
  machinery is changed by hand, never made or deleted by hand.

  Its Runtime's upgrades (IS-Atlas-26) are under it: `Model.RuntimeUpgrade`, one open at a
  time.
  """
  use RelaDSL

  entity :machinery,
    label: "Machinery",
    plural: "machineries",
    id_type: :manual,
    description: """
    A machinery assignee: the Runtimes of a flow's human supervisor, which pull its
    tasks as work. The id is short and lower case, its name in Flow's configuration,
    e.g. mac-mini.
    """ do
    field(:name, :string,
      required: true,
      description: "As it is shown; its name in Flow's configuration",
      set_by: [:flow]
    )

    field(:configuration, :string,
      description:
        "The Runtime's configuration, its whole policy.json as JSON: version (raise it on " <>
          "every change), sources (url, git_url, priority, max_slots), profiles (permissions, " <>
          "cost classes, options), slots. The Runtime applies it within a poll, without a restart",
      multiline: true
    )

    field(:applied_version, :integer,
      description: "The configuration version the Runtime runs under, as its last poll said",
      set_by: [:flow]
    )

    field(:refused_version, :integer,
      description:
        "The last configuration version the Runtime refused (0: Flow could not read its " <>
          "version); it stays on the version it had",
      set_by: [:flow]
    )

    field(:refused_reason, :string,
      description: "Why the Runtime refused refused_version",
      set_by: [:flow]
    )

    top(false)
    by_hand("update")
    primary(:name)
  end
end
