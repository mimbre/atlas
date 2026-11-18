defmodule AtlasCodeBoundary.Generator.Example do
  @moduledoc false
  # A neutral contract for the generator's tests: a lending library, none of Code's
  # values.
  use AtlasCodeBoundary.Generator.Schema

  version "1.0.0"

  defmodel :shelf do
    field :row, :integer, required: true
  end

  defmodel :branch do
    field :city, :string, required: true
    field :open, :boolean
  end

  defmodel :book do
    field :title, :string, required: true
    field :condition, {:enum, [:new, :worn, :"badly-worn"]}, required: true
    field :place, {:one_of, [:shelf, :branch], tag: :kind}, required: true
    field :due_at, :datetime
    field :labels, {:list, {:enum, [:large_print, :audio]}}
    field :notes, {:map, :string}
  end

  defmodel :lend_input do
    field :title, :string, required: true
    field :until, :datetime, required: true
  end

  defmodel :shortage do
    field :waiting, :integer, required: true
  end

  defmodel :refusal do
    field :why, {:enum, [:banned, :unreadable]}, required: true
    field :note, :string
  end

  defmodel :find_input do
    field :title, :string, required: true
  end

  defmodel :tally do
    field :books, {:list, :book}, required: true
    field :counted_at, :datetime, required: true
  end

  defcapability :lend,
    input: :lend_input,
    outcomes: [lent: :book, short: :shortage, declined: :refusal, missing: nil],
    right: :lend

  defcapability :count, outcomes: [counted: :tally], right: :browse

  # An input, but no outcome for an invalid one: the facade answers InvalidInput.
  defcapability :find, input: :find_input, outcomes: [lent: :book, missing: nil], right: :browse

  invalid_input :declined, set: [why: :unreadable], detail: :note
end

defmodule AtlasCodeBoundary.Generator.Example.Boundary do
  @moduledoc false
  use AtlasCodeBoundary.Generator.Targets.Boundary,
    contract: AtlasCodeBoundary.Generator.Example,
    implementation: AtlasCodeBoundary.Generator.Example.Library
end

defmodule AtlasCodeBoundary.Generator.Example.Library do
  @moduledoc false
  # The example's implementation: answers by the title, so tests can reach every outcome,
  # and two outcomes the contract does not allow.
  use AtlasCodeBoundary.Generator.Example.Boundary.Implementation

  alias AtlasCodeBoundary.Generator.Example.Boundary, as: B

  @impl true
  def lend(_client, %B.LendInput{title: "missing"}), do: %B.Outcome.Missing{}
  def lend(_client, %B.LendInput{title: "short"}), do: %B.Outcome.Short{waiting: 2}

  def lend(_client, %B.LendInput{title: "undeclared"}),
    do: %B.Outcome.Counted{books: [], counted_at: DateTime.utc_now()}

  def lend(_client, %B.LendInput{title: "invalid"}), do: %B.Outcome.Short{waiting: "two"}
  def lend(_client, %B.LendInput{title: "plain"}), do: {:ok, :lent}

  def lend(_client, %B.LendInput{title: title, until: until}),
    do: %B.Outcome.Lent{title: title, condition: :worn, place: %B.Shelf{row: 3}, due_at: until}

  @impl true
  def find(_client, %B.FindInput{}), do: %B.Outcome.Missing{}

  @impl true
  def count({id, _rights}),
    do: %B.Outcome.Counted{
      books: [%B.Book{title: id, condition: :new, place: %B.Branch{city: "Delft"}}],
      counted_at: ~U[2026-01-02 03:04:05Z]
    }
end
