defmodule AtlasRuntimeBoundary.Test.HistorySkeleton do
  @moduledoc """
  The skeleton implementation of the history contract: every capability with its arity,
  and no behaviour. Each one raises `AtlasRuntimeBoundary.Test.NotImplemented`: an empty
  list or not_found would claim the Runtime has no such turns.
  """
  use AtlasRuntimeBoundary.Test.HistoryFacade.Implementation

  alias AtlasRuntimeBoundary.Test.NotImplemented

  @impl true
  def list_turns(_client, _input), do: raise(NotImplemented, :list_turns)

  @impl true
  def get_turn(_client, _input), do: raise(NotImplemented, :get_turn)
end
