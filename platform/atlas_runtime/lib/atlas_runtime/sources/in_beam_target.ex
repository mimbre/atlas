defmodule AtlasRuntime.Sources.InBeamTarget do
  @moduledoc """
  A work source reached through the `work_source` contract's in-BEAM Elixir target (M1),
  as `AtlasRuntime.Sources.Upload` calls it (M2 plan A3, the result upload's wiring; W6's
  `{module, ref}` seam). The ref is `%{facade: target, client: client, revision: n}`:

  - `facade`: a module generated with `AtlasRuntimeBoundary.Generator.Targets.Boundary` on
    `AtlasRuntimeBoundary.WorkSource` (the built-in local source's, or a test's);
  - `client`: the Runtime as that source knows it, `{id, [:lease]}`;
  - `revision`: the lease's report revision for this `ended` (1 for a lease's first
    report, then +1 for each; the puller derives it from the attempt). The work record's own
    revision, which `Upload` puts in its report, is not the lease's and is not sent.

  `report/2` maps `Upload`'s ended report onto the contract's `ended`:
  - the result's kind, reason, retry advice, `never_started`, answer (already redacted by
    `Upload`) and after-check (its output tail);
  - the attempt's provenance, one record per turn (none for an attempt that never ran);
  - the frozen result as the `change_set`: its `base` (the baseline snapshot id the attempt
    froze on, which every root's `csf_` covers; required since `work_source` 0.2.0) and its
    roots, each with its `csf_` fingerprint and entries.

  Answers: `recorded` → `{:recorded, missing}`; `lease_lost` → `:lease_lost`; `put_blob`'s
  `stored`, `too_large` and `not_referenced` as they are. `rejected` (a revision conflict, an
  invalid input or a digest mismatch) has no word in `Upload`'s seam: it is logged and the
  upload stops as for a lost lease, sending nothing more.

  It is also the puller's target (`AtlasRuntime.Sources.Puller.Target`, M2 plan A2) with
  the ref `%{facade: target, client: client}`: `poll/2`, `send_report/2` and `get_blob/3`
  (the import's download, M2 A3) call the facade
  and answer its outcome structs in the seam's terms, and `uploader/2` is this module with
  the ref and the revision for `Upload`. The HTTP client target is
  `AtlasRuntime.Sources.HttpTarget`.
  """
  @behaviour AtlasRuntime.Sources.Upload
  @behaviour AtlasRuntime.Sources.Puller.Target

  require Logger

  @type ref :: %{facade: module(), client: {String.t(), [atom()]}, revision: pos_integer()}

  ## The puller's seam

  @impl AtlasRuntime.Sources.Puller.Target
  def poll(%{facade: facade, client: client}, input) do
    outcome = facade.poll(client, input)

    case name(outcome) do
      "Polled" ->
        {:polled,
         %{
           leases: outcome.leases,
           cancel: outcome.cancel,
           lease_lost: outcome.lease_lost,
           timing: %{lease_ttl: outcome.timing.lease_ttl, poll_max: outcome.timing.poll_max}
         }}

      "Rejected" ->
        {:rejected, outcome.reason}

      _ ->
        {:error, {:unexpected, name(outcome)}}
    end
  end

  @impl AtlasRuntime.Sources.Puller.Target
  def send_report(%{facade: facade, client: client}, input) do
    outcome = facade.report(client, input)

    case name(outcome) do
      "Recorded" -> {:recorded, outcome.missing}
      "LeaseLost" -> :lease_lost
      "Rejected" -> {:rejected, outcome.reason}
      _ -> {:error, {:unexpected, name(outcome)}}
    end
  end

  @impl AtlasRuntime.Sources.Puller.Target
  def uploader(ref, revision), do: {__MODULE__, Map.put(ref, :revision, revision)}

  # M2 A3: one blob of the lease's input, for the import.
  @impl AtlasRuntime.Sources.Puller.Target
  def get_blob(%{facade: facade, client: client}, lease_id, sha256) do
    outcome = facade.get_blob(client, %{lease_id: lease_id, sha256: sha256})

    case name(outcome) do
      "Blob" -> {:ok, %{sha256: outcome.sha256, size: outcome.size, content: outcome.content}}
      other -> {:not_served, other}
    end
  end

  ## Upload's seam

  @impl AtlasRuntime.Sources.Upload
  def report(%{facade: facade, client: client, revision: revision}, %{state: :ended} = report) do
    input = %{lease_id: report.lease_id, revision: revision, report: ended_report(report.result)}

    outcome = facade.report(client, input)

    case name(outcome) do
      "Recorded" -> {:recorded, outcome.missing}
      _ -> stop_on(outcome, report.lease_id, "report")
    end
  end

  @impl AtlasRuntime.Sources.Upload
  def put_blob(%{facade: facade, client: client}, blob) do
    input = Map.take(blob, [:lease_id, :sha256, :size, :content])

    outcome = facade.put_blob(client, input)

    case name(outcome) do
      "Stored" -> :stored
      "TooLarge" -> :too_large
      "NotReferenced" -> :not_referenced
      _ -> stop_on(outcome, blob.lease_id, "put_blob #{blob.sha256}")
    end
  end

  @doc false
  # Upload's ended result (plain maps, nil fields dropped) as the contract's ended; also the
  # HTTP target's.
  def ended_report(%{result: result} = ended) do
    %{
      state: :ended,
      result: result(result),
      provenance: provenance(ended[:provenance]),
      change_set: change_set(ended[:manifest])
    }
    |> drop_nil()
  end

  defp result(result) do
    result
    |> Map.take([:kind, :reason, :retryable, :never_started, :answer])
    |> Map.put(:check, check(get_in(result, [:work_product, :check])))
    |> drop_nil()
  end

  defp check(nil), do: nil

  defp check(check) do
    check
    |> Map.take([:command, :exit_status, :signal, :error, :timed_out, :duration_ms])
    |> Map.put(:output_tail, get_in(check, [:output, :tail]) || "")
    |> drop_nil()
  end

  defp provenance(nil), do: []

  defp provenance(provenance) do
    selection = provenance[:selection] || %{}

    [
      provenance
      |> Map.take([
        :provider,
        :harness,
        :harness_version,
        :runtime_build,
        :machine,
        :slot,
        :configured_model,
        :reported_model,
        :turn_id,
        :started_at,
        :ended_at
      ])
      |> Map.merge(%{profile: selection[:profile], policy_version: selection[:policy_version]})
      |> Map.update(:started_at, nil, &datetime/1)
      |> Map.update(:ended_at, nil, &datetime/1)
      |> drop_nil()
    ]
  end

  # Upload hands times over as ISO 8601 text; the contract's values are DateTimes (the HTTP
  # client checks them as such).
  defp datetime(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} -> at
      _ -> text
    end
  end

  defp datetime(other), do: other

  defp change_set(nil), do: nil

  # base: the frozen result's own (Upload's manifest/3), never invented here; a manifest
  # without one stays without one and the contract refuses it as invalid.
  defp change_set(%{roots: roots} = manifest),
    do:
      drop_nil(%{
        base: manifest[:base],
        roots: for(root <- roots, do: Map.take(root, [:root, :fingerprint, :entries]))
      })

  defp stop_on(outcome, lease_id, call) do
    case name(outcome) do
      "LeaseLost" ->
        :lease_lost

      _ ->
        reason = if is_map(outcome), do: Map.get(outcome, :reason), else: outcome

        Logger.warning(
          "upload #{lease_id}: the source answered #{call} #{name(outcome)} " <>
            "(#{inspect(reason)}); stopping"
        )

        :lease_lost
    end
  end

  # An outcome struct's own name: the last segment of its module.
  defp name(%module{}), do: module |> Module.split() |> List.last()
  defp name(other), do: inspect(other)

  defp drop_nil(map), do: for({k, v} <- map, v != nil, into: %{}, do: {k, v})
end
