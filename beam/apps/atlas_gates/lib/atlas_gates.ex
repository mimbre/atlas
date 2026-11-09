defmodule AtlasGates do
  @moduledoc """
  Gates: the one gate framework every component uses (D-0063). A caller asks a gate for a
  verdict (`AtlasGates.Request`), Gates evaluates it with the evaluator for the gate's
  flavor, settles it into a verdict by the gate's decide map (`AtlasGates.Verdict`) and
  records it once through Facts (`AtlasGates.Record`). The caller enforces the verdict.

  Gate definitions are data (`AtlasGates.Definitions`); Gates' code names no gate and no
  kind. The safe defaults: no verdict, an uncertain one or an error mean the gate's safe
  verdict, and a verdict that could not be recorded is an error, never a pass.

  This slice evaluates rule gates (`AtlasGates.Rules`). A smart gate (advice plus rules)
  has no evaluator yet: it is answered with the safe verdict, as an error, and not recorded.
  """

  alias AtlasGates.{Record, Request, Rules, Verdict}

  @doc """
  Evaluate and record `request` through `facts` (`{module, state}`, see `AtlasGates.Facts`):
  `{:ok, verdict}` once it is recorded (now, or by an earlier identical request), or
  `{:error, verdict, reason}` with the safe verdict when it could not be evaluated or
  recorded. `opts` go to `AtlasGates.Record.record/4`.
  """
  def decide(%Request{} = request, facts, opts \\ []) do
    case evaluator(request.definition) do
      {:ok, evaluate} ->
        started = System.monotonic_time()
        result = evaluate.(request.definition, request.evidence)
        ms = System.convert_time_unit(System.monotonic_time() - started, :native, :millisecond)
        Record.record(request, Verdict.settle(request, result, ms), facts, opts)

      {:error, why} ->
        verdict = Verdict.settle(request, {"error", [why]}, 0)
        {:error, Verdict.unrecorded(verdict, request, why), why}
    end
  end

  defp evaluator(%{"flavor" => "rule"}), do: {:ok, &Rules.evaluate/2}

  defp evaluator(%{"flavor" => flavor}),
    do: {:error, "gates of flavor #{inspect(flavor)} have no evaluator yet"}

  defp evaluator(_gate), do: {:error, "the gate names no flavor"}
end
