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
  the Runtime writer.

  Its install (IS-Atlas-116, UC-Atlas-50): its supervisor makes it through Control
  (`atlas runtime install`), which names the machine, links the supervisor (`runs_for`)
  and keeps the sha256 of the Runtime's work source credential (`credential_sha256`),
  never the credential itself. Flow's work source and Code's Git endpoint admit a
  Runtime whose bearer token hashes to it, as the Runtime of this machinery working for
  that supervisor, next to the credentials of the core secret: a new Runtime needs no
  core secret and no restart. Clearing `credential_sha256` (or deleting the machinery)
  turns the credential away within the cache time of the listeners (10 s). Flow records
  the build and incarnation each poll reports (`runtime_build`, `runtime_incarnation`),
  so Control shows the Runtime linked, and `applied_version` shows the configuration it
  runs under.

  Its Runtime's configuration (IS-Atlas-27): a person sets `configuration` through
  Control (the Console or `atlas set`), the whole `policy.json` of the Runtime; Flow's
  work source serves it to the Runtime whose id is this fact's key, and writes back what
  the Runtime did with it (`applied_version`, `refused_version`, `refused_reason`). So a
  machinery is changed by hand, never made or deleted by hand.

  Its Runtime's upgrades (IS-Atlas-26) are `runtime_upgrade` facts under it
  (`Model.RuntimeUpgrade`): its supervisor makes one naming a released build, and Flow's
  work source drains, updates, restarts and verifies the Runtime.
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
      description: "As it is shown; its machine name, which its id is made from"
    )

    field(:credential_sha256, :string,
      description:
        "The sha256 (64 lowercase hex) of the bearer token its Runtime is admitted with by " <>
          "Flow's work source and Code's Git endpoint; never the token. `atlas runtime install` " <>
          "sets it. Empty: no credential of this machinery is admitted"
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

    field(:runtime_build, :string,
      description: "The build its Runtime runs, as its last poll said: it is linked",
      set_by: [:flow]
    )

    field(:runtime_incarnation, :string,
      description:
        "The incarnation of its Runtime, as its last poll said; a restart makes a new one",
      set_by: [:flow]
    )

    top(false)
    primary(:name)

    create(
      ask: [:name, :credential_sha256],
      id: [
        from: :name,
        pattern: "^\\s*([A-Za-z][A-Za-z0-9-]*)",
        template: "{1}",
        lower: true,
        error: "name must start with a letter, then letters, digits or -, e.g. mac-mini"
      ]
    )
  end

  # Whose work its Runtime takes: the credential's holder (decision 2026-11-17 §5.6), as
  # Flow's work source admits it. Set when the machinery is made (`atlas runtime install`).
  relation(:runs_for,
    label: "runs for",
    description:
      "The supervisor whose work the machinery's Runtime takes: its credential's holder.",
    from: [:machinery],
    to: [:person],
    max_outgoing: 1,
    inverse: {:machineries, "machineries"}
  )
end
