defmodule AtlasRuntimeBoundary.Test.NotImplemented do
  @moduledoc "Raised by a skeleton capability: the contract is declared, its behaviour is not."
  defexception [:capability]

  @impl true
  def exception(capability), do: %__MODULE__{capability: capability}

  @impl true
  def message(%{capability: capability}), do: "#{capability} has no implementation yet"
end
