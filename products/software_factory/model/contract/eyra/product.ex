defmodule Model.Product do
  @moduledoc """
  A product Atlas builds (SC-Atlas-20): the top level of the product plan. Every scene
  belongs to one product (`of_product`), and under it its use cases and issues; a
  product's page lists only its scenes and creates one under it.

  A product's `code` is the part of its work's keys that says whose work it is: a scene
  made under the product with code `Atlas` gets `SC-Atlas-` and the next number among
  that product's scenes (the composition's `create: [id: [code: {:of_product, :code}]]`).
  Keys already made never change.

  A product is data, made by hand from the products list (its name and its code); the
  model names none. Its own configuration (repositories, tokens, default phase,
  milestones, Runtimes and people; IS-Atlas-128) comes later.
  """
  use RelaDSL

  entity :product,
    label: "Product",
    plural: "products",
    aliases: ["pd"],
    id_type: :manual,
    id_prefix: "PD-",
    description: """
    A product Atlas builds, with its scenes, their use cases and their issues. Its
    code is in the keys of its work, e.g. SC-<code>-01.
    """ do
    field(:name, :string, required: true, description: "What the product is called")

    field(:code, :string,
      required: true,
      unique: true,
      description:
        "The key code of its work, such as Atlas: its scenes are SC-<code>-NN; never changed once work has it"
    )

    field(:description, :string, description: "What the product is", multiline: true)

    create(ask: [:name, :code, :description], id: [prefix: "PD-", digits: 2])
  end

  relation(:of_product,
    label: "of product",
    description: "A scene belongs to one product; a product has zero or more scenes.",
    from: [:scene],
    to: [:product],
    max_outgoing: 1,
    inverse: {:scenes, "scenes"},
    parent: true
  )
end
