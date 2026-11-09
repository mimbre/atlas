defmodule AtlasFlow.Depot.Clerk do
  @moduledoc "Who works in the depot: a clerk owns a box, signs it off, or runs on a desk."
  use RelaDSL

  entity :clerk, label: "Clerk", plural: "clerks", id_type: :manual do
    field(:name, :string)
    field(:node, :string)
  end
end

defmodule AtlasFlow.Depot.Box do
  @moduledoc """
  A box: crates go in it, a clerk packs it and another checks it. Its subflow sorts it,
  and its runs are selected while it is in its first phase.
  """
  use RelaDSL

  type(:box_stage, values: [:packing, :check], labels: [packing: "Packing", check: "Check"])

  entity :box, label: "Box", plural: "boxes", id_type: :manual do
    field(:phase, :string)
    field(:result, :string)
    field(:mark, :string)
    field(:choice, :string)
    field(:todo, :string)
    field(:due, :string)
    field(:stage, :box_stage)
    field(:step, :string)
    field(:later, :string)
  end

  relation(:owned_by, label: "owned by", from: [:box], to: [:clerk], max_outgoing: 1)
  relation(:signed_by, label: "signed by", from: [:box], to: [:clerk], max_outgoing: 1)
  relation(:chosen_by, label: "chosen by", from: [:box], to: [:clerk], max_outgoing: 1)

  subflow :sort, label: "Sort", subject: :box do
    run_as("system:depot")
    owner(default: {:clerk, :ada})
    start(:create)
    initial(:waiting)

    state :waiting, label: "Sort it" do
      set(mark: "entered")
      branch(to: :done, when: "entity.result == 'ok'")
      branch(to: :discarded, when: "entity.result == 'no'")
      wait_for([:clerk], on: :choice, reset: false, yes: :done)
      timer(:retry, "5m", to: :waiting)
      present(expected: "Sort it")
    end

    final(:done, label: "Done")
    final(:discarded, label: "Discarded")
  end

  select(:sort,
    choices: [:choice],
    roles: [clerk: :chosen_by],
    projection: [field: :todo, owner_relation: :owned_by],
    admission: [phase: [:first]],
    imports: [
      [when: [result: [:ok, :old]], state: :done],
      [when: [result: [:no]], state: :discarded]
    ]
  )
end

defmodule AtlasFlow.Depot.Crate do
  @moduledoc "What goes in a box."
  use RelaDSL

  entity :crate, label: "Crate", plural: "crates", id_type: :manual do
    field(:label, :string)
  end

  relation(:in_box, label: "in box", from: [:crate], to: [:box], max_outgoing: 1, parent: true)
end

defmodule AtlasFlow.Depot.Ledger do
  @moduledoc "The runs of the depot's subflows (cursors) and the choices that move them."
  use RelaDSL

  entity :cursor, label: "Cursor", plural: "cursors", id_type: :manual do
    for f <- ~w(flow subject_kind subject_key definition_sha256 state entered_at status
                deadlines pending last_input blocked_reason)a,
        do: field(f, :string)

    for f <- ~w(generation entry input_cursor)a, do: field(f, :integer)
  end

  entity :choice, label: "Choice", plural: "choices", id_type: :manual do
    field(:run, :string)
    field(:actor, :string)
  end

  flow_runtime(runs: :cursor, writer: [sender: :flow, by: :flow], inputs: :choice)
end

defmodule AtlasFlow.Depot.Goods do
  @moduledoc "The depot's one module."
  use RelaDSL.Module,
    path: "modules/goods/schema.yaml",
    concepts: [
      AtlasFlow.Depot.Clerk,
      AtlasFlow.Depot.Box,
      AtlasFlow.Depot.Crate,
      AtlasFlow.Depot.Ledger
    ]

  progress_order(order: [:packing, :check], done_label: "Done")
end
