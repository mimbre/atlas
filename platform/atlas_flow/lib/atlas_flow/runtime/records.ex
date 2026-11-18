defmodule AtlasFlow.Runtime.Records do
  @moduledoc """
  Flow's records of its leases' attempts (plan m3 §3.5; Flow plan obligation 7): from the
  reports a Runtime sends on a lease, one `task_attempt` fact per lease, with provenance.
  Delivery calls it, after the task fact holds the report; it moves to `work_source/` with
  A5 (Q1).

  **Key and links.** The attempt of lease `n` of task `TK-…` is `TA-<task key>-<n>`, linked
  `attempt_of` the task and, when the Runtime's id names a fact of the machinery kind
  (Q7), `ran_on` it.

  **Written once per lease, never overwritten:**

  - `refused` creates it (state `refused`); `started` creates it (state `running`);
    `ended` fills in the result and the provenance of its last turn, creating it when no
    `started` came (`accepted` → `ended`);
  - while it runs, a record only gains: `state` and `result_kind` move on, and a field not
    yet recorded is filled in; a recorded provenance field is never replaced;
  - once it holds a terminal state, it is never written again; neither is an earlier
    lease's record by a later one.

  **Ended by Flow's own fence (F10, `lost/6`).** When Dispatch fences a lease (`expired`
  or `lost`), its running record ends `state: lost`, `result_kind` the fence's cause
  (`lease_end_cause`), and `ended_at` only when the caller gives a time (Delivery's live
  path, on Dispatch's notice; its boot repair gives none) and the record has none yet.
  `lost` is a terminal state like the others. A fence never creates a record (a lease
  fenced before `started` has none) and never writes another lease's record.

  Each write goes under a stable message id, so a lost answer is sent again and stored
  once. Writes go from the calling process: Delivery's endpoint, the only attempt writer.
  """

  alias AtlasFlow.Talk
  alias AtlasFlow.WorkSource.{Leases, Translate}

  @terminal ~w(refused completed failed crashed interrupted cancelled returned lost)
  @progress ~w(state result_kind)

  @doc "The key of the attempt of lease `n` of the task `task_key`: `TA-<task key>-<n>`."
  @spec attempt_key(String.t(), pos_integer()) :: String.t()
  def attempt_key(task_key, n) when is_integer(n) and n > 0,
    do: "TA-" <> task_key <> "-" <> Integer.to_string(n)

  @doc """
  Records `report` (JSON terms, `AtlasFlow.WorkSource.Translate.normal/1`) of lease
  `lease_id`, attempt `n` of `task_key`. `ran_on` is the machinery fact's key, or nil.
  `{:ok, :created | :changed | :unchanged | :kept}`, `{:ok, :none}` for a report that makes
  no record (`accepted`), or `{:error, why}`.
  """
  @spec record(String.t(), pos_integer(), String.t(), map(), String.t() | nil, String.t()) ::
          {:ok, atom()} | {:error, term()}
  def record(task_key, n, lease_id, report, ran_on, by \\ "flow")

  def record(_task_key, _n, _lease_id, %{"state" => "accepted"}, _ran_on, _by), do: {:ok, :none}

  def record(task_key, n, lease_id, report, ran_on, by) do
    key = attempt_key(task_key, n)
    values = Map.put(Translate.attempt_values(report), "lease_id", lease_id)

    case read(key) do
      {:ok, nil} ->
        links = %{"attempt_of" => [task_key]}
        links = if ran_on, do: Map.put(links, "ran_on", [ran_on]), else: links

        content = %{
          "op" => "create",
          "key" => key,
          "values" => values,
          "links" => links,
          "by" => by
        }

        put(content, digest([key, "create"]), :created)

      {:ok, %{"values" => stored} = fact} ->
        cond do
          stored["lease_id"] not in [nil, lease_id] -> {:ok, :kept}
          stored["state"] in @terminal -> {:ok, :kept}
          true -> change(fact, gained(stored, values), by)
        end

      error ->
        error
    end
  end

  @doc """
  Ends the record of lease `lease_id`, attempt `n` of `task_key`, that Flow's fence ended
  with `cause` (the lease's `lease_end_cause`): `state: lost`, `result_kind` `cause`, and
  `ended_at` `at` when `at` is given and the record has none. `{:ok, :changed |
  :unchanged}`; `{:ok, :kept}` for a terminal record or another lease's; `{:ok, :none}`
  when there is no record (none is created); or `{:error, why}`.
  """
  @spec lost(String.t(), pos_integer(), String.t(), String.t(), DateTime.t() | nil, String.t()) ::
          {:ok, atom()} | {:error, term()}
  def lost(task_key, n, lease_id, cause, at, by \\ "flow") do
    case read(attempt_key(task_key, n)) do
      {:ok, nil} ->
        {:ok, :none}

      {:ok, %{"values" => stored} = fact} ->
        cond do
          stored["lease_id"] not in [nil, lease_id] -> {:ok, :kept}
          stored["state"] in @terminal -> {:ok, :kept}
          true -> change(fact, gained(stored, ending(lease_id, cause, at)), by)
        end

      error ->
        error
    end
  end

  # `ended_at` is not a progress field: `gained/2` keeps one the record already holds.
  defp ending(lease_id, cause, at) do
    values = %{"state" => "lost", "result_kind" => cause, "lease_id" => lease_id}
    if at, do: Map.put(values, "ended_at", DateTime.to_iso8601(at)), else: values
  end

  # What a running attempt's record gains: progress fields that moved on, and fields not
  # recorded yet. A recorded field other than progress is never replaced.
  defp gained(stored, values) do
    Map.filter(values, fn {field, value} ->
      case stored[field] do
        nil -> true
        ^value -> false
        _other -> field in @progress
      end
    end)
  end

  defp change(_fact, values, _by) when map_size(values) == 0, do: {:ok, :unchanged}

  defp change(fact, values, by) do
    content = %{
      "op" => "change",
      "key" => fact["key"],
      "values" => values,
      "version" => fact["version"],
      "was" => Map.new(Map.keys(values), &{&1, fact["values"][&1]}),
      "by" => by
    }

    put(content, digest([fact["key"], fact["version"], values]), :changed)
  end

  defp put(content, id, outcome) do
    case Talk.put(Leases.attempt_kind(), content, id) do
      {:stored, _position} -> {:ok, outcome}
      {:refused, reasons} -> {:error, {:refused, content["key"], reasons}}
      {:error, reason} -> {:error, {reason, content["key"]}}
    end
  end

  defp read(key) do
    case Talk.read(Leases.attempt_kind(), %{"key" => key, "plain" => true}) do
      %{"fact" => %{"values" => values} = fact} when is_map(values) -> {:ok, fact}
      %{"fact" => nil} -> {:ok, nil}
      other -> {:error, {:unreadable, key, other}}
    end
  end

  defp digest(term),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(term)) |> Base.encode16(case: :lower)
end
