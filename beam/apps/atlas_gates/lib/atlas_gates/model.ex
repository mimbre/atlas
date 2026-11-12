defmodule AtlasGates.Model do
  @moduledoc """
  The model whose gates Gates evaluates: a module the domain compiles, wired by
  configuration (`config :atlas, model: SomeModel`). Gates names no gate and no kind.
  """

  @doc """
  Every gate, by name, with string keys: `version`, `flavor` (`rule` or `smart`),
  `purpose` (`flow` or `decider`), `evidence`, `rule` or `advice`, `verdicts`, `decide`,
  and for a decider its `fingerprint`, `fixed` rules and `answer_within` limits.
  """
  @callback gates() :: %{String.t() => map}

  @doc "The model Gates is wired to; raises when it is missing or has no gates."
  def configured! do
    model = Application.fetch_env!(:atlas, :model)

    unless is_atom(model) and Code.ensure_loaded?(model) and function_exported?(model, :gates, 0),
      do: raise(ArgumentError, "the model #{inspect(model)} has no gates/0 Gates can call")

    model
  end
end
