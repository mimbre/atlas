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

    top(false)
    by_hand(false)
    primary(:name)
  end
end
