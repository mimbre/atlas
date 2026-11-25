defmodule AtlasBus.Router do
  @moduledoc false
  use GenServer

  require Logger

  alias AtlasBus.Envelope

  @to_store ~w(fact read)
  @to_address ~w(request refused answer)
  # A failure to offer or cause (IS-Atlas-23): addressed to a layer, test only.
  @faults ~w(fault)
  @acknowledged_and_hinted ~w(stored)

  def classes, do: @to_store ++ @acknowledged_and_hinted ++ @to_address ++ @faults

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  def attach(name) when is_binary(name) and name != "" do
    case Registry.register(AtlasBus.Endpoints, name, nil) do
      {:ok, _} -> :ok
      {:error, {:already_registered, pid}} when pid == self() -> :ok
      {:error, {:already_registered, _pid}} -> {:error, :taken}
    end
  end

  def listen(kind) when is_binary(kind) and kind != "" do
    if kind in Registry.keys(AtlasBus.Listeners, self()) do
      :ok
    else
      {:ok, _} = Registry.register(AtlasBus.Listeners, kind, nil)
      :ok
    end
  end

  # The sender is taken from the calling process here, before the call, so it cannot be posed.
  def route(envelope, content) do
    with :ok <- Envelope.validate(envelope),
         :ok <- known_class(envelope.class),
         :ok <- same_environment(envelope.environment),
         :ok <- not_in_prod(envelope.class),
         {:ok, sender} <- sender_of(self()) do
      envelope = %{envelope | sender: sender}

      case answered_here(envelope, content) do
        :answered -> :ok
        :pass -> GenServer.call(__MODULE__, {:route, envelope, content})
      end
    end
  end

  @doc """
  Let the calling process, attached as the store, have its reads answered where they are
  sent (`AtlasBus.answer_reads/1`): `module.answer(arg, envelope, content)` runs in the
  sending process and returns `{:answer, content}`, or `:pass` to have the store answer.
  """
  def answer_reads({module, _arg} = reader) when is_atom(module) do
    case Registry.update_value(AtlasBus.Endpoints, AtlasBus.store(), fn _ -> reader end) do
      {_new, _old} -> :ok
      :error -> {:error, :not_the_store}
    end
  end

  # A read answered in the sending process, by the store's reader, outside the store's
  # process: so it does not wait behind the store's writes. It goes to the store as any
  # message does when the store has no reader, when the reader passes or fails, when this
  # node reaches the store over a link, and while a fact the sender sent the store is not
  # answered yet: that read is answered after the fact, as the store takes them in order.
  defp answered_here(%Envelope{class: "read"} = envelope, content) do
    store = AtlasBus.store()

    with false <- AtlasBus.Link.client?(),
         [{_pid, {module, arg}}] <- Registry.lookup(AtlasBus.Endpoints, store),
         false <- unanswered_fact?(envelope.sender),
         {:answer, answer} <- read_here(module, arg, %{envelope | address: store}, content),
         [{to, _}] <- Registry.lookup(AtlasBus.Endpoints, envelope.sender) do
      reply = %{Envelope.reply(envelope, "answer") | sender: store}
      send(to, {:atlas_bus, reply, answer})
      :answered
    else
      _ -> :pass
    end
  end

  defp answered_here(_envelope, _content), do: :pass

  defp read_here(module, arg, envelope, content) do
    module.answer(arg, envelope, content)
  catch
    kind, reason ->
      Logger.warning(
        "Bus: the store's reader failed on read #{envelope.id}; the store answers it: " <>
          Exception.format(kind, reason, __STACKTRACE__)
      )

      :pass
  end

  # Facts sent to the store and not answered yet (`stored` or `refused` to their sender),
  # by sender and id. One that is never answered (it found no store, or the store stopped)
  # no longer counts after a minute: the sender sends it again or has given up on it.
  @unanswered __MODULE__.Unanswered
  @unanswered_ms 60_000

  defp unanswered_fact?(sender) do
    since = System.monotonic_time(:millisecond) - @unanswered_ms
    match = [{{{sender, :_}, :"$1"}, [{:>, :"$1", since}], [true]}]
    :ets.select(@unanswered, match, 1) != :"$end_of_table"
  end

  def drop_hints(count) when is_integer(count) and count >= 0 do
    if AtlasBus.environment() == "prod",
      do: {:error, :prod},
      else: GenServer.call(__MODULE__, {:drop_hints, count})
  end

  @impl true
  def init(:ok) do
    :ets.new(@unanswered, [:ordered_set, :protected, :named_table, read_concurrency: true])
    {:ok, %{drop_hints: 0}}
  end

  @impl true
  def handle_call({:route, envelope, content}, _from, state) do
    if AtlasBus.Link.client?() do
      AtlasBus.Link.Client.forward(envelope, content)
      {:reply, :ok, state}
    else
      route_local(envelope, content, state)
    end
  end

  def handle_call({:drop_hints, count}, _from, state),
    do: {:reply, :ok, %{state | drop_hints: count}}

  defp route_local(%Envelope{class: class} = envelope, content, state)
       when class in @to_store do
    store = AtlasBus.store()
    if class == "fact", do: unanswered(envelope)
    deliver([endpoint(store)], %{envelope | address: store}, content)
    {:reply, :ok, state}
  end

  defp route_local(%Envelope{class: class} = envelope, content, state)
       when class in @to_address or class in @faults do
    if class == "refused", do: answered(envelope)
    deliver([endpoint(envelope.address)], envelope, content)
    {:reply, :ok, state}
  end

  defp route_local(%Envelope{class: class} = envelope, content, state)
       when class in @acknowledged_and_hinted do
    answered(envelope)
    {listeners, state} = hint_receivers(state, envelope.kind)
    deliver([endpoint(envelope.address) | listeners], envelope, content)
    {:reply, :ok, state}
  end

  # Kept in the Router's process, as it routes: a read routed after a fact sees it.
  defp unanswered(%Envelope{sender: sender, id: id}) do
    now = System.monotonic_time(:millisecond)
    :ets.select_delete(@unanswered, [{{:_, :"$1"}, [{:<, :"$1", now - @unanswered_ms}], [true]}])
    :ets.insert(@unanswered, {{sender, id}, now})
  end

  defp answered(%Envelope{address: address, id: id}),
    do: :ets.delete(@unanswered, {address, id})

  defp known_class(class) do
    if class in classes(), do: :ok, else: {:error, {:unknown_class, class}}
  end

  defp same_environment(environment) do
    if environment == AtlasBus.environment(),
      do: :ok,
      else: {:error, {:other_environment, environment}}
  end

  defp not_in_prod(class) do
    if class in @faults and AtlasBus.environment() == "prod", do: {:error, :prod}, else: :ok
  end

  defp sender_of(pid) do
    case Registry.keys(AtlasBus.Endpoints, pid) do
      [name] -> {:ok, name}
      [] -> {:error, :not_attached}
    end
  end

  defp hint_receivers(%{drop_hints: count} = state, _kind) when count > 0 do
    Logger.info("Bus dropped a hint on purpose (#{count - 1} more to drop)")
    {[], %{state | drop_hints: count - 1}}
  end

  defp hint_receivers(state, kind) do
    {Enum.map(Registry.lookup(AtlasBus.Listeners, kind), fn {pid, _} -> pid end), state}
  end

  defp endpoint(nil), do: nil

  defp endpoint(name) do
    case Registry.lookup(AtlasBus.Endpoints, name) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  # Delivery is not promised (AtlasBus): what finds no endpoint is dropped. A sender that
  # still needs the reply asks again: the Runtime sends a fact again with its id, a read with
  # a new one; a hint has nobody waiting for it. A reply addresses its request's sender, which
  # was attached when it sent (sender_of/1); so a reply finds nobody only when that endpoint
  # went away before it came: its process stopped or detached, or the link it came over
  # closed (a link's endpoints go with its connection, AtlasBus.Link.Server).
  defp deliver(pids, envelope, content) do
    case pids |> Enum.reject(&is_nil/1) |> Enum.uniq() do
      [] -> Logger.debug(fn -> undelivered(envelope) end)
      pids -> Enum.each(pids, &send(&1, {:atlas_bus, envelope, content}))
    end
  end

  defp undelivered(%Envelope{} = e),
    do: "Bus: dropped #{e.class} #{e.id}: no endpoint is attached as #{e.address}"
end
