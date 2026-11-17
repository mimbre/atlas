defmodule AtlasFlow.Runtime.Records do
  @moduledoc """
  Flow's own records of its Runtime work (plan 2026-11-17 §3.2, §6 F1.6; client obligation
  7): from each work snapshot (`AtlasFlow.Runtime.Client`'s work, string keys) it updates
  the `task` fact and writes one `task_attempt` fact per attempt, with provenance.

  The caller (the `task` activity, F1.3) has written the task fact first (its intent,
  obligation 2) and applies snapshots in `revision` order (obligation 5); `record/4` is
  what it calls with each one. No state reads these facts (§3.2), so a write here never
  drives a run.

  **Task fact.** It takes from the snapshot what the Runtime says: `work_id`, the current
  `attempt`, and from that attempt's result `result_kind`, `reason`, `answer`, the check
  (`check_exit_status`, `check_ending`, `check_output_tail`), `result_fingerprints` and
  `based_on`. `state` (where the task is, as Flow keeps it) and the task's intent fields
  stay the caller's. On a newer attempt, the earlier attempt's result fields are cleared
  (that result stays in its own attempt record); a snapshot of an earlier attempt than the
  fact's changes nothing, and one without attempts leaves the attempt and its result alone.

  **Attempt facts.** Attempt `n` of task `TK-…` is `TA-<task key>-<n>`, linked `attempt_of`
  the task and `ran_on` the machinery. An earlier attempt's record is never overwritten:

  - each attempt writes only its own key, created once;
  - while its attempt runs, a record only gains: `state` and `result_kind` move on, and a
    field not yet recorded is filled in; a recorded provenance field is never replaced;
  - once it holds a terminal state, it is never written again.

  The reported model is kept as the harness reported it, also when it differs from the
  configured one: the difference is the record.
  """

  alias AtlasFlow.Talk

  @task "task"
  @attempt "task_attempt"
  @terminal ~w(completed failed crashed interrupted cancelled returned)

  # The task's fields that come from its current attempt's result.
  @result ~w(result_kind reason answer check_exit_status check_ending check_output_tail
             result_fingerprints based_on)

  # What may move on while an attempt runs; every other field is written once.
  @progress ~w(state result_kind)

  @type summary :: %{task: :changed | :unchanged, attempts: %{pos_integer() => atom()}}

  @doc """
  Record `work` (a snapshot) for the task `task_key`, run on the machinery `machinery` (its
  Facts key, the name in Flow's configuration). `{:ok, summary}` tells what was written:
  the task `:changed` or `:unchanged`, and per attempt `:created`, `:changed`, `:unchanged`
  or `:kept` (terminal, never written again). `{:error, reason}` when Facts did not store
  a write or the task fact is missing; calling again with the same snapshot is safe.

  Options: `by:` the writer (default `"flow"`).
  """
  @spec record(String.t(), String.t(), map(), keyword()) :: {:ok, summary()} | {:error, term()}
  def record(task_key, machinery, %{"work_id" => _} = work, opts \\ [])
      when is_binary(task_key) and is_binary(machinery) do
    by = Keyword.get(opts, :by, "flow")

    # The task first: without its fact (the caller's intent) nothing is recorded.
    with {:ok, task} <- task_fact(task_key),
         {:ok, attempts} <- record_attempts(task_key, machinery, work, by),
         {:ok, task} <- record_task(task, work, by) do
      {:ok, %{task: task, attempts: attempts}}
    end
  end

  @doc "The key of attempt `n` of the task `task_key`: `TA-<task key>-<n>`."
  @spec attempt_key(String.t(), pos_integer()) :: String.t()
  def attempt_key(task_key, n) when is_integer(n) and n > 0,
    do: "TA-" <> task_key <> "-" <> Integer.to_string(n)

  @doc "The task fact's values a snapshot gives (no nil values)."
  @spec task_values(map()) :: map()
  def task_values(work) do
    current = current(work)
    result = (current && current["result"]) || %{}
    product = result["work_product"] || %{}
    check = product["check"] || %{}

    %{
      "work_id" => work["work_id"],
      "attempt" => current && current["attempt"],
      "result_kind" => result["kind"],
      "reason" => result["reason"],
      "answer" => result["answer"],
      "check_exit_status" => check["exit_status"],
      "check_ending" => ending(check),
      "check_output_tail" => get_in(check, ["output", "tail"]),
      "result_fingerprints" => fingerprints(get_in(product, ["frozen", "fingerprints"])),
      "based_on" => based_on(get_in(product, ["based_on", "fingerprints"]))
    }
    |> compact()
  end

  @doc "The `task_attempt` values of one attempt of a snapshot, with its provenance (no nil values)."
  @spec attempt_values(map()) :: map()
  def attempt_values(attempt) do
    p = attempt["provenance"] || %{}
    times = attempt["timestamps"] || %{}

    %{
      "turn_id" => attempt["turn_id"] || p["turn_id"],
      "state" => attempt["state"],
      "result_kind" => get_in(attempt, ["result", "kind"]),
      "provider" => p["provider"],
      "harness" => p["harness"],
      "harness_version" => p["harness_version"],
      "configured_model" => p["configured_model"],
      "reported_model" => p["reported_model"],
      "selection_reason" => get_in(p, ["selection", "reason"]),
      "conversation_id" => p["conversation_id"],
      "machine" => p["machine"],
      "slot" => p["slot"] || attempt["slot"],
      "started_at" => p["started_at"] || times["started_at"],
      "ended_at" => p["ended_at"] || times["ended_at"]
    }
    |> compact()
  end

  # -- Attempts ----------------------------------------------------------------------------

  defp record_attempts(task_key, machinery, work, by) do
    (work["attempts"] || [])
    |> Enum.filter(&match?(%{"attempt" => n} when is_integer(n) and n > 0, &1))
    |> Enum.uniq_by(& &1["attempt"])
    |> Enum.sort_by(& &1["attempt"])
    |> Enum.reduce_while({:ok, %{}}, fn attempt, {:ok, done} ->
      case record_attempt(task_key, machinery, attempt, by) do
        {:ok, outcome} -> {:cont, {:ok, Map.put(done, attempt["attempt"], outcome)}}
        error -> {:halt, error}
      end
    end)
  end

  defp record_attempt(task_key, machinery, attempt, by) do
    key = attempt_key(task_key, attempt["attempt"])
    values = attempt_values(attempt)

    with {:ok, fact} <- read(@attempt, key) do
      case fact do
        nil ->
          content = %{
            "op" => "create",
            "key" => key,
            "values" => values,
            "links" => %{"attempt_of" => [task_key], "ran_on" => [machinery]},
            "by" => by
          }

          # Under a stable id: a lost answer is sent again and stored once.
          put(@attempt, content, digest([key, "create"]), :created)

        %{"values" => stored} = fact ->
          if stored["state"] in @terminal do
            {:ok, :kept}
          else
            change(@attempt, fact, gained(stored, values), by)
          end
      end
    end
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

  # -- Task --------------------------------------------------------------------------------

  defp record_task(%{"values" => stored} = fact, work, by) do
    values = task_values(work)

    if stale?(stored, values) do
      {:ok, :unchanged}
    else
      changed =
        stored
        |> cleared(values)
        |> Map.merge(values)
        |> Map.reject(fn {field, value} -> stored[field] == value end)

      change(@task, fact, changed, by)
    end
  end

  # On a newer attempt, the earlier attempt's result fields it does not give are cleared
  # (nil clears in Facts): its result is in its own attempt record. A snapshot without an
  # attempt names no newer one, so it clears nothing (the held attempt keeps its result).
  defp cleared(stored, %{"attempt" => given}) when is_integer(given) do
    if given != stored["attempt"],
      do: for(field <- @result, stored[field] != nil, into: %{}, do: {field, nil}),
      else: %{}
  end

  defp cleared(_stored, _values), do: %{}

  defp task_fact(task_key) do
    case read(@task, task_key) do
      {:ok, nil} -> {:error, {:task_missing, task_key}}
      other -> other
    end
  end

  # A snapshot of an earlier attempt than the fact's. (One of the same attempt cannot take
  # a result away: within an attempt, a field the snapshot does not give is kept.)
  defp stale?(%{"attempt" => held}, %{"attempt" => given})
       when is_integer(held) and is_integer(given),
       do: given < held

  defp stale?(_stored, _values), do: false

  # -- Facts -------------------------------------------------------------------------------

  defp change(_kind, _fact, values, _by) when map_size(values) == 0, do: {:ok, :unchanged}

  defp change(kind, fact, values, by) do
    content = %{
      "op" => "change",
      "key" => fact["key"],
      "values" => values,
      "version" => fact["version"],
      "was" => Map.new(Map.keys(values), &{&1, fact["values"][&1]}),
      "by" => by
    }

    put(kind, content, digest([fact["key"], fact["version"], values]), :changed)
  end

  defp put(kind, content, id, outcome) do
    case Talk.put(kind, content, id) do
      {:stored, _position} -> {:ok, outcome}
      {:refused, reasons} -> {:error, {:refused, kind, content["key"], reasons}}
      {:error, reason} -> {:error, {reason, kind, content["key"]}}
    end
  end

  defp read(kind, key) do
    case Talk.read(kind, %{"key" => key, "plain" => true}) do
      %{"fact" => %{"values" => values} = fact} when is_map(values) -> {:ok, fact}
      %{"fact" => nil} -> {:ok, nil}
      %{"error" => error} -> {:error, {:unreadable, kind, key, error}}
      other -> {:error, {:unreadable, kind, key, other}}
    end
  end

  # -- Snapshot fields ---------------------------------------------------------------------

  defp current(work) do
    (work["attempts"] || [])
    |> Enum.filter(&match?(%{"attempt" => n} when is_integer(n), &1))
    |> Enum.max_by(& &1["attempt"], fn -> nil end)
  end

  defp ending(check) do
    cond do
      check["timed_out"] == true -> "timed_out"
      check["cancelled"] == true -> "cancelled"
      check["interrupted"] == true -> "interrupted"
      true -> nil
    end
  end

  defp fingerprints(list) when is_list(list) and list != [], do: JSON.encode!(list)
  defp fingerprints(_), do: nil

  # One root: its fingerprint, which a review compares with; several: all of them (JSON).
  defp based_on([%{"fingerprint" => fingerprint}]) when is_binary(fingerprint), do: fingerprint
  defp based_on(list), do: fingerprints(list)

  defp compact(values), do: Map.reject(values, fn {_, v} -> v in [nil, ""] end)

  defp digest(term),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(term)) |> Base.encode16(case: :lower)
end
