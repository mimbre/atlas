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
      GenServer.call(__MODULE__, {:route, %{envelope | sender: sender}, content})
    end
  end

  def drop_hints(count) when is_integer(count) and count >= 0 do
    if AtlasBus.environment() == "prod",
      do: {:error, :prod},
      else: GenServer.call(__MODULE__, {:drop_hints, count})
  end

  @impl true
  def init(:ok), do: {:ok, %{drop_hints: 0}}

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
    deliver([endpoint(store)], %{envelope | address: store}, content)
    {:reply, :ok, state}
  end

  defp route_local(%Envelope{class: class} = envelope, content, state)
       when class in @to_address or class in @faults do
    deliver([endpoint(envelope.address)], envelope, content)
    {:reply, :ok, state}
  end

  defp route_local(%Envelope{class: class} = envelope, content, state)
       when class in @acknowledged_and_hinted do
    {listeners, state} = hint_receivers(state, envelope.kind)
    deliver([endpoint(envelope.address) | listeners], envelope, content)
    {:reply, :ok, state}
  end

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
