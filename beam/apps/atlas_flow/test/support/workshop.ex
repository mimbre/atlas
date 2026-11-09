defmodule AtlasFlow.Workshop.Things do
  @moduledoc "A workshop: widgets, made of parts, each tended by a maker."
  use RelaDSL

  entity :maker, label: "Maker", plural: "makers", id_type: :manual do
    field(:name, :string)
  end

  entity :widget, label: "Widget", plural: "widgets", id_type: :manual do
    field(:title, :string)
    field(:todo, :string)
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
end

defmodule AtlasFlow.Workshop.Module do
  @moduledoc "The workshop's one module."
  use RelaDSL.Module, path: "modules/things/schema.yaml", concepts: [AtlasFlow.Workshop.Things]
end

defmodule AtlasFlow.Workshop do
  @moduledoc """
  A second neutral model for Flow's tests, with the kinds the freshness design names
  (docs/design/page-freshness.md): its legacy flow `tend` hands an open widget to the
  maker mia, until the widget is completed.
  """
  use RelaDSL.Composition,
    name: "workshop",
    subflow_behaviour: AtlasFlow.Subflow,
    legacy_behaviour: AtlasFlow.Legacy

  @behaviour AtlasFlow.Model

  schema(
    version: "1.0",
    namespace: "https://example.invalid/workshop#",
    description: "A workshop.\n"
  )

  modules([AtlasFlow.Workshop.Module])
  environments([:prod, :test])

  legacy_flow(:tend,
    kinds: [:widget],
    field: :todo,
    owner_relation: :tended_by,
    states: [
      [name: :done, when: [completed: true], done: true],
      [
        name: :open,
        owner: [kind: :maker, key: "mia"],
        expected: "Tend it",
        why: "it is open",
        next: [:done]
      ]
    ]
  )

  defcomposition :workshop do
    subflows([])
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
