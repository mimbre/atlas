defmodule AtlasRuntime.TestModel.Clerk do
  @moduledoc "Who works: a clerk, who may be stuck on a machine."
  use RelaDSL

  entity :clerk, label: "Clerk", plural: "clerks", id_type: :manual do
    field(:stuck, :string, set_by: [:runtime])
    top(false)
  end
end

defmodule AtlasRuntime.TestModel.Box do
  @moduledoc "A box, and its card: who packs it and how far it is."
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
    from: [:card],
    to: [:clerk],
    max_outgoing: 1,
    inverse: {:owns, "owns"}
  )
end

defmodule AtlasRuntime.TestModel.Run do
  @moduledoc "A run: a clerk's turn on a card."
  use RelaDSL

  type(:run_status, values: [:going, :over])

  entity :run, label: "Run", plural: "runs", id_type: :manual do
    field(:status, :run_status)
    field(:host, :string)
    field(:until, :string)
    field(:last, :string)
    field(:reason, :string)
    field(:done_at, :string)
    field(:result, :string)
    top(false)
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
      outcome: :result
    ],
    agent: [cannot_run: :stuck]
  )
end

defmodule AtlasRuntime.TestModel.Packing do
  @moduledoc "The module: everything of the packing room."
  use RelaDSL.Module,
    path: "modules/packing/schema.yaml",
    concepts: [
      AtlasRuntime.TestModel.Clerk,
      AtlasRuntime.TestModel.Box,
      AtlasRuntime.TestModel.Run
    ]
end

defmodule AtlasRuntime.TestModel do
  @moduledoc """
  A neutral model for Runtime's tests (`AtlasRuntime.FakeFacts` holds its facts): a clerk
  packs a box through its card, and a run is a turn. Its kinds are made up on purpose.
  """
  use RelaDSL.Composition, name: "packing"

  @behaviour AtlasRuntime.Model

  schema(version: "1.0", namespace: "https://example.invalid/packing#", comment: "Packing.")
  modules([AtlasRuntime.TestModel.Packing])

  legacy_flow(:pack,
    on: :card,
    kinds: [:box],
    field: :todo,
    state_field: :step,
    handover_field: :later,
    owner_relation: :owned_by,
    states: [
      [name: :packed, when: [values: [phase: ["packed"]]], done: true],
      [
        name: :checking,
        when: [values: [phase: ["check"]]],
        owner: [kind: :clerk, key: "bob"],
        expected: "Check it",
        next: [:packing]
      ],
      [name: :packing, owner: [kind: :clerk, key: "ada"], expected: "Pack it", next: [:packed]]
    ]
  )

  defcomposition :packing do
    subflows([])
  end
end

defmodule AtlasRuntime.TestModel.GuidedRun do
  @moduledoc "A run whose every attempt is fenced, and the durable guidance records of it."
  use RelaDSL

  @slots %{
    execution:
      ~w(environment worker turn attempt machine harness harness_version configured_model reported_model capability_version queued_input durable_accept_query consumption_evidence recorded_at recorded_position)a,
    interaction:
      ~w(environment actor client_key body body_digest worker turn attempt mode execution cause recorded_at recorded_position)a,
    receipt:
      ~w(environment interaction worker turn attempt execution stage evidence_id admission_id consumption_id reason writer cause recorded_at recorded_position)a
  }

  @typed %{
    queued_input: :boolean,
    durable_accept_query: :boolean,
    consumption_evidence: :boolean,
    recorded_position: :integer
  }

  type(:run_status, values: [:going, :over])

  entity :run, label: "Run", plural: "runs", id_type: :manual do
    field(:status, :run_status)
    field(:host, :string)
    field(:fence, :string)
    field(:until, :string)
    field(:last, :string)
    field(:reason, :string)
    field(:done_at, :string)
    field(:result, :string)
    top(false)
  end

  for {role, slots} <- @slots do
    entity :"synthetic_#{role}", label: "#{role}", plural: "#{role}s", id_type: :manual do
      for slot <- slots, do: field(:"slot_#{slot}", Map.get(@typed, slot, :string))
      top(false)
      by_hand(false)
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
      attempt: :fence
    ],
    agent: [cannot_run: :stuck]
  )

  guidance(
    for {role, slots} <- @slots do
      {role, [kind: :"synthetic_#{role}", fields: for(s <- slots, do: {s, :"slot_#{s}"})]}
    end
  )
end

defmodule AtlasRuntime.TestModel.GuidedPacking do
  @moduledoc "The module of the guided packing room."
  use RelaDSL.Module,
    path: "modules/guided/schema.yaml",
    concepts: [
      AtlasRuntime.TestModel.Clerk,
      AtlasRuntime.TestModel.Box,
      AtlasRuntime.TestModel.GuidedRun
    ]
end

defmodule AtlasRuntime.TestModel.Guided do
  @moduledoc """
  The neutral model with guidance: as `AtlasRuntime.TestModel`, but each run's attempt is
  fenced and its executions, interactions and receipts are kept as facts.
  """
  use RelaDSL.Composition, name: "guided-packing"

  @behaviour AtlasRuntime.Model

  schema(version: "1.0", namespace: "https://example.invalid/guided#", comment: "Guided.")
  modules([AtlasRuntime.TestModel.GuidedPacking])

  legacy_flow(:pack,
    on: :card,
    kinds: [:box],
    field: :todo,
    state_field: :step,
    handover_field: :later,
    owner_relation: :owned_by,
    states: [
      [name: :packed, when: [values: [phase: ["packed"]]], done: true],
      [name: :packing, owner: [kind: :clerk, key: "ada"], expected: "Pack it", next: [:packed]]
    ]
  )

  defcomposition :guided do
    subflows([])
  end
end
