defmodule AtlasFlow.Yard.Basket do
  @moduledoc "A basket waits for the outcome of its tray, which waits for its cup."
  use RelaDSL

  entity :basket, label: "Basket", plural: "baskets", id_type: :manual do
    field(:phase, :string)
    field(:revision, :string)
    field(:outcome, :string)
  end

  relation(:in_basket,
    label: "in basket",
    from: [:tray],
    to: [:basket],
    max_outgoing: 1,
    parent: true
  )

  subflow :pack, label: "Pack", subject: :basket do
    run_as("system:yard")
    owner(default: {:hand, :ada})
    start(:create)
    initial(:waiting)

    state :waiting do
      await(:outcome, full: :packed, spilt: :spilt)
    end

    final(:packed)
    final(:spilt)
  end

  select(:pack, choices: [], admission: [phase: [:first]], imports: [])
end

defmodule AtlasFlow.Yard.NestedStock do
  use RelaDSL.Module,
    path: "modules/stock/schema.yaml",
    concepts: [
      AtlasFlow.Yard.Hand,
      AtlasFlow.Yard.Tray,
      AtlasFlow.Yard.Cup,
      AtlasFlow.Yard.Ledger,
      AtlasFlow.Yard.Basket
    ]
end

defmodule AtlasFlow.Yard.Nested do
  @moduledoc "The yard's nested composition, with two durable links to carry an outcome."
  use RelaDSL.Composition, name: "nestedyard", subflow_behaviour: AtlasFlow.Subflow
  @behaviour AtlasFlow.Model

  schema(
    version: "1.0",
    namespace: "https://example.invalid/nested-yard#",
    description: "A yard.\n"
  )

  modules([AtlasFlow.Yard.NestedStock])
  environments([:prod, :test])

  acl(comment: "The yard's roles.")
  role("yard", read: ["*"], create: [:cursor], update: [:basket, :tray, :cup, :cursor])
  role("hand", read: ["*"], update: [:basket, :tray, :cup])
  assign("system:yard", "yard")

  defcomposition :nestedyard do
    subflows([AtlasFlow.Yard.Tray, AtlasFlow.Yard.Cup, AtlasFlow.Yard.Basket])

    link(:pour,
      to: {:tray, :on_tray},
      field: :outcome,
      states: [full: :full, spilt: :spilt],
      stale: :drop,
      current: {:revision, :revision}
    )

    count(:pour, to: {:tray, :on_tray}, all: :cups, open: :open_cups)

    link(:fill,
      to: {:basket, :in_basket},
      field: :outcome,
      states: [filled: :full, spilt: :spilt],
      stale: :drop,
      current: {:revision, :revision}
    )
  end
end
