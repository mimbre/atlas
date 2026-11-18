defmodule AtlasRuntimeBoundary.Generator.Example do
  @moduledoc false
  # A neutral contract for the generator's tests: a lending library, none of the
  # Runtime's values.
  use AtlasRuntimeBoundary.Generator.Schema

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

  # A scanned copy as a byte stream: a :stream is a direct field of an outcome model.
  defmodel :scan do
    field :title, :string, required: true
    field :content, :stream, required: true
  end

  defmodel :download_input do
    field :title, :string, required: true
  end

  # A returned copy's pages as a byte stream: an input model takes at most one :stream.
  defmodel :upload_input do
    field :title, :string, required: true
    field :pages, :stream, required: true
  end

  defcapability :lend,
    input: :lend_input,
    outcomes: [lent: :book, short: :shortage, declined: :refusal, missing: nil],
    right: :lend

  defcapability :count, outcomes: [counted: :tally], right: :browse

  # An input, but no outcome for an invalid one: the facade answers InvalidInput.
  defcapability :find, input: :find_input, outcomes: [lent: :book, missing: nil], right: :browse

  defcapability :download,
    input: :download_input,
    outcomes: [downloaded: :scan, missing: nil],
    right: :browse

  defcapability :upload,
    input: :upload_input,
    outcomes: [received: nil, declined: :refusal],
    right: :lend

  invalid_input :declined, set: [why: :unreadable], detail: :note
end

defmodule AtlasRuntimeBoundary.Generator.Example.Boundary do
  @moduledoc false
  use AtlasRuntimeBoundary.Generator.Targets.Boundary,
    contract: AtlasRuntimeBoundary.Generator.Example,
    implementation: AtlasRuntimeBoundary.Generator.Example.Library
end

defmodule AtlasRuntimeBoundary.Generator.Example.Library do
  @moduledoc false
  # The example's implementation: answers by the title, so tests can reach every outcome,
  # and two outcomes the contract does not allow.
  use AtlasRuntimeBoundary.Generator.Example.Boundary.Implementation

  alias AtlasRuntimeBoundary.Generator.Example.Boundary, as: B

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

  # The client's id is the process told when the stream is opened, so a test sees whether
  # anything enumerated it.
  @impl true
  def download(_client, %B.DownloadInput{title: "missing"}), do: %B.Outcome.Missing{}

  def download(_client, %B.DownloadInput{title: "map"}),
    do: %B.Outcome.Downloaded{title: "map", content: %{}}

  def download(_client, %B.DownloadInput{title: "one-arity"}),
    do: %B.Outcome.Downloaded{title: "one-arity", content: fn _ -> :ok end}

  def download(_client, %B.DownloadInput{title: "text"}),
    do: %B.Outcome.Downloaded{title: "text", content: "not a stream"}

  def download({owner, _rights}, %B.DownloadInput{title: title}) do
    content =
      Stream.resource(
        fn ->
          if is_pid(owner), do: send(owner, {:opened, title})
          ["page 1\n", "page 2\n"]
        end,
        fn
          [] -> {:halt, []}
          [chunk | rest] -> {[chunk], rest}
        end,
        fn _ -> :ok end
      )

    %B.Outcome.Downloaded{title: title, content: content}
  end

  # The client's id is told the input's stream as received, so a test sees it is the term
  # it gave, unread.
  @impl true
  def upload({owner, _rights}, %B.UploadInput{pages: pages}) do
    if is_pid(owner), do: send(owner, {:received, pages})
    %B.Outcome.Received{}
  end

  @impl true
  def count({id, _rights}),
    do: %B.Outcome.Counted{
      books: [%B.Book{title: id, condition: :new, place: %B.Branch{city: "Delft"}}],
      counted_at: ~U[2026-01-02 03:04:05Z]
    }
end

defmodule AtlasRuntimeBoundary.Generator.Example.Guarded do
  @moduledoc false
  # The same contract, with the invalid_input detail told only to clients holding
  # :see_reasons.
  use AtlasRuntimeBoundary.Generator.Targets.Boundary,
    contract: AtlasRuntimeBoundary.Generator.Example,
    implementation: AtlasRuntimeBoundary.Generator.Example.GuardedLibrary,
    invalid_detail_right: :see_reasons
end

defmodule AtlasRuntimeBoundary.Generator.Example.GuardedLibrary do
  @moduledoc false
  # Answers every valid input with an outcome; the tests use it for invalid inputs.
  use AtlasRuntimeBoundary.Generator.Example.Guarded.Implementation

  alias AtlasRuntimeBoundary.Generator.Example.Guarded, as: G

  @impl true
  def lend(_client, _input), do: %G.Outcome.Missing{}

  @impl true
  def find(_client, _input), do: %G.Outcome.Missing{}

  @impl true
  def download(_client, _input), do: %G.Outcome.Missing{}

  @impl true
  def upload(_client, _input), do: %G.Outcome.Received{}

  @impl true
  def count(_client), do: %G.Outcome.Counted{books: [], counted_at: ~U[2026-01-02 03:04:05Z]}
end
