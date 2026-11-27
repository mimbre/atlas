defmodule AtlasFlow.Health do
  @moduledoc """
  What Flow says about its own health, for Control's health and machines pages
  (IS-Atlas-117): when Flow's round was due and when it finished, when each Runtime last
  polled Dispatch and what that poll said of it, and the work waiting for a Runtime.
  Attached to the Bus as `flow/health`; a `request` `_health` is answered with

      %{"flow" => %{"due" => due of the round now stepping, or nil,
                    "next_due" => when the next round is due, or nil,
                    "last_due" => due of the last finished round, or nil,
                    "last_finished" => when it finished, or nil},
        "runtimes" => [%{"runtime" => id, "polled_at" => when,
                         "build" => its build, "incarnation" => its incarnation,
                         "incarnation_since" => its first poll in that incarnation,
                         "poll_max" => the longest Dispatch holds a poll, in seconds}],
        "queue" => [%{"task" => key, "title" => text, "profile" => profile,
                      "subject_kind" => kind, "subject_key" => key, "since" => when}] or nil,
        "at" => now}

  every moment ISO 8601 in UTC; what a poll did not say is left out. Whether that is late
  is Control's to say. The queue is Dispatch's ready set less what a lease holds, oldest
  first: the tasks a Runtime may take next. It is nil until Dispatch has read the ready
  set and leases, and after this process restarts until Dispatch reports them again.

  The Engine and Dispatch write what they know into this process's table as it happens
  (`round/2`, `polled/4`, `queue/2`), and the answer is read from that table alone: it
  never waits for the Engine or Dispatch, so a stuck round still shows, growing late. The
  table is memory only and is lost with the core: what was due before the core started is
  not history Atlas keeps (D-0100); after a restart the Engine's first round and each
  Runtime's first poll fill it again (an incarnation's since is then that first poll). A
  write while no table exists (Flow's parts started alone, in a test) is dropped.

  Options of `start_link/1`: `name` (default `AtlasFlow.Health`, also the table's name)
  and `endpoint` (default `flow/health`; nil attaches none).
  """
  use GenServer

  alias AtlasBus.Envelope

  @endpoint "flow/health"

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.put(opts, :name, name), name: name)
  end

  @doc "The endpoint that answers `_health`."
  def endpoint, do: @endpoint

  @doc """
  The Engine's round: `%{due:, next_due:, last_due:, last_finished:}`, each a DateTime or
  nil, as the Engine knows it now.
  """
  def round(round, table \\ __MODULE__), do: put(table, :flow, round)

  @doc """
  Runtime `runtime` polled Dispatch at `at` (a DateTime); `about`, what the poll said of
  it: `"build"`, `"incarnation"`, and `"poll_max"`, the longest Dispatch holds a poll (in
  seconds). A new incarnation starts at this poll; the same one keeps its start.
  """
  def polled(runtime, at, about, table \\ __MODULE__) when is_binary(runtime) do
    incarnation = about["incarnation"]

    since =
      case lookup(table, {:runtime, runtime}) do
        %{about: %{"incarnation" => ^incarnation}, since: since} when is_binary(incarnation) ->
          since

        _ ->
          at
      end

    put(table, {:runtime, runtime}, %{at: at, about: about, since: since})
  end

  @doc """
  The work waiting for a Runtime, oldest first: `[%{task, title, profile, subject, since}]`,
  `subject` `{kind, key}` or nil, `since` ISO 8601. Nil means the queue is unknown.
  """
  def queue(entries, table \\ __MODULE__) when is_list(entries) or is_nil(entries),
    do: put(table, :queue, entries)

  @doc "What `_health` answers, read from `table` now."
  def report(table \\ __MODULE__, now \\ DateTime.utc_now()) do
    rows = if :ets.whereis(table) == :undefined, do: [], else: :ets.tab2list(table)
    flow = Enum.find_value(rows, %{}, fn {k, v} -> if k == :flow, do: v end)

    queue =
      case List.keyfind(rows, :queue, 0) do
        {:queue, entries} -> entries
        nil -> nil
      end

    %{
      "flow" =>
        Map.new(~w(due next_due last_due last_finished)a, fn k ->
          {Atom.to_string(k), iso(flow[k])}
        end),
      "runtimes" =>
        for({{:runtime, id}, polled} <- rows, do: runtime(id, polled))
        |> Enum.sort_by(& &1["runtime"]),
      "queue" => if(is_nil(queue), do: nil, else: Enum.map(queue, &waiting/1)),
      "at" => iso(now)
    }
  end

  defp runtime(id, %{at: at, about: about, since: since}) do
    %{
      "runtime" => id,
      "polled_at" => iso(at),
      "build" => about["build"],
      "incarnation" => about["incarnation"],
      "incarnation_since" => about["incarnation"] && iso(since),
      "poll_max" => about["poll_max"]
    }
    |> Map.reject(fn {_, v} -> is_nil(v) end)
  end

  defp waiting(entry) do
    {kind, key} = entry[:subject] || {nil, nil}

    %{
      "task" => entry[:task],
      "title" => entry[:title],
      "profile" => entry[:profile],
      "subject_kind" => kind,
      "subject_key" => key,
      "since" => entry[:since]
    }
    |> Map.reject(fn {_, v} -> is_nil(v) end)
  end

  defp lookup(table, key) do
    case :ets.lookup(table, key) do
      [{^key, value}] -> value
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp put(table, key, value) do
    :ets.insert(table, {key, value})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp iso(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  defp iso(_), do: nil

  @impl true
  def init(opts) do
    table = Keyword.fetch!(opts, :name)
    :ets.new(table, [:named_table, :public, :set, read_concurrency: true])

    case Keyword.get(opts, :endpoint, @endpoint) do
      nil -> :ok
      endpoint -> :ok = AtlasBus.attach(endpoint)
    end

    {:ok, %{table: table}}
  end

  @impl true
  def handle_info({:atlas_bus, %Envelope{class: "request", kind: "_health"} = request, _}, state) do
    AtlasBus.send(Envelope.reply(request, "answer"), report(state.table))
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}
end
