defmodule AtlasGates.Rules do
  @moduledoc """
  The rule evaluator: applies a rule gate's `rule` to the evidence, deterministically. It
  knows conditions, never a gate.

  A rule is `%{"all" => conditions}`: every condition must hold. A condition is

    * `["equals", field, value]`: the evidence's `field` is exactly `value`;
    * `["same", field, other]`: the evidence's `field` and `other` are equal;
    * `["in", field, values]`: the field's value is in `values`;
    * `["includes", field, value]`: the field is a list holding `value`;
    * `["at_least", field, minimum]`: the field is a number at least `minimum`.

  An ordered rule is `%{"first" => [%{"when" => conditions, "then" => outcome}, ...],
  "otherwise" => outcome}`. Each case requires all its conditions; the first match
  returns its named outcome without reading later cases. An uncertain or erroneous
  case stops evaluation. When none match, the otherwise outcome is returned, including
  `advise`, which is settled by the gate's decide map without calling an advisor.
  Fixed cases must remain the prefix declared by the generated definition.

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
  def evaluate(%{"rule" => %{"first" => cases, "otherwise" => fallback}} = gate, evidence)
      when is_list(cases) and cases != [] and is_binary(fallback) and is_map(evidence) do
    with :ok <- AtlasGates.Definitions.check_fixed(gate) do
      declared = gate["evidence"] || []
      declared = if is_map(declared), do: Map.keys(declared), else: declared
      first(cases, fallback, declared, evidence)
    else
      {:error, why} -> {"error", [why]}
    end
  end

  def evaluate(%{"rule" => %{"all" => conditions}} = gate, evidence)
      when is_list(conditions) and conditions != [] and is_map(evidence) do
    with :ok <- AtlasGates.Definitions.check_fixed(gate) do
      declared = gate["evidence"] || []
      declared = if is_map(declared), do: Map.keys(declared), else: declared
      results = Enum.map(conditions, &condition(&1, declared, evidence))

      cond do
        bad = Enum.find(results, &match?({:error, _}, &1)) -> {"error", [elem(bad, 1)]}
        unsettled(results) != [] -> {"uncertain", unsettled(results)}
        failed(results) != [] -> {"changes_required", failed(results)}
        true -> {"pass", []}
      end
    else
      {:error, why} -> {"error", [why]}
    end
  end

  def evaluate(%{"rule" => rule}, _evidence),
    do: {"error", ["the rule #{inspect(rule)} is not one the rule evaluator knows"]}

  def evaluate(_gate, _evidence), do: {"error", ["the gate has no rule"]}

  defp unsettled(results), do: for({:uncertain, why} <- results, do: why)
  defp failed(results), do: for({:failed, why} <- results, do: why)

  defp first([], fallback, _declared, _evidence), do: {fallback, []}

  defp first([%{"when" => conditions, "then" => outcome} | rest], fallback, declared, evidence)
       when is_list(conditions) and conditions != [] and is_binary(outcome) do
    results = Enum.map(conditions, &condition(&1, declared, evidence))

    cond do
      bad = Enum.find(results, &match?({:error, _}, &1)) -> {"error", [elem(bad, 1)]}
      unsettled(results) != [] -> {"uncertain", unsettled(results)}
      failed(results) != [] -> first(rest, fallback, declared, evidence)
      true -> {outcome, []}
    end
  end

  defp first(_cases, _fallback, _declared, _evidence),
    do: {"error", ["each first case needs nonempty when conditions and a then outcome"]}

  defp condition(["in", name, choices], declared, evidence)
       when is_binary(name) and is_list(choices) do
    with {:ok, value} <- field(name, declared, evidence) do
      if value in choices, do: :holds, else: {:failed, "#{name} is not in #{show(choices)}"}
    end
  end

  defp condition(["includes", name, expected], declared, evidence) when is_binary(name) do
    with {:ok, value} <- field(name, declared, evidence) do
      cond do
        not is_list(value) -> {:uncertain, "#{name} must be a list"}
        expected in value -> :holds
        true -> {:failed, "#{name} does not include #{show(expected)}"}
      end
    end
  end

  defp condition(["at_least", name, minimum], declared, evidence)
       when is_binary(name) and is_number(minimum) do
    with {:ok, value} <- field(name, declared, evidence) do
      cond do
        not is_number(value) -> {:uncertain, "#{name} must be a number"}
        value >= minimum -> :holds
        true -> {:failed, "#{name} is less than #{show(minimum)}"}
      end
    end
  end

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
