defmodule AtlasControl.Gateway do
  @moduledoc """
  Where clients connect: a TCP listener on this environment's Control address. Each
  connection gets its own `AtlasControl.Session`, with the model it serves pages for:
  `model:` (an `AtlasControl.Model`, checked when the Gateway starts) and the
  environment's `settings:` for Control (`AtlasControl.Model.catalog/2`).

  The actors the model's owners name (`actors:`, else the configured ones) must be filled
  by the settings, or the Gateway does not start (`AtlasControl.Model.actors!/2`).
  Whether their facts exist is Flow's concern (an owner that does not exist yet waits);
  Control serves meanwhile, so a fresh environment can make its first actors.
  """
  use GenServer

  require Logger

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "The port it listens on (useful when started on port 0)."
  def port(server \\ __MODULE__), do: GenServer.call(server, :port)

  @doc """
  Test only (IS-Atlas-23): close every client's connection, and take none for `ms`; a
  client then shows it is not connected, and comes back by itself.
  """
  def offline(ms, server \\ __MODULE__), do: GenServer.call(server, {:offline, ms})

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    # The model first: without one Control can serve, it listens for nobody.
    model = Keyword.fetch!(opts, :model)
    catalog = AtlasControl.Model.catalog(model, opts[:settings] || %{})

    # Every role the model's owners name is filled by the settings, or nothing starts.
    _actors =
      AtlasControl.Model.actors!(
        model,
        Keyword.get_lazy(opts, :actors, &AtlasBus.Actors.configured/0)
      )

    destination = %{
      "host" => Keyword.get(opts, :host, "127.0.0.1"),
      "port" => Keyword.fetch!(opts, :port),
      "tls" => Keyword.get(opts, :tls)
    }

    {:ok, listen} =
      AtlasTransport.listen(destination, [
        :binary,
        packet: :line,
        buffer: 4_194_304,
        active: false,
        reuseaddr: true
      ])

    {:ok, port} = AtlasTransport.port(listen)

    Logger.info(
      "Control #{AtlasBus.environment()} listens on #{Keyword.get(opts, :host, "127.0.0.1")}:#{port}"
    )

    {:ok, peers} = Task.Supervisor.start_link(max_children: 64)
    {acceptor, ref} = start_acceptor(listen, peers, catalog)

    {:ok,
     %{
       listen: listen,
       port: port,
       acceptor: acceptor,
       ref: ref,
       peers: peers,
       catalog: catalog,
       offline: nil
     }}
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  def handle_call(:online?, _from, state), do: {:reply, state.offline == nil, state}

  def handle_call({:offline, ms}, _from, state) do
    if AtlasBus.environment() == "prod" do
      {:reply, {:error, :prod}, state}
    else
      Logger.info("Control goes offline for #{ms} ms, on purpose")

      for {_, pid, _, _} <- DynamicSupervisor.which_children(AtlasControl.Sessions),
          is_pid(pid),
          do: DynamicSupervisor.terminate_child(AtlasControl.Sessions, pid)

      # Its own while: one that ran out of an earlier offline does not end this one.
      while = make_ref()
      AtlasControl.Clock.after_ms({:online, while}, ms)
      {:reply, :ok, %{state | offline: while}}
    end
  end

  @impl true
  def handle_info({:online, while}, %{offline: while} = state),
    do: {:noreply, %{state | offline: nil}}

  def handle_info({:online, _}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _, reason}, %{ref: ref} = state) do
    case AtlasTransport.port(state.listen) do
      {:ok, _} ->
        Logger.warning("Control acceptor exited: #{inspect(reason)}; restarting")
        {acceptor, ref} = start_acceptor(state.listen, state.peers, state.catalog)
        {:noreply, %{state | acceptor: acceptor, ref: ref}}

      _ ->
        {:stop, :listener_closed, state}
    end
  end

  def handle_info({:EXIT, pid, reason}, %{peers: pid} = state),
    do: {:stop, {:peers, reason}, state}

  def handle_info({:EXIT, _, _}, state), do: {:noreply, state}

  @impl true
  def terminate(_, state) do
    AtlasTransport.close(state.listen)
    Process.exit(state.acceptor, :shutdown)
    if Process.alive?(state.peers), do: Supervisor.stop(state.peers)
  end

  defp start_acceptor(listen, peers, catalog) do
    gateway = self()
    :erlang.spawn_opt(fn -> accept(listen, gateway, peers, catalog) end, [:link, :monitor])
  end

  defp accept(listen, gateway, peers, catalog) do
    case AtlasTransport.accept_peer(listen) do
      {:ok, socket} ->
        AtlasTransport.start_peer(peers, socket, fn socket ->
          if GenServer.call(gateway, :online?) do
            {:ok, pid} =
              DynamicSupervisor.start_child(
                AtlasControl.Sessions,
                {AtlasControl.Session, {socket, catalog, self()}}
              )

            ref = Process.monitor(pid)
            :ok = AtlasTransport.controlling_process(socket, pid)
            send(pid, :go)

            receive do
              {:DOWN, ^ref, :process, ^pid, _} -> :ok
            end
          else
            AtlasTransport.close(socket)
          end
        end)

      {:error, :closed} ->
        exit(:normal)

      {:error, _} ->
        :ok
    end

    accept(listen, gateway, peers, catalog)
  end
end
