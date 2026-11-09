defmodule AtlasGates.Verdict do
  @moduledoc """
  What a gate answers a request: the `outcome` (one of the request's allowed outcomes), the
  `rule_outcome` and `rule_version` it came from, `unsettled` (`"uncertain"` or `"error"`
  when the gate could not decide by itself, else nil), the `reasons`, how long the
  evaluation took (`duration_ms`) and, once recorded, the verdict's key in `recorded` and
  whether it was recorded now (`:new`) or by an earlier, identical request (`:again`).

  The safe defaults: an uncertain or failed evaluation, a rule outcome the gate's decide
  map has no allowed verdict for, and a recording that failed all give the gate's safe
  verdict (its decide map's verdict for an error), never a pass.
  """

  defstruct [
    :request_id,
    :gate,
    :outcome,
    :rule_outcome,
    :rule_version,
    :unsettled,
    :duration_ms,
    :recorded,
    :recorded_as,
    reasons: []
  ]

  @type t :: %__MODULE__{}

  alias AtlasGates.Request

  @doc "Settle the evaluator's `{rule_outcome, reasons}` into a verdict by the gate's decide map."
  def settle(%Request{} = request, {rule_outcome, reasons}, duration_ms) do
    gate = request.definition
    safe = Request.safe_verdict(gate)
    decided = get_in(gate, ["decide", rule_outcome])

    {outcome, unsettled, reasons} =
      cond do
        rule_outcome in ["uncertain", "error"] ->
          {allowed(decided, request) || safe, rule_outcome, reasons}

        allowed(decided, request) ->
          {decided, nil, reasons}

        true ->
          {safe, "error",
           reasons ++ ["rule outcome #{rule_outcome} has no allowed verdict in the decide map"]}
      end

    %__MODULE__{
      request_id: request.id,
      gate: request.gate,
      outcome: outcome,
      rule_outcome: rule_outcome,
      rule_version: request.rule_version,
      unsettled: unsettled,
      reasons: reasons,
      duration_ms: duration_ms
    }
  end

  @doc "The verdict when it could not be recorded: an error, with the gate's safe verdict."
  def unrecorded(%__MODULE__{} = verdict, %Request{} = request, why) do
    %{
      verdict
      | outcome: Request.safe_verdict(request.definition),
        unsettled: "error",
        reasons: verdict.reasons ++ ["not recorded: #{why}"],
        recorded: nil,
        recorded_as: nil
    }
  end

  @doc "The verdict as a map with string keys, for printing as JSON."
  def to_map(%__MODULE__{} = v) do
    %{
      "request" => v.request_id,
      "gate" => v.gate,
      "verdict" => v.outcome,
      "rule_outcome" => v.rule_outcome,
      "rule_version" => v.rule_version,
      "unsettled" => v.unsettled,
      "reasons" => v.reasons,
      "duration_ms" => v.duration_ms,
      "recorded" => v.recorded,
      "recorded_as" => v.recorded_as && Atom.to_string(v.recorded_as)
    }
  end

  defp allowed(outcome, request) when is_binary(outcome),
    do: if(outcome in request.allowed_outcomes, do: outcome)

  defp allowed(_outcome, _request), do: nil
end
