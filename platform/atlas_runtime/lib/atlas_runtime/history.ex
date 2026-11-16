defmodule AtlasRuntime.History do
  @moduledoc """
  The implementation behind `AtlasRuntime.Boundary.History`: a skeleton. Both capabilities
  are declared with their arity, and neither has behaviour yet: each raises
  `AtlasRuntime.History.NotImplemented`, since an empty page or `not_found` would claim the
  Runtime has no such turns (OC review R2). Nothing starts or calls it until HR. Not the
  turn records themselves (`AtlasRuntime.Persistence.History`).
  """
  use AtlasRuntime.Boundary.History.Implementation

  defmodule NotImplemented do
    @moduledoc "Raised by a skeleton capability: the contract is declared, its behaviour is not."
    defexception [:capability]

    @impl true
    def exception(capability), do: %__MODULE__{capability: capability}

    @impl true
    def message(%{capability: capability}), do: "#{capability} has no implementation yet"
  end

  @impl true
  def list_turns(_client, _input), do: raise(NotImplemented, :list_turns)

  @impl true
  def get_turn(_client, _input), do: raise(NotImplemented, :get_turn)
end
