defmodule AtlasRuntime.Work do
  @moduledoc """
  The Runtime's work core: the one implementation of the work contract
  (`AtlasRuntime.Boundary.Work.Implementation`, design §1.5). Callers never call it; they
  call the facade `AtlasRuntime.Boundary.Work`, which checks rights, input and outcomes.

  The behaviour lives in `AtlasRuntime.Work.Server` (the process that owns the work
  records) and the modules under `AtlasRuntime.Work`: `Store` (persistence through the
  private model), `Queue` (slots, buffer, start gate, retry and cancel tables), `Turns`
  (the Service's turns), `Notifications`, `Restart` and `Prune`.

  It is started only by `host/service.exs`, after the Service, never by
  `AtlasRuntime.Application`. While it is not running every capability answers with a
  declared outcome meaning "not running": `submit`/`retry` `at_capacity: not_accepting`,
  `get_work`/`find_work`/`turn_output`/`cancel` `not_found`, `list_work` empty, `capacity`
  not accepting, `subscribe` `subscribed` with no notifications. `get_frozen` and
  `get_frozen_blob` (S5a) answer `not_found` until frozen results are read (s5a-plan P8).

  A subscriber receives `{:atlas_runtime_work, notification}` messages, where
  `notification` is a `AtlasRuntime.Boundary.Work.WorkChanged`, `CapacityAvailable` or
  `Heartbeat` struct (`AtlasRuntime.Work.Notifications`).
  """
  use AtlasRuntime.Boundary.Work.Implementation

  alias AtlasRuntime.Boundary.Work, as: B
  alias AtlasRuntime.Work.Server

  # A start runs inside the core's process (workspace preparation included), so a call
  # may wait for one.
  @timeout 150_000

  @doc "Starts the core on the Service's home `dir`; see `AtlasRuntime.Work.Server` for `opts`."
  defdelegate start_link(dir, opts \\ []), to: Server

  @doc """
  The Service's `release` of `worker_id` (F2): a human confirms the slot free, so an attempt
  there whose end was never confirmed becomes quiescent. A no-op while the core is not running.
  """
  def released(worker_id) do
    case GenServer.whereis(Server) do
      nil -> :ok
      pid -> send(pid, {:released, worker_id})
    end

    :ok
  end

  ## For the operations (design §13.1 Q8, Q9; I-K): internal, never through a facade

  @doc """
  The Runtime's mode (I-K): the persisted `open`, `paused` or `draining`
  (`AtlasRuntime.Work.Mode`), or `:stopping` once a stop began (`stop/2`, or a Service stop
  the core heard of), which is never persisted. `:open` while the core is not running.
  """
  @spec mode() :: :open | :paused | :draining | :stopping
  def mode, do: call(:mode, fn -> :open end)

  @doc """
  Sets the persisted mode (I-K, §13.1 Q5): `:paused`, `:draining` or `:open` (resume), by
  the client id `by`, and answers `mode/0` after it. `mode.json` is written before the
  answer, and so is every buffered attempt a drain returns; the same mode again changes
  nothing. A no-op answering `stopping` while the core is not running.
  """
  @spec set_mode(:open | :paused | :draining, String.t()) ::
          :open | :paused | :draining | :stopping
  def set_mode(mode, by) when mode in [:open, :paused, :draining] and is_binary(by),
    do: call({:set_mode, mode, by}, fn -> :stopping end)

  @doc """
  What runtime info shows of the core, or nil while it is not running: `home`,
  `runtime_build`, `incarnation` and `policy_version` exactly as `capacity` answers them,
  `mode` (`mode/0`) and `slots`, the policy's slots in order as `{name, busy}`, busy as
  `capacity` counts it.
  """
  def runtime, do: call(:runtime, fn -> nil end)

  @doc """
  Releases `slot` for `by` (§13.1 Q8): `:busy` while a process of the slot is alive (a turn
  the Service owns now, or one the process probe finds running). Otherwise the Service's
  `release` clears the slot's admission latch and ends a turn of a previous Service it left
  unknown; every attempt there whose end was never confirmed becomes quiescent with
  `released_by`/`released_at`, persisted before the answer, and `work_changed` goes out.
  `:released` also when there was nothing to release, which changes no record.
  `:not_running` while the core is not running.
  """
  def mark_released(slot, by), do: call({:mark_released, slot, by}, fn -> :not_running end)

  @doc """
  Begins the Runtime's stop (§13.1 Q9) for `by` and returns once the mode is `:stopping`:
  no new work and no start; buffered work stays. Running attempts get the cancel stages'
  signal and, after `cancel_grace`, the kill (with `force`, the kill at once), and end
  `interrupted`, reason `runtime_stop`, retryable. Once none runs, the Service's own
  service stop ends the process. A repeat changes nothing. While the core is not running,
  the Service is stopped directly.
  """
  def stop(force, by), do: call({:stop, force == true, by}, &stop_service/0)

  @doc """
  Clears the quota mark of `harness` in the Service's process
  (`AtlasRuntime.Availability.clear_quota_mark/2`): `:cleared`, `:unmarked`, `:not_found`,
  or `:not_running`. A cleared mark lets waiting work start, and `capacity_available` goes
  out if the Runtime takes new work again (§3.6).
  """
  def clear_quota_mark(harness),
    do: call({:clear_quota_mark, harness}, fn -> :not_running end)

  @impl true
  def submit(client, input), do: call({:submit, client, input}, &not_accepting/0)

  @impl true
  def retry(client, input), do: call({:retry, client, input}, &not_accepting/0)

  @impl true
  def cancel(client, input), do: call({:cancel, client, input}, &not_found/0)

  @impl true
  def get_work(client, input), do: call({:get_work, client, input}, &not_found/0)

  @impl true
  def find_work(client, input), do: call({:find_work, client, input}, &not_found/0)

  @impl true
  def list_work(client, input),
    do: call({:list_work, client, input}, fn -> %B.Outcome.Works{works: [], sequence: 0} end)

  @impl true
  def capacity(client),
    do:
      call({:capacity, client}, fn ->
        struct!(B.Outcome.Capacity, Map.from_struct(stopped_capacity()))
      end)

  @impl true
  def turn_output(client, input), do: call({:turn_output, client, input}, &not_found/0)

  @impl true
  def subscribe(client, input),
    do: call({:subscribe, client, input, self()}, fn -> %B.Outcome.Subscribed{} end)

  # S5a skeletons (s5a-plan P4): no attempt is frozen before P7b, so there is no frozen
  # result to read yet. P8 gives these their bodies (reads, visibility and retention).
  @impl true
  def get_frozen(_client, %B.GetFrozenInput{}), do: not_found()

  @impl true
  def get_frozen_blob(_client, %B.GetFrozenBlobInput{}), do: not_found()

  defp call(message, stopped) do
    case GenServer.whereis(Server) do
      nil -> stopped.()
      pid -> GenServer.call(pid, message, @timeout)
    end
  end

  defp not_found, do: %B.Outcome.NotFound{}

  # Without the core only the Service's service stop is left; its exit follows the answer.
  defp stop_service do
    with pid when is_pid(pid) <- GenServer.whereis(AtlasRuntime.Service),
         {_reply, true} <- GenServer.call(pid, %{"command" => "service-stop"}, @timeout) do
      Process.send_after(pid, :shutdown, 200)
    end

    :ok
  catch
    :exit, _ -> :ok
  end

  defp not_accepting,
    do: %B.Outcome.AtCapacity{
      reason: :not_accepting,
      retry_after: 60,
      capacity: stopped_capacity()
    }

  defp stopped_capacity do
    %B.Capacity{
      slots: %B.SlotCounts{total: 0, busy: 0, free: 0},
      buffer: %B.BufferCounts{size: 0, used: 0, free: 0},
      profiles: [],
      accepting: false,
      policy_version: 0,
      runtime_build: AtlasRuntime.Provenance.context().runtime_build,
      incarnation: "stopped",
      retry_after: 60
    }
  end
end
