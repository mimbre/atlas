defmodule AtlasRuntime.Availability do
  @moduledoc """
  Quota evidence per harness, `availability.json` in the Runtime home (design §6, §7).

  The Runtime records native evidence here; a human may also mark a harness out (operator
  evidence, for example Codex while it has no credits) or re-enable one by editing the file
  locally. Each entry keeps the former `backends.json` `claude_quota` shape: `evidence`,
  `turn_id`, `observed_at` and `reenabled_at`. A harness is out until the evidence's
  positive `resetsAt` (Unix seconds) has passed, or until `reenabled_at` is set; without a
  usable reset it stays out until re-enabled.

  The `claude_quota` of an existing `backends.json` is imported once, at service start,
  when no `availability.json` exists yet; `backends.json` is never read again after that.
  Its `preferred`/`fallback` pair is carried as `preferences`: until the CLI cutover (D3) a
  start with neither a profile nor a backend still follows it (`preferences/1`).
  Unreadable or invalid evidence fails visibly instead of selecting another option.
  """

  @file_name "availability.json"
  @legacy "backends.json"
  @format_version 1
  @harnesses ~w(claude codex)

  def path(dir), do: Path.join(dir, @file_name)
  def empty, do: %{"format_version" => @format_version, "quota" => %{}}

  @doc "Reads and validates `availability.json`; absent means every harness is available."
  def load(dir) do
    case File.read(path(dir)) do
      {:ok, bytes} -> validate!(JSON.decode!(bytes))
      {:error, :enoent} -> empty()
      {:error, reason} -> raise("Cannot read #{@file_name}: #{:file.format_error(reason)}")
    end
  rescue
    error in JSON.DecodeError ->
      raise("Invalid #{@file_name}: #{Exception.message(error)}")
  end

  @doc "Writes atomically: a temporary file renamed into place."
  def persist(dir, availability) do
    validate!(availability)
    target = path(dir)
    File.write!(target <> ".tmp", JSON.encode!(availability))
    File.rename!(target <> ".tmp", target)
    :ok
  end

  @doc """
  Imports the quota record and the preferred/fallback pair of a former `backends.json`
  once. A no-op when `availability.json` exists or there is no `backends.json`.
  """
  def import_legacy!(dir) do
    legacy = Path.join(dir, @legacy)

    if not File.exists?(path(dir)) and File.exists?(legacy) do
      former =
        case JSON.decode(File.read!(legacy)) do
          {:ok, %{} = former} -> former
          _ -> raise("Cannot import #{@legacy}: not a JSON object")
        end

      quota = if entry = former["claude_quota"], do: %{"claude" => entry}, else: %{}

      availability =
        case former do
          %{"preferred" => %{} = preferred, "fallback" => %{} = fallback} ->
            Map.put(empty(), "preferences", %{"preferred" => preferred, "fallback" => fallback})

          _ ->
            empty()
        end

      persist(dir, %{availability | "quota" => quota})
    end

    :ok
  end

  @doc "The imported legacy preferred/fallback pair (claude then codex targets), or nil."
  def preferences(availability), do: availability["preferences"]

  @doc "`:available`, or `{:out, until}` with `until` in Unix seconds or nil when unknown."
  def status(availability, harness, now) do
    case availability["quota"][harness] do
      nil ->
        :available

      %{"reenabled_at" => enabled} when is_integer(enabled) ->
        :available

      %{"evidence" => %{"resetsAt" => reset}} when is_number(reset) and reset > 0 ->
        if reset <= now, do: :available, else: {:out, ceil(reset)}

      _ ->
        {:out, nil}
    end
  end

  @doc """
  Records exact native weekly-quota evidence for `harness` from `turn_id`, re-reading the
  file first so a local edit is kept. Returns the stored entry, or nil when the evidence is
  not weekly quota (nothing is written).
  """
  def record_quota(dir, harness, evidence, turn_id, now) when harness in @harnesses do
    if weekly_quota?(evidence) do
      reset = evidence["resetsAt"]
      evidence = Map.put(evidence, "resetsAt", if(positive?(reset), do: reset, else: nil))

      entry = %{
        "evidence" => evidence,
        "turn_id" => turn_id,
        "observed_at" => now,
        "reenabled_at" => nil
      }

      availability = load(dir)
      persist(dir, put_in(availability, ["quota", harness], entry))
      entry
    end
  end

  @doc "Only a rejected seven-day window without usable overage is weekly quota."
  def weekly_quota?(%{"status" => "rejected", "rateLimitType" => "seven_day"} = info),
    do: info["isUsingOverage"] != true and info["overageStatus"] != "allowed"

  def weekly_quota?(_), do: false

  @doc "A view for `preferences`: the file, plus each harness's current status."
  def view(availability, now) do
    status =
      Map.new(@harnesses, fn harness ->
        case status(availability, harness, now) do
          :available -> {harness, %{"available" => true}}
          {:out, until} -> {harness, %{"available" => false, "until" => iso(until)}}
        end
      end)

    Map.put(availability, "status", status)
  end

  defp iso(nil), do: nil
  defp iso(seconds), do: DateTime.to_iso8601(DateTime.from_unix!(seconds))

  def validate!(%{"format_version" => @format_version, "quota" => quota} = availability)
      when is_map(quota) do
    extra = Map.keys(availability) -- ["format_version", "quota", "preferences"]
    if extra != [], do: raise("Invalid #{@file_name}: unknown fields #{inspect(extra)}")
    if Map.has_key?(availability, "preferences"), do: preferences!(availability["preferences"])

    Enum.each(quota, fn {harness, entry} ->
      if harness not in @harnesses, do: raise("Unknown harness #{inspect(harness)} in quota")
      entry!(harness, entry)
    end)

    availability
  end

  def validate!(_),
    do: raise("Invalid #{@file_name}: expected format_version #{@format_version} and quota")

  defp entry!(
         harness,
         %{"evidence" => evidence, "turn_id" => turn, "observed_at" => at, "reenabled_at" => on} =
           entry
       )
       when map_size(entry) == 4 and is_integer(at) and (is_nil(on) or is_integer(on)) do
    cond do
      # Native evidence, as `backends.json` kept it for Claude.
      harness == "claude" and is_binary(turn) and weekly_quota?(evidence) and
          (is_nil(evidence["resetsAt"]) or positive?(evidence["resetsAt"])) ->
        :ok

      # A human's mark, written locally: no turn observed it.
      is_nil(turn) and operator?(evidence) ->
        :ok

      true ->
        raise("Invalid quota evidence for #{harness}")
    end
  end

  defp entry!(harness, _), do: raise("Invalid quota record for #{harness}")

  # The former backends.json pair: Claude preferred, Codex as its quota fallback.
  defp preferences!(%{"preferred" => preferred, "fallback" => fallback} = pair)
       when map_size(pair) == 2 do
    if not (target?(preferred, "claude") and target?(fallback, "codex")),
      do: raise("Invalid preferences: expected a claude then codex {backend, model} pair")
  end

  defp preferences!(_), do: raise("Invalid preferences: expected preferred and fallback only")

  defp target?(%{"backend" => backend, "model" => model} = target, backend),
    do:
      map_size(target) == 2 and
        (is_nil(model) or
           (is_binary(model) and
              Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._:\/\[\]-]{0,199}\z/, model)))

  defp target?(_, _), do: false

  defp operator?(%{"source" => "operator", "note" => note, "resetsAt" => reset} = evidence),
    do:
      map_size(evidence) == 3 and is_binary(note) and note != "" and
        (is_nil(reset) or positive?(reset))

  defp operator?(_), do: false

  defp positive?(value), do: is_number(value) and value > 0
end
