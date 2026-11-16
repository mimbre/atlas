defmodule AtlasRuntime.Operations do
  @moduledoc """
  The implementation behind `AtlasRuntime.Boundary.Operations`: a skeleton. Every
  capability is declared with its arity, and none has behaviour yet. The contract declares
  no "not running" outcome, so each one raises `AtlasRuntime.Operations.NotImplemented`
  rather than answer something untrue (OC review R2). Nothing starts or calls it until S2c
  (O1: `runtime_info`, `policy`, `stop`, `release_slot`, `clear_quota_mark`; O2: `pause`,
  `resume`, `drain`).
  """
  use AtlasRuntime.Boundary.Operations.Implementation

  defmodule NotImplemented do
    @moduledoc "Raised by a skeleton capability: the contract is declared, its behaviour is not."
    defexception [:capability]

    @impl true
    def exception(capability), do: %__MODULE__{capability: capability}

    @impl true
    def message(%{capability: capability}), do: "#{capability} has no implementation yet"
  end

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
