defmodule AtlasRuntimeBoundary.Test.OperationsSkeleton do
  @moduledoc """
  The skeleton implementation of the operations contract: every capability with its arity,
  and no behaviour. The contract declares no "not running" outcome, so each one raises
  `AtlasRuntimeBoundary.Test.NotImplemented` rather than answer something untrue.
  """
  use AtlasRuntimeBoundary.Test.OperationsFacade.Implementation

  alias AtlasRuntimeBoundary.Test.NotImplemented

  @impl true
  def runtime_info(_client), do: raise(NotImplemented, :runtime_info)

  @impl true
  def policy(_client), do: raise(NotImplemented, :policy)

  @impl true
  def pause(_client), do: raise(NotImplemented, :pause)

  @impl true
  def resume(_client), do: raise(NotImplemented, :resume)

  @impl true
  def drain(_client), do: raise(NotImplemented, :drain)

  @impl true
  def stop(_client, _input), do: raise(NotImplemented, :stop)

  @impl true
  def release_slot(_client, _input), do: raise(NotImplemented, :release_slot)

  @impl true
  def clear_quota_mark(_client, _input), do: raise(NotImplemented, :clear_quota_mark)
end
