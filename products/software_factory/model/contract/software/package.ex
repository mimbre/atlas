defmodule Model.Package do
  @moduledoc """
  A bounded part of an issue that becomes one pull request (the Flow Engine plan, §3.1
  and §3.2). It comes from an Architect's plan or is made by hand; Flow names it
  `PK-<issue>-<n>`. It is a child of its issue (`package_of`), and its tasks belong to it
  (`task_of`, in the composition).

  The kind only: its subflow comes with F1.4, and `published_revision` and
  `published_fingerprint` with F3. Flow writes every field (`set_by: [:flow]`).

  It is not a pull request: `in_issue` stays the pull request's relation alone, whose
  limit and the issue's completion read a pull request's `state`.
  """
  use RelaDSL

  entity :package,
    label: "Package",
    plural: "packages",
    id_type: :manual,
    id_prefix: "PK-",
    description: """
    A bounded part of an issue that becomes one pull request: from an Architect's plan
    or made by hand. Flow names it PK-<issue>-<n>.
    """ do
    field(:title, :string, required: true, description: "What it builds", set_by: [:flow])

    field(:instructions, :string,
      description: "What its author is to do",
      set_by: [:flow],
      multiline: true
    )

    field(:acceptance, :string,
      description: "When it is done",
      set_by: [:flow],
      multiline: true
    )

    field(:after, :string,
      description: "The keys of the packages it waits for, integrated first",
      set_by: [:flow]
    )

    field(:state, :string, description: "The state of its run, as Flow keeps it", set_by: [:flow])

    top(false)
    by_hand(false)
    primary(:title)
  end

  relation(:package_of,
    label: "package of",
    description: "A package belongs to one issue; an issue has its packages.",
    from: [:package],
    to: [:issue],
    max_outgoing: 1,
    inverse: {:packages, "packages"},
    parent: true,
    set_by: [:flow]
  )
end
