defmodule RelaDSL do
  @moduledoc """
  A concept of a model: its types, its entity with its fields and rules, its relations,
  and the subflows and gates on it, in one module.

      defmodule MyModel.Letter do
        use RelaDSL

        type :letter_state, values: [:draft, :sent], labels: [draft: "Draft", sent: "Sent"]

        entity :letter, label: "Letter", plural: "letters", id_type: :manual,
          id_prefix: "LE-", description: "One letter." do
          field :title, :string, required: true, description: "What it is about"
          field :body, :string, description: "The text", multiline: true
          field :state, :letter_state
          primary :title
          create ask: [:title, :body], id: [prefix: "LE-", digits: 2]
        end

        relation :written_by, label: "written by", description: "Who wrote it.",
          from: [:letter], to: [:clerk], max_outgoing: 1, inverse: {:letters, "letters"}

        subflow :letter, label: "Letter", subject: :letter do
          # RelaDSL.Schema's subflow macros
        end
      end

  `use RelaDSL` gives a module both vocabularies: the description macros of
  `RelaDSL.Description` and the subflow and gate macros of `RelaDSL.Schema`. Inside an
  `entity` block, `start` puts the kind on the start page; inside a subflow, it is a
  start trigger. The module gets `__rela__(:concept)`, what it declares as plain data,
  besides `__flows__/0` and `__gates__/0`.

  A concept on its own is not checked against others: a module (`RelaDSL.Module`)
  groups concepts into one Rela file, and a composition (`RelaDSL.Composition`) selects
  modules and checks that every name resolves.
  """

  defmacro __using__(opts) do
    quote do
      use RelaDSL.Schema, unquote(opts)
      import RelaDSL.Schema, only: unquote(RelaDSL.Schema.__macros__() -- [start: 1, start: 2])
      use RelaDSL.Description, :concept
    end
  end
end
