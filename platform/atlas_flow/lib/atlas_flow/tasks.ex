defmodule AtlasFlow.Tasks do
  @moduledoc """
  What Flow answers through its `tasks` contract (`AtlasFlow.Boundary.Tasks`, plan
  2026-11-17 §3.3, F5a): the translation from Flow's own records to the contract's values.
  Reading only; nothing here writes a fact, submits, cancels or retries work.

  - **Tasks** are the `task` facts Flow writes (`AtlasFlow.Activities.Task`,
    `AtlasFlow.Runtime.Records`), linked `task_of` their subject, and each task's
    `task_attempt` facts, linked `attempt_of` it and `ran_on` its machinery. They are read
    over the Bus from the calling process (`AtlasFlow.Talk`), which must be attached. A
    subject's tasks are in the order Flow defined them (`TK-<subject>-<n>`, by `n`), a
    task's attempts oldest first (`TA-<task>-<n>`).
  - **Shown** is the safe-to-show part of a task (§3.2): what it is, where it is, how its
    current attempt ended (with the check), the base it started from and every attempt's
    provenance. The task's input and instructions are not shown.
  - **Unavailable**: when Facts does not answer, or holds a record that is not one, the
    answer is `unavailable` with a message, never an empty or partial list.
  - **Machinery status** asks the machinery's Runtime for its capacity
    (`AtlasFlow.Runtime.Client`, the configured one): `reachable` when it answered, with
    what it said and when; a machinery Flow has no configuration of is not reachable.
  """
  use AtlasFlow.Boundary.Tasks.Implementation

  alias AtlasFlow.Activities.Task, as: TaskActivity
  alias AtlasFlow.Boundary.Tasks, as: B
  alias AtlasFlow.Runtime.Config
  alias AtlasFlow.Talk

  @task "task"
  @attempt "task_attempt"
  @task_of "task_of"
  @attempt_of "attempt_of"
  @ran_on "ran_on"

  # The task fact's values that are shown as they are.
  @shown ~w(kind role profile state work_id attempt result_kind reason verdict answer
            base_id base_snapshot base_revision)

  @attempt_shown ~w(state result_kind provider harness harness_version configured_model
                    reported_model selection_reason conversation_id machine slot turn_id
                    started_at ended_at)

  @impl true
  def list_tasks(_client, %B.ListTasksInput{subject: subject}) do
    with {:ok, facts} <- facts(@task, %{"linked" => %{@task_of => subject}}),
         {:ok, tasks} <- each(sort(facts, "TK-" <> subject <> "-"), &task(&1, subject)) do
      B.Outcome.Tasks.new!(subject: subject, tasks: tasks)
    else
      {:error, message} -> unavailable(message)
    end
  end

  @impl true
  def get_task(_client, %B.GetTaskInput{task_id: id}) do
    with {:ok, fact} when fact != nil <- fact(@task, id),
         [subject | _] when is_binary(subject) <- List.wrap(get_in(fact, ["links", @task_of])),
         {:ok, task} <- task(fact, subject) do
      B.Outcome.Found.new!(Map.from_struct(task))
    else
      {:ok, nil} -> %B.Outcome.NotFound{}
      {:error, message} -> unavailable(message)
      _no_subject -> unavailable("Flow's record of #{id} names no subject")
    end
  end

  @impl true
  def machinery_status(_client, %B.MachineryStatusInput{machinery: name}) do
    with {:ok, machinery} <- Config.fetch(name),
         {:capacity, capacity} <- TaskActivity.client().capacity(machinery) do
      B.Outcome.Status.new!(
        machinery: name,
        reachable: true,
        last_capacity: capacity(capacity),
        last_seen: DateTime.utc_now() |> DateTime.truncate(:second)
      )
    else
      _unconfigured_unreachable_or_refused ->
        B.Outcome.Status.new!(machinery: name, reachable: false)
    end
  end

  # -- Translation -------------------------------------------------------------------------

  defp task(%{"key" => key} = fact, subject) do
    values = fact["values"] || %{}

    with {:ok, attempts} <- facts(@attempt, %{"linked" => %{@attempt_of => key}}),
         {:ok, attempts} <- each(sort(attempts, "TA-" <> key <> "-"), &attempt(&1, key)) do
      shown =
        values
        |> Map.take(@shown)
        |> Map.merge(%{
          "task_id" => key,
          "subject" => subject,
          "check" => check(values),
          "result_fingerprints" => fingerprints(values["result_fingerprints"]),
          "based_on" => fingerprints(values["based_on"]),
          "attempts" => attempts
        })

      build(B.Task, shown, key)
    end
  end

  defp attempt(%{"key" => key} = fact, task_key) do
    shown =
      (fact["values"] || %{})
      |> Map.take(@attempt_shown)
      |> Map.put("attempt", number(key, "TA-" <> task_key <> "-"))
      |> Map.put("machinery", List.first(List.wrap(get_in(fact, ["links", @ran_on]))))

    build(B.TaskAttempt, shown, key)
  end

  defp check(values) do
    check = %{
      "exit_status" => values["check_exit_status"],
      "ending" => values["check_ending"],
      "output_tail" => values["check_output_tail"]
    }

    if Enum.all?(check, fn {_, v} -> v == nil end), do: nil, else: check
  end

  # Records keep fingerprints as one fingerprint, or as JSON: a list of them, each a text
  # or an object with its `fingerprint` (AtlasFlow.Runtime.Records).
  defp fingerprints(nil), do: []
  defp fingerprints(""), do: []

  defp fingerprints(text) when is_binary(text) do
    case JSON.decode(text) do
      {:ok, list} when is_list(list) ->
        list |> Enum.map(&fingerprint/1) |> Enum.reject(&is_nil/1)

      _ ->
        [text]
    end
  end

  defp fingerprints(_other), do: []

  defp fingerprint(%{"fingerprint" => f}) when is_binary(f), do: f
  defp fingerprint(f) when is_binary(f), do: f
  defp fingerprint(_), do: nil

  defp capacity(capacity) do
    params = %{
      "accepting" => capacity["accepting"],
      "free_slots" => get_in(capacity, ["slots", "free"]),
      "profiles" => profiles(capacity["profiles"])
    }

    # What the machinery said, when it is a capacity; nothing when it is not.
    case B.Capacity.new(params) do
      {:ok, capacity} -> capacity
      {:error, _} -> nil
    end
  end

  # Per profile, as a list of entries (the Runtime's contract) or by name (as Flow's
  # submit reads it, `AtlasFlow.Activities.Task.room?/2`), ordered by profile.
  defp profiles(profiles) when is_map(profiles),
    do: profiles(for {name, p} <- profiles, is_map(p), do: Map.put(p, "profile", name))

  defp profiles(profiles) when is_list(profiles) do
    for(p <- profiles, is_map(p), do: Map.take(p, ["profile", "available", "reason"]))
    |> Enum.sort_by(&to_string(&1["profile"]))
  end

  defp profiles(_), do: []

  # Nil values are left out: an optional field Flow has not recorded yet.
  defp build(module, values, key) do
    case module.new(Map.reject(values, fn {_, v} -> v == nil end)) do
      {:ok, value} -> {:ok, value}
      {:error, _reasons} -> {:error, "Flow's record of #{key} is not readable"}
    end
  end

  # -- Facts -------------------------------------------------------------------------------

  defp fact(kind, key) do
    case read(kind, %{"key" => key}) do
      %{"fact" => nil} -> {:ok, nil}
      %{"fact" => %{"key" => ^key} = fact} -> {:ok, fact}
      _ -> {:error, "Facts did not answer"}
    end
  end

  defp facts(kind, content) do
    case read(kind, content) do
      %{"facts" => facts} when is_list(facts) -> {:ok, Enum.filter(facts, &keyed?/1)}
      _ -> {:error, "Facts did not answer"}
    end
  end

  defp keyed?(%{"key" => key}) when is_binary(key), do: true
  defp keyed?(_), do: false

  # A caller that is not attached to the Bus cannot read: the same as no answer.
  defp read(kind, content) do
    Talk.read(kind, Map.put(content, "plain", true))
  rescue
    MatchError -> %{"error" => "not attached to the Bus"}
  end

  # -- Order -------------------------------------------------------------------------------

  # By the number after `prefix`; a key without one last, by key.
  defp sort(facts, prefix),
    do: Enum.sort_by(facts, &{number(&1["key"], prefix) || :infinity, &1["key"]})

  defp number(key, prefix) do
    with true <- String.starts_with?(key, prefix),
         {n, ""} when n > 0 <- Integer.parse(String.replace_prefix(key, prefix, "")) do
      n
    else
      _ -> nil
    end
  end

  defp each(list, fun) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, done} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | done]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, done} -> {:ok, Enum.reverse(done)}
      error -> error
    end
  end

  defp unavailable(message), do: B.Outcome.Unavailable.new!(message: message)
end
