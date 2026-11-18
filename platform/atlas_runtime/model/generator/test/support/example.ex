defmodule AtlasRuntimeModel.Generator.Example do
  @moduledoc false
  # A neutral model for the generator's tests: a small library, none of the Runtime's
  # entities. It uses every type, and both a file per record and one file for all.
  use AtlasRuntimeModel.Generator.Schema

  version "1.2.0"

  type :genre, values: [:novel, :poetry, :essay]

  defmodel :author do
    field :name, :string, required: true
    field :born, :integer
  end

  defmodel :paper do
    field :pages, :integer, required: true
    field :hardcover, :boolean, required: true
  end

  defmodel :ebook do
    field :bytes, :integer, required: true
  end

  defmodel :review do
    field :stars, {:enum, [:one, :two, :three]}, required: true
    field :at, :datetime, required: true
  end

  defrecord :book,
    persist: [form: :json_file, path: "books/{book_id}.json", format_version: 2] do
    field :book_id, :string, required: true
    field :title, :string, required: true
    field :genre, :genre, required: true
    field :authors, {:list, :author}, required: true
    field :edition, {:one_of, [:paper, :ebook]}, required: true
    field :reviews, {:list, :review}
    field :tags, {:list, :string}
    field :shelved_at, :datetime
    field :archive_note, :string
  end

  defrecord :loan_entry,
    persist: [form: :json_file, path: "books/loans.json", format_version: 1] do
    field :reader, :string, required: true
    field :book_id, :string, required: true
    field :returned, :boolean, required: true
    field :genre, :genre
  end
end

defmodule AtlasRuntimeModel.Generator.Example.Model do
  @moduledoc false
  use AtlasRuntimeModel.Generator.Targets.Model, contract: AtlasRuntimeModel.Generator.Example
end
