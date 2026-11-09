defmodule Model.Person do
  @moduledoc "A person who works with Atlas."
  use RelaDSL

  entity :person,
    label: "Person",
    plural: "people",
    id_type: :manual,
    description: """
    Someone who works with Atlas. The id is short and lower case, made from
    the name, e.g. melle.
    """ do
    field(:name, :string, required: true, description: "As it is shown")
    top(false)
    primary(:name)

    create(
      ask: [:name],
      id: [
        from: :name,
        pattern: "^\\s*([A-Za-z][A-Za-z0-9]*)",
        template: "{1}",
        lower: true,
        error: "name must start with a letter, e.g. Melle"
      ]
    )
  end
end
