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

  @doc """
  How the key of a fact of each kind is made, by kind: `prefix` and `digits` (a new
  verdict's key is the prefix and the next number) and every `prefixes` its keys start
  with (to find a fact's kind by its key).
  """
  @callback ids() :: %{String.t() => %{String.t() => term}}

  @doc "The model Gates is wired to; raises when it is missing or lacks a callback."
  def configured! do
    model = Application.fetch_env!(:atlas, :model)

    unless is_atom(model) and Code.ensure_loaded?(model) and function_exported?(model, :gates, 0) and
             function_exported?(model, :ids, 0),
           do:
             raise(
               ArgumentError,
               "the model #{inspect(model)} has no gates/0 and ids/0 Gates can call"
             )

    model
  end
end
