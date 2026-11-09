defmodule AtlasFlow.Shelf.Stock do
  @moduledoc """
  A shelf, and the jars and tins on it. The shelf's subflow `stock` waits until something
  stands on it: the composition tallies whatever relates to it by `on_shelf`, of either
  kind, whether a subflow runs on it or not (`items`). A second subflow on the shelf,
  `dust`, reads no tally: it is never given one.
  """
  use RelaDSL

  entity :shelf, label: "Shelf", plural: "shelves", id_type: :manual do
    field(:items, :integer)
    field(:dusted, :string)
  end

  entity :jar, label: "Jar", plural: "jars", id_type: :manual do
    field(:label, :string)
  end

  entity :tin, label: "Tin", plural: "tins", id_type: :manual do
    field(:label, :string)
  end

  relation(:on_shelf, label: "on shelf", from: [:jar, :tin], to: [:shelf])

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

  subflow :stock, label: "Stock", subject: :shelf do
    owner(default: {:shelf, :keeper})
    start(:create)
    initial(:empty)

    state :empty, label: "Fill it" do
      branch(to: :stocked, when: "entity.items > 0")
    end

    final(:stocked, label: "Stocked")
  end

  subflow :dust, label: "Dust", subject: :shelf do
    owner(default: {:shelf, :keeper})
    start(:predicate, when: "entity.dusted == 'no'")
    initial(:dusty)

    state :dusty, label: "Dust it" do
      branch(to: :clean, when: "entity.dusted == 'yes'")
    end

    final(:clean, label: "Clean")
  end

  select(:stock, choices: [], admission: [], imports: [])
  select(:dust, choices: [], admission: [], imports: [])
end

defmodule AtlasFlow.Shelf.Module do
  @moduledoc "The shelf's one module."
  use RelaDSL.Module, path: "modules/shelf/schema.yaml", concepts: [AtlasFlow.Shelf.Stock]
end

defmodule AtlasFlow.Shelf do
  @moduledoc "A neutral model with a tally: a shelf counts what stands on it."
  use RelaDSL.Composition, name: "shelf", subflow_behaviour: AtlasFlow.Subflow

  @behaviour AtlasFlow.Model

  schema(version: "1.0", namespace: "https://example.invalid/shelf#", description: "A shelf.\n")
  modules([AtlasFlow.Shelf.Module])
  environments([:prod, :test])

  defcomposition :shelf do
    subflows([AtlasFlow.Shelf.Stock])
    tally(to: {:shelf, :on_shelf}, all: :items)
  end
end
