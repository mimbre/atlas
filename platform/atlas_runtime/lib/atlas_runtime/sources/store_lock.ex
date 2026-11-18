defmodule AtlasRuntime.Sources.StoreLock do
  @moduledoc """
  One writer per source store (`AtlasRuntime.Sources.Store`): a lock for each source of a
  Runtime home, held by `AtlasRuntime.Sources.Import.base/5` from its `Store.scan/2` to its
  last `Store.put/6`. Without it, two imports for the same source (the puller runs each
  accepted lease's import in a task of its own) race: one's scan removes the other's
  `.partial-*` file while that one is still writing it, and that write then fails `enoent`
  ("cannot store blob"); and both could pass the quota check on the same count.

  **Waiting.** A lock is granted to one process at a time per `{home, source}`; the others
  wait in order of their request, blocked in a call (no polling). Locks of different sources
  or homes never wait on each other.

  **Released on any end.** The server traps exits and links to every process that asks: a
  holder that returns, raises, throws or is killed (`Task.shutdown(task, :brutal_kill)` at an
  import's deadline or a fenced lease) releases its lock at once, and a waiter that dies
  leaves the queue. If this server itself ends, its linked holders and waiters end with it,
  so no import keeps writing a store it no longer holds.

  A process asks for one lock at a time: a second request while it holds or waits for one
  is refused (`ArgumentError` in `hold/4`) rather than deadlocking.

  The key is the home as given, expanded (`Path.expand/1`), not resolved through symlinks:
  every caller of one Runtime passes the same home (`AtlasRuntime.Work.runtime/0`).
  """

  use GenServer

  @doc "Starts the lock server; `name:` (default this module, `nil` for none)."
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, :ok)
      name -> GenServer.start_link(__MODULE__, :ok, name: name)
    end
  end

  @doc """
  Runs `fun` holding the lock of source `name`'s store in `home`, and answers its value. It
  waits for the lock as long as another process holds it; it releases it however `fun`
  ends.
  """
  @spec hold(Path.t(), String.t(), (-> result), GenServer.server()) :: result
        when result: term()
  def hold(home, name, fun, server \\ __MODULE__) when is_function(fun, 0) do
    key = key(home, name)

    case GenServer.call(server, {:acquire, key}, :infinity) do
      :ok ->
        try do
          fun.()
        after
          :ok = GenServer.call(server, {:release, key}, :infinity)
        end

      {:error, :nested} ->
        raise ArgumentError, "this process already holds or waits for a store lock"
    end
  end

  @doc "The processes waiting for the lock of source `name`'s store in `home`, in order."
  @spec waiting(Path.t(), String.t(), GenServer.server()) :: [pid()]
  def waiting(home, name, server \\ __MODULE__),
    do: GenServer.call(server, {:waiting, key(home, name)})

  @doc "The process holding the lock of source `name`'s store in `home`, or `nil`."
  @spec holder(Path.t(), String.t(), GenServer.server()) :: pid() | nil
  def holder(home, name, server \\ __MODULE__),
    do: GenServer.call(server, {:holder, key(home, name)})

  defp key(home, name) when is_binary(name), do: {Path.expand(home), name}

  ## Server

  # holders: key => pid; queues: key => :queue of {pid, from}; pids: every linked pid => key.
  @impl true
  def init(:ok) do
    Process.flag(:trap_exit, true)
    {:ok, %{holders: %{}, queues: %{}, pids: %{}}}
  end

  @impl true
  def handle_call({:acquire, key}, {pid, _tag} = from, state) do
    if Map.has_key?(state.pids, pid) do
      {:reply, {:error, :nested}, state}
    else
      Process.link(pid)
      state = put_in(state.pids[pid], key)

      case state.holders do
        %{^key => _holder} ->
          queue = Map.get(state.queues, key, :queue.new())
          {:noreply, put_in(state.queues[key], :queue.in({pid, from}, queue))}

        %{} ->
          {:reply, :ok, put_in(state.holders[key], pid)}
      end
    end
  end

  def handle_call({:release, key}, {pid, _tag}, state) do
    case state.holders do
      %{^key => ^pid} ->
        Process.unlink(pid)
        {:reply, :ok, state |> forget(pid) |> grant(key)}

      %{} ->
        {:reply, {:error, :not_held}, state}
    end
  end

  def handle_call({:waiting, key}, _from, state) do
    queue = Map.get(state.queues, key, :queue.new())
    {:reply, for({pid, _from} <- :queue.to_list(queue), do: pid), state}
  end

  def handle_call({:holder, key}, _from, state),
    do: {:reply, Map.get(state.holders, key), state}

  # A linked holder or waiter ended. An exit of a process no longer linked (it released, and
  # then ended before the unlink took effect) is not one of ours any more.
  @impl true
  def handle_info({:EXIT, pid, _reason}, state) do
    case state.pids do
      %{^pid => key} ->
        state = forget(state, pid)

        case state.holders do
          %{^key => ^pid} ->
            {:noreply, grant(state, key)}

          %{} ->
            queue = :queue.filter(fn {waiter, _} -> waiter != pid end, state.queues[key])
            {:noreply, put_in(state.queues[key], queue)}
        end

      %{} ->
        {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp forget(state, pid), do: %{state | pids: Map.delete(state.pids, pid)}

  # The lock of key passes to its first waiter, or is free.
  defp grant(state, key) do
    case :queue.out(Map.get(state.queues, key, :queue.new())) do
      {{:value, {pid, from}}, queue} ->
        GenServer.reply(from, :ok)

        %{
          state
          | holders: Map.put(state.holders, key, pid),
            queues: Map.put(state.queues, key, queue)
        }

      {:empty, _queue} ->
        %{
          state
          | holders: Map.delete(state.holders, key),
            queues: Map.delete(state.queues, key)
        }
    end
  end
end
