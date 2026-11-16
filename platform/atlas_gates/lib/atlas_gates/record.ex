defmodule AtlasGates.Record do
  @moduledoc """
  Records each verdict once, through Facts (`AtlasGates.Facts`), as one fact of the
  verdict kind the configuration names (`config :atlas_gates, verdict_kind: …`): which gate
  and version, the subject and fingerprint, the evidence itself (one `field: value` line
  each, sorted, so it can be replayed) and its digest, the rule outcome and version, the
  verdict, the allowed outcomes, `unsettled`, the duration and when it was decided.

  Idempotent by the request id: a verdict already recorded with the request's identity
  (`AtlasGates.Request.identity/1`) is the answer, and nothing new is recorded. A failure to
  read or write Facts is an error, never a pass.
  """

  alias AtlasGates.{Request, Verdict}

  @doc "The kind verdicts are recorded as, from the configuration."
  def kind, do: Application.fetch_env!(:atlas_gates, :verdict_kind)

  @doc """
  Record `verdict` for `request` through `facts` (`{module, state}`): `{:ok, verdict}`
  with `recorded` set, or `{:error, verdict, reason}` with the safe verdict. `opts`: `kind`
  (default `kind/0`), `now` (the decision's moment, a `DateTime`).
  """
  def record(%Request{} = request, %Verdict{} = verdict, {module, state}, opts \\ []) do
    kind = Keyword.get_lazy(opts, :kind, &kind/0)
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    now = if is_function(now, 0), do: now.(), else: now

    result =
      case module.find(state, kind, Request.identity(request)) do
        {:ok, nil} ->
          values = values(request, verdict, now)

          with {:ok, key} <- module.create(state, kind, request.id, values, request.links),
               do: {:ok, key, :new}

        {:ok, key} ->
          {:ok, key, :again}

        {:error, _} = error ->
          error
      end

    case result do
      {:ok, key, how} ->
        repaired =
          if function_exported?(module, :ensure_links, 5),
            do: module.ensure_links(state, kind, request.id, key, request.links),
            else: {:ok, key}

        case repaired do
          {:ok, ^key} -> {:ok, %{verdict | recorded: key, recorded_as: how}}
          {:error, why} -> {:error, Verdict.unrecorded(verdict, request, why), why}
        end

      {:error, why} ->
        {:error, Verdict.unrecorded(verdict, request, why), why}
    end
  end

  @doc "The values of the recorded verdict, without empty ones."
  def values(%Request{} = request, %Verdict{} = verdict, %DateTime{} = now) do
    gate = request.definition

    %{
      "gate" => request.gate,
      "activity_id" => request.activity_id,
      "activity_digest" => request.activity_digest,
      "gate_version" => request.gate_version,
      "flavor" => gate["flavor"],
      "purpose" => gate["purpose"],
      "subject" => request.subject,
      "fingerprint" => request.fingerprint,
      "evidence" => evidence(request.evidence),
      "evidence_digest" => request.evidence_digest,
      "rule_outcome" => verdict.rule_outcome,
      "rule_version" => verdict.rule_version,
      "verdict" => verdict.outcome,
      "allowed_outcomes" => Enum.join(request.allowed_outcomes, ","),
      "unsettled" => verdict.unsettled,
      "duration_ms" => verdict.duration_ms,
      "decided_at" => now |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }
    |> Map.reject(fn {_, v} -> v in [nil, ""] end)
  end

  defp evidence(evidence) do
    evidence
    |> Enum.sort()
    |> Enum.map_join("\n", fn {field, value} ->
      "#{field}: #{if is_binary(value), do: value, else: JSON.encode!(value)}"
    end)
  end
end
