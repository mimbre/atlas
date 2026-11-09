defmodule RelaDSL.Workshop.Clerk do
  @moduledoc "A neutral concept: who works on cards."
  use RelaDSL

  entity :clerk, label: "Clerk", plural: "clerks", id_type: :manual do
    field(:name, :string)
    field(:stuck, :string, set_by: [:runtime])
    top(false)
  end
end

defmodule RelaDSL.Workshop.Box do
  @moduledoc "A neutral concept: a box and the card that says who packs it."
  use RelaDSL

  entity :box, label: "Box", plural: "boxes", id_type: :manual do
    field(:phase, :string)
  end

  entity :card, label: "Card", plural: "cards", id_type: :manual do
    field(:todo, :string, set_by: [:flow])
    field(:step, :string)
    field(:later, :string)
    top(false)
  end

  entity :crate, label: "Crate", plural: "crates", id_type: :manual do
    field(:full, :string)
    field(:todo, :string, set_by: [:flow])
    field(:step, :string)
    field(:later, :string)
  end

  relation(:card,
    label: "card",
    description: "The card of a box.",
    from: [:box],
    to: [:card],
    max_outgoing: 1,
    inverse: {:card_of, "card of"}
  )

  relation(:owned_by,
    label: "owned by",
    description: "Who packs it.",
    from: [:card, :crate],
    to: [:clerk],
    max_outgoing: 1,
    inverse: {:owns, "owns"}
  )

  entity :job, label: "Job", plural: "jobs", id_type: :manual do
    field(:flow, :string)
    field(:state, :string)
    top(false)
    by_hand(false)
  end

  flow_runtime(runs: :job, writer: [sender: :flow, by: :flow])

  # A box is packed through its card; a crate is stacked on itself.
  subflow :pack, label: "Pack", subject: :box do
    owner via: :card, relation: :owned_by, default: {:clerk, :ada}
    start :create
    initial :packing

    state :packing, label: "Pack it" do
      present(expected: "Pack it")
      branch to: :packed, when: "entity.phase == 'packed'"
    end

    final :packed, label: "Packed"
  end

  subflow :stack, label: "Stack", subject: :crate do
    owner relation: :owned_by, default: {:clerk, :bob}
    start :create
    initial :stacking

    state :stacking, label: "Stack it" do
      present(expected: "Stack it")
      branch to: :stacked, when: "entity.full == 'yes'"
    end

    final :stacked, label: "Stacked"
  end

  select(:pack,
    choices: [],
    projection: [
      on: :card,
      field: :todo,
      state_field: :step,
      handover_field: :later,
      owner_relation: :owned_by
    ],
    admission: [],
    imports: []
  )

  select(:stack,
    choices: [],
    projection: [
      field: :todo,
      state_field: :step,
      handover_field: :later,
      owner_relation: :owned_by
    ],
    admission: [],
    imports: []
  )
end

defmodule RelaDSL.Workshop.Run do
  @moduledoc "A neutral concept: a clerk's turn on a card, and its durable records."
  use RelaDSL

  @slots %{
    log:
      ~w(environment worker turn attempt machine harness harness_version configured_model reported_model capability_version queued_input durable_accept_query consumption_evidence recorded_at recorded_position)a,
    note:
      ~w(environment actor client_key body body_digest worker turn attempt mode execution cause recorded_at recorded_position)a,
    stamp:
      ~w(environment interaction worker turn attempt execution stage evidence_id admission_id consumption_id reason writer cause recorded_at recorded_position)a
  }

  type(:run_status, values: [:going, :over])

  entity :run, label: "Run", plural: "runs", id_type: :manual do
    field(:status, :run_status)
    field(:host, :string)
    field(:until, :string)
    field(:last, :string)
    field(:reason, :string)
    field(:done_at, :string)
    field(:result, :string)
    field(:try, :string)
    field(:about, :string)
    field(:engine, :string)
    top(false)
  end

  for {kind, fields} <- @slots do
    entity kind, label: to_string(kind), plural: "#{kind}s", id_type: :manual do
      for f <- fields, do: field(f, :string)
      top(false)
    end
  end

  relation(:run_on,
    label: "on",
    description: "The card it is on.",
    from: [:run],
    to: [:card],
    max_outgoing: 1,
    inverse: {:runs, "runs"}
  )

  relation(:run_by,
    label: "by",
    description: "The clerk in it.",
    from: [:run],
    to: [:clerk],
    max_outgoing: 1,
    inverse: {:runs_by, "runs"}
  )

  runtime(
    turn: [
      kind: :run,
      key: "R-{on}-{n}",
      on: :run_on,
      by: :run_by,
      state: :status,
      running: :going,
      ended: :over,
      machine: :host,
      lease: :until,
      activity: :last,
      why: :reason,
      ended_at: :done_at,
      outcome: :result,
      attempt: :try,
      title: :about,
      model: :engine
    ],
    agent: [cannot_run: :stuck]
  )

  guidance(
    execution: [kind: :log, fields: for(f <- @slots.log, do: {f, f})],
    interaction: [kind: :note, fields: for(f <- @slots.note, do: {f, f})],
    receipt: [kind: :stamp, fields: for(f <- @slots.stamp, do: {f, f})]
  )
