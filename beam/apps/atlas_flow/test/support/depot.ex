defmodule AtlasFlow.Depot do
  @moduledoc """
  The neutral model Flow's tests run: a depot of boxes, written in the Rela DSL as a
  model is. Its subflow `sort` runs a box while it is in its first phase.
  """
  use RelaDSL.Composition,
    name: "depot",
    subflow_behaviour: AtlasFlow.Subflow

  @behaviour AtlasFlow.Model

  schema(version: "1.0", namespace: "https://example.invalid/depot#", description: "A depot.\n")
  modules([AtlasFlow.Depot.Goods])
  environments([:prod, :test])

  acl(comment: "The depot's roles.")
  role("depot", read: ["*"], create: [:cursor], update: [:box, :cursor])
  role("clerk", read: ["*"], update: [:box])
  assign("system:depot", "depot")

  defcomposition :depot do
    subflows([AtlasFlow.Depot.Box])
  end
end
