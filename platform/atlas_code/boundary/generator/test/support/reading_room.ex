defmodule AtlasCodeBoundary.Generator.ReadingRoom do
  @moduledoc false
  # A neutral contract for the `:stream` type: a reading room that hands out a book's pages
  # as a stream. A stream is a direct field of an outcome model only (as in the Runtime's
  # generator). None of Code's values.
  use AtlasCodeBoundary.Generator.Schema

  version "1.0.0"

  defmodel :read_input do
    field :title, :string, required: true
  end

  defmodel :reading do
    field :title, :string, required: true
    field :pages, :stream, required: true
  end

  defcapability :read, input: :read_input, outcomes: [opened: :reading], right: :read
end

defmodule AtlasCodeBoundary.Generator.ReadingRoom.Boundary do
  @moduledoc false
  use AtlasCodeBoundary.Generator.Targets.Boundary,
    contract: AtlasCodeBoundary.Generator.ReadingRoom,
    implementation: AtlasCodeBoundary.Generator.ReadingRoom.Desk
end

defmodule AtlasCodeBoundary.Generator.ReadingRoom.Desk do
  @moduledoc false
  # A lazy stream of three pages that tells the client's pid each time it produces one, so a
  # test sees when it is read. A few titles answer with what is no stream.
  use AtlasCodeBoundary.Generator.ReadingRoom.Boundary.Implementation

  alias AtlasCodeBoundary.Generator.ReadingRoom.Boundary, as: R

  @not_streams ["text", "map", "number", "one-arity"]

  @impl true
  def read(_client, %R.ReadInput{title: title}) when title in @not_streams,
    do: %R.Outcome.Opened{title: title, pages: not_stream(title)}

  def read({pid, _rights}, %R.ReadInput{title: title}) do
    pages =
      Stream.map(1..3, fn n ->
        send(pid, {:page_read, n})
        "page #{n}\n"
      end)

    %R.Outcome.Opened{title: title, pages: pages}
  end

  defp not_stream("text"), do: "not a stream"
  defp not_stream("map"), do: %{"a" => "b"}
  defp not_stream("number"), do: 42
  defp not_stream("one-arity"), do: &Function.identity/1
end
