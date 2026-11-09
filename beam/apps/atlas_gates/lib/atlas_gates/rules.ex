defmodule AtlasGates.Rules do
  @moduledoc """
  The rule evaluator: applies a rule gate's `rule` to the evidence, deterministically. It
  knows conditions, never a gate.

  A rule is `%{"all" => conditions}`: every condition must hold. A condition is

    * `["equals", field, value]`: the evidence's `field` is exactly `value`;
    * `["same", field, other]`: the evidence's `field` and `other` are equal.

  The outcome, with the reasons that led to it:

    * `"pass"` when every condition holds;
    * `"changes_required"` when one does not;
    * `"uncertain"` when the evidence cannot settle it: a field the rule needs is missing
      or empty, or the rule names a field the gate does not declare as its evidence (the
      gate would decide on something it was never given). Uncertain wins over a failed
      condition: the gate did not get the fixed input it decides on;
    * `"error"` when the rule is not one this evaluator understands.
  """

  @type outcome :: String.t()

  @doc "Evaluate `gate`'s rule on `evidence` (a map of field name to value): `{outcome, reasons}`."
  @spec evaluate(map(), map()) :: {outcome(), [String.t()]}
  def evaluate(%{"rule" => %{"all" => conditions}} = gate, evidence)
      when is_list(conditions) and conditions != [] and is_map(evidence) do
    declared = gate["evidence"] || []
    results = Enum.map(conditions, &condition(&1, declared, evidence))

    cond do
      bad = Enum.find(results, &match?({:error, _}, &1)) -> {"error", [elem(bad, 1)]}
      unsettled(results) != [] -> {"uncertain", unsettled(results)}
      failed(results) != [] -> {"changes_required", failed(results)}
      true -> {"pass", []}
    end
  end

  def evaluate(%{"rule" => rule}, _evidence),
    do: {"error", ["the rule #{inspect(rule)} is not one the rule evaluator knows"]}

  def evaluate(_gate, _evidence), do: {"error", ["the gate has no rule"]}

  defp unsettled(results), do: for({:uncertain, why} <- results, do: why)
  defp failed(results), do: for({:failed, why} <- results, do: why)

  defp condition(["equals", field, expected], declared, evidence) when is_binary(field) do
    with {:ok, value} <- field(field, declared, evidence) do
      if value == expected,
        do: :holds,
        else: {:failed, "#{field} is #{show(value)}, not #{show(expected)}"}
    end
  end

  defp condition(["same", field, other], declared, evidence)
       when is_binary(field) and is_binary(other) do
    with {:ok, value} <- field(field, declared, evidence),
         {:ok, other_value} <- field(other, declared, evidence) do
      if value == other_value,
        do: :holds,
        else: {:failed, "#{field} (#{show(value)}) differs from #{other} (#{show(other_value)})"}
    end
  end

  defp condition(condition, _declared, _evidence),
    do: {:error, "the condition #{inspect(condition)} is not one the rule evaluator knows"}

  defp field(name, declared, evidence) do
    cond do
      name not in declared -> {:uncertain, "#{name} is not evidence this gate declares"}
      Map.get(evidence, name) in [nil, ""] -> {:uncertain, "#{name} is missing"}
      true -> {:ok, Map.fetch!(evidence, name)}
    end
  end

  defp show(value) when is_binary(value), do: inspect(value)
  defp show(value), do: JSON.encode!(value)
end