end

defmodule RelaDSL.Workshop.Memo do
  @moduledoc "A neutral concept: the memos a box rests on; one elaborates another."
  use RelaDSL

  type(:memo_sort, values: [:direction, :habit, :limit, :pledge])

  type(:memo_status,
    values: [:proposed, :kept, :replaced, :dropped],
    labels: [proposed: "Proposed", kept: "Kept", replaced: "Replaced", dropped: "Dropped"]
  )

  entity :memo, label: "Memo", plural: "memos", id_type: :manual do
    field(:title, :string)
    field(:rule, :string)
    field(:sort, :memo_sort)
    field(:status, :memo_status)
    primary(:title)
  end

  relation(:rests_on,
    label: "rests on",
    description: "The memos a box carries out.",
    from: [:box],
    to: [:memo],
    inverse: {:carried_by, "carried by"}
  )

  relation(:elaborates,
    label: "elaborates",
    description: "The memo this one works out.",
    from: [:memo],
    to: [:memo],
    inverse: {:elaborated_by, "elaborated by"}
  )
end

defmodule RelaDSL.Workshop.Shop do
  @moduledoc "The neutral module: everything of the workshop."
  use RelaDSL.Module,
    path: "modules/shop/schema.yaml",
    concepts: [
      RelaDSL.Workshop.Clerk,
      RelaDSL.Workshop.Box,
      RelaDSL.Workshop.Run,
      RelaDSL.Workshop.Memo
    ]
end

defmodule RelaDSL.Workshop do
  @moduledoc """
  A neutral composition for what Runtime is given: a clerk packs a box through its card
  (a selected subflow), and crates directly; a run is a turn; a box rests on memos.
  """
  use RelaDSL.Composition, name: "workshop"

  schema(
    version: "1.0",
    namespace: "https://example.invalid/workshop#",
    description: "The workshop.\n",
    comment: "The workshop."
  )

  modules([RelaDSL.Workshop.Shop])

  read_first(
    title: "Read these memos first.",
    through: :rests_on,
    then: :elaborates,
    standing: [
      [title: "Pledges", first: true, when: [status: [:kept], sort: [:pledge]]],
      [title: "Habits and limits that hold", when: [status: [:kept], sort: [:habit, :limit]]]
    ],
    tags: [:sort, :status],
    text: :rule
  )

  defcomposition :workshop do
    subflows([RelaDSL.Workshop.Box])
  end
end

defmodule RelaDSL.Workshop.Bench do
  @moduledoc "A module with one plain kind."
  use RelaDSL.Module, path: "modules/bench/schema.yaml", concepts: [RelaDSL.Workshop.Clerk]
end

defmodule RelaDSL.Workshop.Bare do
  @moduledoc "A neutral composition that runs no turns and reads nothing first."
  use RelaDSL.Composition, name: "bare"

  schema(version: "1.0", namespace: "https://example.invalid/bare#", comment: "Bare.")
  modules([RelaDSL.Workshop.Bench])

  defcomposition :bare do
    subflows([])
  end
end
