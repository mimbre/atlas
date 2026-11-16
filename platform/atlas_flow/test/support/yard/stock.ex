defmodule AtlasFlow.Yard.Hand do
  @moduledoc "Who works in the yard."
  use RelaDSL

  entity :hand, label: "Hand", plural: "hands", id_type: :manual do
    field(:name, :string)
  end
end

defmodule AtlasFlow.Yard.Tray do
  @moduledoc "A tray: its cups' outcome comes back to it, and it counts them."
  use RelaDSL

  entity :tray, label: "Tray", plural: "trays", id_type: :manual do
    field(:phase, :string)
    field(:revision, :string)
    field(:outcome, :string)
    field(:cups, :integer)
    field(:open_cups, :integer)
    field(:verdict, :string)
  end

  subflow :fill, label: "Fill", subject: :tray do
    run_as("system:yard")
    owner(default: {:hand, :ada})
    start(:create)
    initial(:waiting)

    state :waiting, label: "Waiting for its cup" do
      await(:outcome, full: :filled, spilt: :spilt)
      wait_for([:hand], on: :verdict, reset: false, keep: :filled)
    end

    final(:filled, label: "Filled")
    final(:spilt, label: "Spilt")
  end

  subflow :tally, label: "Tally", subject: :tray do
    run_as("system:yard")
    owner(default: {:hand, :ada})
    start(:predicate, when: "entity.cups > 0")
    initial(:counting)

    state :counting, label: "Counting its cups" do
      branch(to: :counted, by: :atlas, when: "entity.open_cups == 0 and entity.cups > 0")
      wait_for([:hand], on: :verdict, reset: false, keep: :counted)
    end

    final(:counted, label: "Counted")
  end

  select(:fill, choices: [:verdict], admission: [phase: [:first]], imports: [])
  select(:tally, choices: [:verdict], admission: [phase: [:first]], imports: [])
end

defmodule AtlasFlow.Yard.Cup do
  @moduledoc "A cup, poured for one revision of its tray."
  use RelaDSL

  entity :cup, label: "Cup", plural: "cups", id_type: :manual do
    field(:phase, :string)
    field(:revision, :string)
    field(:level, :string)
    field(:verdict, :string)
  end

  relation(:on_tray, label: "on tray", from: [:cup], to: [:tray], max_outgoing: 1, parent: true)

  subflow :pour, label: "Pour", subject: :cup do
    run_as("system:yard")
    owner(default: {:hand, :ada})
    start(:create)
    initial(:pouring)

    state :pouring, label: "Pouring" do
      branch(to: :full, when: "entity.level == 'full'")
      branch(to: :spilt, when: "entity.level == 'spilt'")
      wait_for([:hand], on: :verdict, reset: false, keep: :full)
    end

    final(:full, label: "Full")
    final(:spilt, label: "Spilt")
  end

  select(:pour, choices: [:verdict], admission: [phase: [:first]], imports: [])
end

defmodule AtlasFlow.Yard.Ledger do
  @moduledoc "The runs of the yard's subflows (cursors) and the choices that move them."
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

defmodule AtlasFlow.Yard.Stock do
  @moduledoc "The yard's one module."
  use RelaDSL.Module,
    path: "modules/stock/schema.yaml",
    concepts: [
      AtlasFlow.Yard.Hand,
      AtlasFlow.Yard.Tray,
      AtlasFlow.Yard.Cup,
      AtlasFlow.Yard.Ledger
    ]
end
