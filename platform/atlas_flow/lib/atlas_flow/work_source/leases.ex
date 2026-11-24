defmodule AtlasFlow.WorkSource.Leases do
  @moduledoc """
  The task fact as the work source's lease record (plan m3 §2.3, §3.3): reading it by
  lease, and the fenced write every lease change goes through.

  **Lease id.** `<task key>~<attempt>~<22 base64url characters of 16 random bytes>`:
  opaque to the Runtime, unguessable, and it names its task fact without an index (a task
  key never holds `~`).

  **Fenced write (§2.3).** A change that must hold only while lease `L` is current:

  - sets `lease_id: L` (unchanged, or the new lease at a grant) with its other fields;
  - sends the `version` it read, and `was` with every field and link it sets at its read
    value, so Facts applies it on a later version only when none of them changed meanwhile;
  - for Delivery's writes, also sets `lease_state` (unchanged or new), so a Dispatch
    `expired` or `lost` write in between refuses it.

  On a refusal the writer reads the fact again and decides again, at most 3 times
  (`update/3`).

  **Fenced lease (§3.2).** A lease is fenced for a caller when the fact's `lease_id` is not
  the request's, its `runtime` is not the caller's, or its `lease_state` is `expired` or
  `lost`.

  Every function here talks to Facts from the calling process, which must be attached to
  the Bus.
  """

  alias AtlasFlow.Talk

  @task "task"
  @attempt "task_attempt"
  @tries 3
  @fenced_states ~w(expired lost)

  @doc "The kind of the facts leases are kept on."
  def task_kind, do: @task

  @doc "The kind of the attempt records."
  def attempt_kind, do: @attempt

  @doc "A new lease id for attempt `attempt` of the task `task_key`."
  @spec new_id(String.t(), pos_integer()) :: String.t()
  def new_id(task_key, attempt) when is_binary(task_key) and is_integer(attempt) do
    random = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    Enum.join([task_key, attempt, random], "~")
  end

  @doc "The task key and attempt a lease id names: `{:ok, task_key, attempt}` or `:error`."
  @spec parse(term()) :: {:ok, String.t(), pos_integer()} | :error
  def parse(lease_id) when is_binary(lease_id) do
    with [task_key, attempt, random] when task_key != "" and byte_size(random) == 22 <-
           String.split(lease_id, "~"),
         {n, ""} when n > 0 <- Integer.parse(attempt) do
      {:ok, task_key, n}
    else
      _ -> :error
    end
  end

  def parse(_), do: :error

  @doc "The task fact (`{:ok, fact}`, `{:ok, nil}` when there is none) or `{:error, why}`."
  @spec read(String.t()) :: {:ok, map() | nil} | {:error, term()}
  def read(task_key) do
    case Talk.read(@task, %{"key" => task_key, "plain" => true}) do
      %{"fact" => %{"values" => values} = fact} when is_map(values) -> {:ok, fact}
      %{"fact" => nil} -> {:ok, nil}
      other -> {:error, {:unreadable, task_key, other}}
    end
  end

  @doc "Every task fact, or `{:error, why}`."
  @spec all() :: {:ok, [map()]} | {:error, term()}
  def all do
    case Talk.read(@task, %{"plain" => true}) do
      %{"facts" => facts} when is_list(facts) -> {:ok, facts}
      other -> {:error, {:unreadable, @task, other}}
    end
  end

  @doc "A value of the fact (nil when absent)."
  def value(nil, _field), do: nil
  def value(fact, field), do: (fact["values"] || %{})[field]

  @doc "The keys the fact links through `relation` (`[]` when none)."
  def links(nil, _relation), do: []
  def links(fact, relation), do: List.wrap((fact["links"] || %{})[relation])

  @doc """
  Whether lease `lease_id` is fenced for the Runtime `runtime_id` on `fact` (§3.2): no
  fact, another lease, another Runtime, or `lease_state` expired or lost.
  """
  @spec fenced?(map() | nil, String.t(), String.t()) :: boolean()
  def fenced?(nil, _lease_id, _runtime_id), do: true

  def fenced?(fact, lease_id, runtime_id) do
    value(fact, "lease_id") != lease_id or value(fact, "runtime") != runtime_id or
      value(fact, "lease_state") in @fenced_states
  end

  @doc """
  The fenced change of `fact` (§2.3): `values` and `links` with `lease_id` (the fact's own
  unless `values` names a new one), the read `version` and `was` for every field and link
  it sets.
  """
  @spec change(map(), map(), map(), String.t()) :: map()
  def change(fact, values, links \\ %{}, by \\ "flow") do
    values = Map.put_new(values, "lease_id", value(fact, "lease_id"))

    was =
      Map.merge(
        Map.new(Map.keys(values), &{&1, value(fact, &1)}),
        Map.new(Map.keys(links), &{&1, links(fact, &1)})
      )

    content = %{
      "op" => "change",
      "key" => fact["key"],
      "values" => values,
      "version" => fact["version"],
      "was" => was,
      "by" => by
    }

    if links == %{}, do: content, else: Map.put(content, "links", links)
  end

  @doc """
  Reads the task fact and lets `decide` answer on it, writing what it asks, at most 3
  times. `decide.(fact)` answers `{:write, values, links, reply}` (a fenced change of the
  fact read; `reply` once it is stored, or `reply.()` when it is a function) or `{:reply,
  reply}` (no write). A refused or unanswered write is read and decided again; after the
  last try the answer is `{:error, :fence_contended}`.
  """
  def update(task_key, decide, by \\ "flow"), do: update(task_key, decide, by, @tries)

  defp update(_task_key, _decide, _by, 0), do: {:error, :fence_contended}

  defp update(task_key, decide, by, tries) do
    with {:ok, fact} <- read(task_key) do
      case decide.(fact) do
        {:write, values, links, reply} ->
          case Talk.put(@task, change(fact, values, links, by)) do
            {:stored, _} -> if is_function(reply, 0), do: reply.(), else: reply
            _refused_or_lost -> update(task_key, decide, by, tries - 1)
          end

        {:reply, reply} ->
          reply
      end
    end
  end

  @doc """
  The pins a result store rebuilds from (§3.4 "Index"): `{task_key, result_manifest}` of
  every task whose `result_state` is complete and whose `state` is not abandoned. Raises
  when Facts does not answer, so a store never rebuilds from nothing.
  """
  @spec pins() :: [{String.t(), String.t()}]
  def pins do
    case all() do
      {:ok, facts} ->
        for fact <- facts,
            value(fact, "result_state") == "complete",
            value(fact, "state") != "abandoned",
            sha = value(fact, "result_manifest"),
            is_binary(sha),
            do: {fact["key"], sha}

      {:error, why} ->
        raise "the result store cannot rebuild its pins: #{inspect(why)}"
    end
  end
end
