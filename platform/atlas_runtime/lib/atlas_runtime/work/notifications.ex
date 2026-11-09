defmodule AtlasRuntime.Work.Notifications do
  @moduledoc """
  Notifications of the work contract (design §3.6): signals only, never acknowledged.

  - **Window.** The last `limit` changes (default 10 000) are kept in memory, each with its
    change sequence. The sequence itself is persisted by the store; the window starts
    empty at each boot, at the boot's sequence.
  - **Subscribe.** From a sequence inside the window, the missed changes are replayed and
    the subscriber gets `subscribed`; from one before the window (it was dropped, or the
    Runtime restarted since) or after the current sequence, it gets `reset` and re-reads
    with `list_work(changed_since:)`. Either way it receives every later notification.
  - **Visibility (§3.2).** Without `read_all`, a subscriber receives `work_changed` only for
    its own client's work, and a heartbeat's `running` lists only its own attempts.
    `capacity_available` is global.
  - **Delivery.** Each notification is sent to the subscribing process as
    `{:atlas_runtime_work, notification}`, where `notification` is the facade's
    `WorkChanged`, `CapacityAvailable` or `Heartbeat` struct.
  """

  alias AtlasRuntime.Boundary.Work, as: B

  @message :atlas_runtime_work

  defstruct limit: 10_000, floor: 0, window: :queue.new(), size: 0, subscribers: %{}

  @doc "An empty window that starts after `sequence`."
  def new(sequence, limit \\ 10_000), do: %__MODULE__{limit: limit, floor: sequence}

  @doc "The message tag notifications are sent with."
  def tag, do: @message

  @doc "Records a work change and sends it to every subscriber that may see it."
  def work_changed(notifications, %B.WorkChanged{} = change, owner),
    do: publish(notifications, {change.sequence, owner, change})

  @doc "Records `capacity_available` and sends it to every subscriber."
  def capacity_available(notifications, %B.CapacityAvailable{} = change),
    do: publish(notifications, {change.sequence, nil, change})

  defp publish(notifications, entry) do
    for {pid, {client, _monitor}} <- notifications.subscribers,
        visible?(client, entry),
        do: send(pid, {@message, elem(entry, 2)})

    window = :queue.in(entry, notifications.window)
    size = notifications.size + 1

    if size > notifications.limit do
      {{:value, {dropped, _, _}}, window} = :queue.out(window)
      %{notifications | window: window, size: size - 1, floor: dropped}
    else
      %{notifications | window: window, size: size}
    end
  end

  @doc """
  Subscribes `pid` as `client` from sequence `from` (nil: from now): `{:subscribed, n}` after
  replaying the missed changes it may see, or `{{:reset, current}, n}`.
  """
  def subscribe(notifications, pid, client, from, current) do
    monitor =
      case notifications.subscribers do
        %{^pid => {_client, monitor}} -> monitor
        _ -> Process.monitor(pid)
      end

    notifications = put_in(notifications.subscribers[pid], {client, monitor})

    cond do
      is_nil(from) ->
        {:subscribed, notifications}

      from < notifications.floor or from > current ->
        {{:reset, current}, notifications}

      true ->
        for {sequence, _owner, change} = entry <- :queue.to_list(notifications.window),
            sequence > from,
            visible?(client, entry),
            do: send(pid, {@message, change})

        {:subscribed, notifications}
    end
  end

  @doc "Forgets a subscriber that went down."
  def down(notifications, pid) do
    case Map.pop(notifications.subscribers, pid) do
      {nil, _} ->
        notifications

      {{_client, monitor}, subscribers} ->
        Process.demonitor(monitor, [:flush])
        %{notifications | subscribers: subscribers}
    end
  end

  @doc """
  Sends a heartbeat to every subscriber. `running` is `[{owner, %B.RunningAttempt{}}]`;
  each subscriber gets only the entries it may see.
  """
  def heartbeat(notifications, at, %B.Capacity{} = capacity, running) do
    for {pid, {client, _monitor}} <- notifications.subscribers do
      own = for {owner, attempt} <- running, sees?(client, owner), do: attempt
      send(pid, {@message, %B.Heartbeat{at: at, capacity: capacity, running: own}})
    end

    notifications
  end

  @doc "Whether `client` (`{id, rights}`) may see the work of client id `owner`."
  def sees?({id, rights}, owner), do: owner == id or Enum.member?(rights, :read_all)

  defp visible?(_client, {_sequence, nil, _change}), do: true
  defp visible?(client, {_sequence, owner, _change}), do: sees?(client, owner)
end
