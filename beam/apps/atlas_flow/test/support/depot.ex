defmodule AtlasFlow.Depot do
  @moduledoc """
  The neutral model Flow's tests run: a depot of boxes, written in the Rela DSL as a
  model is. Its legacy flow `pack` hands a box to whoever is next (bob packs it, ada
  checks it, bob again when it is taken back); its subflow `sort` runs a box while it is
  in its first phase, and gives the box back to `pack` after.
  """
  use RelaDSL.Composition,
    name: "depot",
    subflow_behaviour: AtlasFlow.Subflow,
    legacy_behaviour: AtlasFlow.Legacy

  @behaviour AtlasFlow.Model

  schema(version: "1.0", namespace: "https://example.invalid/depot#", description: "A depot.\n")
  modules([AtlasFlow.Depot.Goods])
  environments([:prod, :test])

  legacy_flow(:pack,
    kinds: [:box],
    field: :todo,
    owner_relation: :owned_by,
    states: [
      [name: :done, when: [completed: true], done: true],
      [
        name: :again,
        when: [reopened: :signed_by],
        owner: [kind: :clerk, key: "bob"],
        expected: "Again: {note}",
        why: "taken back",
        next: [:packing, :done]
      ],
      [
        name: :check,
        when: [progress: :check],
        owner: [kind: :clerk, key: "ada"],
        expected: "Check it",
        why: "all in it is packed",
        next: [:done]
      ],
      [
        name: :packing,
        owner: [kind: :clerk, key: "bob"],
        expected: "Pack it",
        why: "not all in it is packed",
        next: [:check]
      ]
    ]
  )

  acl(comment: "The depot's roles.")
  role("depot", read: ["*"], create: [:cursor], update: [:box, :cursor])
  role("clerk", read: ["*"], update: [:box])
  assign("system:depot", "depot")

  defcomposition :depot do
    subflows([AtlasFlow.Depot.Box])
  end
end
