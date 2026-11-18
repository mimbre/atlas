defmodule AtlasBFF.Example do
  @moduledoc false
  # A neutral contract for the generator's tests: none of Atlas's blocks.
  use AtlasBFF.Schema

  version "1.0.0"

  defmodel :link do
    field :label, :string, required: true
    field :to, :string, required: true
  end

  # A message of its own, and a map: what a path-less endpoint takes.
  defmodel :greeting do
    field :name, :string, required: true
    field :tags, {:map, :string}
  end

  defblock :card do
    field :title, :string, required: true
    field :count, :integer
    field :links, {:list, :link}
  end

  defblock :note do
    field :text, :string, required: true
    field :done, :boolean
  end

  defmarkup :group do
    field :title, :string, required: true
  end

  defmarkup :tint do
    field :shade, :string
  end

  # Written in an order that is not the one they match in: a literal wins.
  defpage :card, "/cards/:id"
  defpage :new_card, "/cards/new"
  defpage :home, "/"

  defendpoint :save_card, "/cards/:id",
    call: :submit,
    takes: :values,
    replies: [saved: :view_model, refused: :view_model]

  defendpoint :greet, call: :greet, takes: :greeting, replies: [hi: :greeting, page: :view_model]
end

defmodule AtlasBFF.Example.Server do
  @moduledoc false
  use AtlasBFF.Targets.Server, contract: AtlasBFF.Example
end

defmodule AtlasBFF.Example.Client do
  @moduledoc false
  use AtlasBFF.Targets.Client, contract: AtlasBFF.Example
end
