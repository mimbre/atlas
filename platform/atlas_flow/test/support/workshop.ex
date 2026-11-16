defmodule AtlasFlow.Workshop.Things do
  @moduledoc "A workshop: widgets, made of parts, each tended by a maker."
  use RelaDSL

  entity :maker, label: "Maker", plural: "makers", id_type: :manual do
    field(:name, :string)
  end

  entity :widget, label: "Widget", plural: "widgets", id_type: :manual do
    field(:title, :string)
    field(:todo, :string)
    field(:state, :string)
  end

  entity :part, label: "Part", plural: "parts", id_type: :manual do
    field(:title, :string)
  end

  relation(:of_widget,
    label: "of widget",
    from: [:part],
    to: [:widget],
    max_outgoing: 1,
    parent: true
  )

  relation(:tended_by, label: "tended by", from: [:widget], to: [:maker], max_outgoing: 1)

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

  subflow :tend, label: "Tend", subject: :widget do
    owner(relation: :tended_by, default: {:maker, :mia})
    start(:create)
    initial(:open)

    state :open, label: "Tend it" do
      branch(to: :done, when: "entity.state == 'done'")
      present(expected: "Tend it", why: "it is open")
    end

    final(:done, label: "Done")
  end

  select(:tend,
    choices: [],
    projection: [field: :todo, owner_relation: :tended_by],
    admission: [],
    imports: []
  )
end

defmodule AtlasFlow.Workshop.Module do
  @moduledoc "The workshop's one module."
  use RelaDSL.Module, path: "modules/things/schema.yaml", concepts: [AtlasFlow.Workshop.Things]
end

defmodule AtlasFlow.Workshop do
  @moduledoc """
  A second neutral model for Flow's tests, with the kinds the freshness design names
  (docs/design/page-freshness.md): its subflow `tend` hands an open widget to the maker
  mia, until the widget is done.
  """
  use RelaDSL.Composition,
    name: "workshop",
    subflow_behaviour: AtlasFlow.Subflow

  @behaviour AtlasFlow.Model

  schema(
    version: "1.0",
    namespace: "https://example.invalid/workshop#",
    description: "A workshop.\n"
  )

  modules([AtlasFlow.Workshop.Module])
  environments([:prod, :test])

  defcomposition :workshop do
    subflows([AtlasFlow.Workshop.Things])
  end

  @doc "What Facts describes for it: its kinds and relations, as rela serves them."
  def description do
    %{
      "entities" => %{
        "widget" => %{"plural" => "widgets"},
        "part" => %{"plural" => "parts"},
        "maker" => %{"plural" => "makers"}
      },
      "relations" => %{
        "of_widget" => %{"from" => ["part"], "to" => ["widget"], "max_outgoing" => 1},
        "tended_by" => %{"from" => ["widget"], "to" => ["maker"], "max_outgoing" => 1}
      }
    }
  end
end
