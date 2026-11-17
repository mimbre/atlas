defmodule AtlasCode.Instance do
  @moduledoc """
  The registered name of a started Code (`AtlasCode.start/2` with `register: true`): a
  process under that name holds the instance's settings and exits when the instance's
  server goes down, so the name never outlives the instance. httpd's own process already
  carries a name of its own, so it cannot carry this one.

  Not linked to whoever started Code: the server outlives its starter, and so does this.
  """
  use GenServer

  @doc "Registers `server` (an httpd pid) with `settings` under `name`."
  def start(name, server, settings),
    do: GenServer.start(__MODULE__, {server, settings}, name: name)

  @doc "Unregisters: stops the holder, if it still runs."
  def stop(instance) do
    GenServer.stop(instance)
  catch
    :exit, _ -> :ok
  end

  @doc "The settings registered under `name`; raises when nothing is."
  def settings(name) do
    GenServer.call(name, :settings)
  catch
    :exit, _ ->
      raise "No Code instance is registered as #{inspect(name)}: start one with register: true"
  end

  @impl true
  def init({server, settings}) do
    Process.monitor(server)
    {:ok, settings}
  end

  @impl true
  def handle_call(:settings, _from, settings), do: {:reply, settings, settings}

  @impl true
  def handle_info({:DOWN, _ref, :process, _server, _reason}, settings),
    do: {:stop, :normal, settings}
end
