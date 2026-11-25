defmodule AtlasFlow.Health do
  @moduledoc """
  What Flow says about its own health, for Control's health page (IS-Atlas-117): when
  Flow's round was due and when it finished, and when each Runtime last polled Dispatch.
  Attached to the Bus as `flow/health`; a `request` `_health` is answered with

      %{"flow" => %{"due" => due of the round now stepping, or nil,
                    "next_due" => when the next round is due, or nil,
                    "last_due" => due of the last finished round, or nil,
                    "last_finished" => when it finished, or nil},
        "runtimes" => [%{"runtime" => id, "polled_at" => when}],
        "at" => now}

  every moment ISO 8601 in UTC. Whether that is late is Control's to say.

  The Engine and Dispatch write what they know into this process's table as it happens
  (`round/2`, `polled/3`), and the answer is read from that table alone: it never waits
  for the Engine or Dispatch, so a stuck round still shows, growing late. The table is
  memory only and is lost with the core: what was due before the core started is not
  history Atlas keeps (D-0100); after a restart the Engine's first round and each
  Runtime's first poll fill it again. A write while no table exists (Flow's parts started
  alone, in a test) is dropped.

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

  @doc "Runtime `runtime` polled Dispatch at `at` (a DateTime)."
  def polled(runtime, at, table \\ __MODULE__) when is_binary(runtime),
    do: put(table, {:runtime, runtime}, at)

  @doc "What `_health` answers, read from `table` now."
  def report(table \\ __MODULE__, now \\ DateTime.utc_now()) do
    rows = if :ets.whereis(table) == :undefined, do: [], else: :ets.tab2list(table)
    flow = Enum.find_value(rows, %{}, fn {k, v} -> if k == :flow, do: v end)

    %{
      "flow" =>
        Map.new(~w(due next_due last_due last_finished)a, fn k ->
          {Atom.to_string(k), iso(flow[k])}
        end),
      "runtimes" =>
        for({{:runtime, id}, at} <- rows, do: %{"runtime" => id, "polled_at" => iso(at)})
        |> Enum.sort_by(& &1["runtime"]),
      "at" => iso(now)
    }
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
