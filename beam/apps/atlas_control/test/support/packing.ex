defmodule AtlasControl.Packing.Clerk do
  @moduledoc "Who packs: a clerk, its id its name; and who reads worker pages."
  use RelaDSL

  entity :clerk, label: "Clerk", plural: "clerks", id_type: :manual do
    field(:name, :string)
    field(:stuck, :string, set_by: [:runtime])
    top(false)
  end

  entity :reader, label: "Reader", plural: "readers", id_type: :manual, id_prefix: "H-" do
    field(:name, :string)
    top(false)
  end
end

defmodule AtlasControl.Packing.Box do
  @moduledoc "A box and its card: the card says who packs it and how far it is."
  use RelaDSL

  entity :box, label: "Box", plural: "boxes", id_type: :manual, id_prefix: "B-" do
    field(:title, :string)
    field(:phase, :string)
    primary(:title)
  end

  entity :card, label: "Card", plural: "cards", id_type: :manual, id_prefix: "C-" do
    field(:of, :string)
    field(:todo, :string, set_by: [:flow])
    field(:step, :string)
    field(:later, :string)
    top(false)
  end

  relation(:card,
    label: "card",
    from: [:box],
    to: [:card],
    max_outgoing: 1,
    set_by: [:migration],
    component: [key: "C-{key}", values: [of: "{key}"]]
  )

  relation(:holder, label: "held by", from: [:card], to: [:clerk], max_outgoing: 1)
end

defmodule AtlasControl.Packing.Run do
  @moduledoc "A run: a clerk's turn on a card, and the durable guidance records."
  use RelaDSL

  @slots %{
    trace:
      ~w(environment worker turn attempt machine harness harness_version configured_model reported_model capability_version queued_input durable_accept_query consumption_evidence recorded_at recorded_position)a,
    memo_note:
      ~w(environment actor client_key body body_digest worker turn attempt mode execution cause recorded_at recorded_position)a,
    stamp:
      ~w(environment interaction worker turn attempt execution stage evidence_id admission_id consumption_id reason writer cause recorded_at recorded_position)a
  }

  type(:run_status, values: [:going, :over], labels: [going: "Going", over: "Over"])

  entity :run, label: "Run", plural: "runs", id_type: :manual, id_prefix: "R-" do
    field(:status, :run_status)
    field(:host, :string)
    field(:until, :string)
    field(:last, :string)
    field(:reason, :string)
    field(:done_at, :string)
    field(:result, :string)
    field(:try, :string)
    top(false)
    by_hand(false)
  end

  for {kind, fields} <- @slots do
    entity kind, label: to_string(kind), plural: "#{kind}s", id_type: :manual do
      for f <- fields, do: field(f, :string)
      top(false)
      by_hand(false)
    end
  end

  relation(:work, label: "on", from: [:run], to: [:card], max_outgoing: 1)
  relation(:worker, label: "by", from: [:run], to: [:clerk], max_outgoing: 1)

  runtime(
    turn: [
      kind: :run,
      key: "R-{on}-{n}",
      on: :work,
      by: :worker,
      state: :status,
      running: :going,
      ended: :over,
      machine: :host,
      lease: :until,
      activity: :last,
      why: :reason,
      ended_at: :done_at,
      outcome: :result,
      attempt: :try
    ],
    agent: [cannot_run: :stuck]
  )

  guidance(
    execution: [kind: :trace, fields: for(f <- @slots.trace, do: {f, f})],
    interaction: [kind: :memo_note, fields: for(f <- @slots.memo_note, do: {f, f})],
    receipt: [kind: :stamp, fields: for(f <- @slots.stamp, do: {f, f})]
  )
end

defmodule AtlasControl.Packing.Memo do
  @moduledoc "The memos a box rests on."
  use RelaDSL

  entity :memo, label: "Memo", plural: "memos", id_type: :manual, id_prefix: "M-" do
    field(:title, :string)
    field(:rule, :string)
    primary(:title)
  end

  relation(:rests_on, label: "rests on", from: [:box], to: [:memo])
  relation(:elaborates, label: "elaborates", from: [:memo], to: [:memo])
end

defmodule AtlasControl.Packing.Room do
  @moduledoc false
  use RelaDSL.Module,
    path: "modules/packing/schema.yaml",
    concepts: [
      AtlasControl.Packing.Clerk,
      AtlasControl.Packing.Box,
      AtlasControl.Packing.Run,
      AtlasControl.Packing.Memo
    ]
end

defmodule AtlasControl.Packing do
  @moduledoc """
  A neutral model for Control's turn and worker tests: a clerk packs a box through its
  card (a flow on the card, whose holder owns it), a run is the clerk's turn on the card,
  and a box rests on memos a worker reads first. Its kinds are made up on purpose.
  """
  use RelaDSL.Composition, name: "packing"
  @behaviour AtlasControl.Model

  schema(version: "1.0", namespace: "https://example.invalid/packing#", comment: "Packing.")
  modules([AtlasControl.Packing.Room])

  legacy_flow(:pack,
    on: :card,
    kinds: [:box],
    field: :todo,
    state_field: :step,
    handover_field: :later,
    owner_relation: :holder,
    states: [
      [name: :packed, when: [values: [phase: ["packed"]]], done: true],
      [name: :packing, owner: [kind: :clerk, key: "ada"], expected: "Pack it", next: [:packed]]
    ]
  )

  read_first(title: "First:", through: :rests_on, then: :elaborates, text: :rule)

  shell(title: "Private workers", tabs: [[id: "boxes", label: "Boxes", to: "/k/box"]])

  defcomposition :packing do
    subflows([])
  end
end
