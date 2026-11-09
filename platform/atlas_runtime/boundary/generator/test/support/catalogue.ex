defmodule AtlasRuntimeBoundary.Generator.Catalogue do
  @moduledoc false
  # A neutral contract for the translation tests: a library's public catalogue, whose
  # copies the library keeps in its private model (test/fixtures/model_schema.exs).
  use AtlasRuntimeBoundary.Generator.Schema

  version "1.0.0"

  defmodel :shelf do
    field :row, :integer, required: true
  end

  defmodel :branch do
    field :city, :string, required: true
    field :open, :boolean
  end

  defmodel :hold do
    field :member, :string, required: true
    field :reason, {:enum, [:waitlist, :reserve]}, required: true
    field :placed_at, :datetime, required: true
  end

  defmodel :copy do
    field :id, :string, required: true
    field :title, :string, required: true
    field :condition, {:enum, [:new, :worn, :"badly-worn"]}, required: true
    field :place, {:one_of, [:shelf, :branch], tag: :kind}, required: true
    field :due_at, :datetime
    field :labels, {:list, {:enum, [:large_print, :audio]}}, required: true
    field :holds, {:list, :hold}, required: true
    field :home, :branch
    field :status, {:enum, [:on_shelf, :lent]}, required: true
    field :notes, {:map, :string}
  end

  defmodel :closing do
    field :copy_id, :string, required: true
    field :wear, {:enum, [:new, :worn, :"badly-worn"]}, required: true
  end

  defmodel :look_input do
    field :id, :string, required: true
  end

  defcapability :look,
    input: :look_input,
    outcomes: [seen: :copy, closed: :closing, missing: nil],
    right: :browse
end

defmodule AtlasRuntimeBoundary.Generator.CatalogueMappings do
  @moduledoc false
  use AtlasRuntimeBoundary.Generator.Mappings

  defmapping(:copy_record, :copy,
    rename: [copy_id: :id, wear: :condition, location: :place],
    drop: [:lent_count, :scan_path],
    values: [wear: [badly_worn: :"badly-worn"]],
    supply: [:status, :notes]
  )

  defmapping(:shelf_spot, :shelf)
  defmapping(:branch_spot, :branch)
  defmapping(:hold, :hold, drop: [:desk_note])

  defmapping(:ledger_entry, :closing,
    direction: :from_model,
    rename: [last_wear: :wear],
    drop: [:member, :closed],
    values: [last_wear: [badly_worn: :"badly-worn"]]
  )
end

defmodule AtlasRuntimeBoundary.Generator.Catalogue.Boundary do
  @moduledoc false
  # A test-only facade with translations, over the fixture model.
  use AtlasRuntimeBoundary.Generator.Targets.Boundary,
    contract: AtlasRuntimeBoundary.Generator.Catalogue,
    implementation: AtlasRuntimeBoundary.Generator.Catalogue.Desk,
    mappings: AtlasRuntimeBoundary.Generator.CatalogueMappings,
    model: AtlasRuntimeBoundary.Generator.FixtureModel
end

defmodule AtlasRuntimeBoundary.Generator.Catalogue.Desk do
  @moduledoc false
  # Keeps model entities only, and answers through from_model/2: the id "missing" is
  # never seen, "closed-<id>" is in the ledger, and any other id is a copy on its shelf.
  use AtlasRuntimeBoundary.Generator.Catalogue.Boundary.Implementation

  alias AtlasRuntimeBoundary.Generator.Catalogue.Boundary, as: B
  alias AtlasRuntimeBoundary.Generator.FixtureModel, as: M

  @impl true
  def look(_client, %B.LookInput{id: "missing"}), do: %B.Outcome.Missing{}

  def look(_client, %B.LookInput{id: "closed-" <> id}) do
    entry = M.LedgerEntry.new!(member: "ann", copy_id: id, last_wear: :badly_worn, closed: true)
    {:ok, outcome} = B.from_model(entry, as: :closed)
    outcome
  end

  def look(_client, %B.LookInput{id: id}) do
    {:ok, outcome} = B.from_model(copy(id), as: :seen, supply: [status: :on_shelf])
    outcome
  end

  @doc false
  def copy(id) do
    {:ok, copy} =
      M.CopyRecord.new(
        copy_id: id,
        title: "Dune",
        wear: :badly_worn,
        location: %{kind: :shelf_spot, row: 3},
        labels: [:audio],
        holds: [
          %{
            member: "bo",
            reason: "waitlist",
            placed_at: ~U[2026-01-02 03:04:05Z],
            desk_note: "asked twice"
          }
        ],
        home: %{city: "Delft"},
        lent_count: 7,
        scan_path: "/scans/#{id}.tiff"
      )

    copy
  end
end
