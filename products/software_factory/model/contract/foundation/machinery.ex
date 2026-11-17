defmodule Model.Machinery do
  @moduledoc """
  A machinery assignee: one Runtime backend that Flow hands tasks to (the Flow Engine
  plan, §3.1). An Assignment may be assigned to it (`assigned_to`), next to a person or
  an agent. Its address and token are in Flow's configuration, never in Facts.

  The name is not `runtime`, so it is not mistaken for the `set_by` role `:runtime`,
  the Runtime writer. Flow writes it (`set_by: [:flow]`).
  """
  use RelaDSL

  entity :machinery,
    label: "Machinery",
    plural: "machineries",
    id_type: :manual,
    description: """
    A machinery assignee: one Runtime backend Flow hands tasks to. The id is short and
    lower case, its name in Flow's configuration, e.g. mac-mini.
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
