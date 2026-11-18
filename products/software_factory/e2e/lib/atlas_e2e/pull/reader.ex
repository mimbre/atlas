defmodule AtlasE2E.Pull.Reader do
  @moduledoc """
  A Port that turns an OS command's output lines into `AtlasE2E.Pull.Hub` events: the stub
  agents' FIFO (`:stub`) and `atlas-runtime events --follow` (`:rt`). Each line is decoded
  as JSON (a line that is not JSON is published as `%{"line" => text}`); `on_event` sees each
  published event (the stub registry). With `stub:` the command runs tethered
  (`pull-stub tether --`): when this BEAM ends, however it ends, the stub sees its stdin end
  and KILLs the command's group, so a `cat` on a FIFO never outlives it; and the Reader traps
  its owner's exit, so `terminate/2` KILLs it when the owner dies. When the command ends, a `:port` event
  `%{what: name, status: status}` is published, so its end is an event too (S4 waits for the
  Runtime's events reader to end after the crash). Its OS pid is recorded in the registry.
  """
  use GenServer

  alias AtlasE2E.Pull.{Bench, Hub}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def os_pid(reader), do: GenServer.call(reader, :os_pid)

  def stop(reader) do
    GenServer.stop(reader)
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init(opts) do
    # Its owner's end stops it through terminate/2, which kills the command (a `cat` on a
    # FIFO never sees an end of file and would outlive it).
    Process.flag(:trap_exit, true)

    env =
      Enum.map(opts[:env] || [], fn {k, v} ->
        {String.to_charlist(k), if(v, do: String.to_charlist(v), else: false)}
      end)

    {exe, args} =
      if stub = opts[:stub],
        do: {stub, ["tether", "--", opts[:command] | opts[:args] || []]},
        else: {opts[:command], opts[:args] || []}

    port =
      Port.open({:spawn_executable, exe}, [
        :binary,
        :exit_status,
        # Never the BEAM's own stderr: a child that outlives it must not hold that open.
        :stderr_to_stdout,
        {:line, 1_048_576},
        {:args, args},
        {:env, env}
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    if run = opts[:run], do: Bench.record(run, "port", %{pid: os_pid, name: opts[:name]})

    {:ok,
     %{
       port: port,
       os_pid: os_pid,
       source: opts[:source],
       name: opts[:name],
       hub: opts[:hub] || Hub,
       on_event: opts[:on_event] || fn _ -> :ok end,
       partial: ""
     }}
  end

  @impl true
  def handle_call(:os_pid, _from, state), do: {:reply, state.os_pid, state}

  @impl true
  def handle_info({port, {:data, {:noeol, part}}}, %{port: port} = state),
    do: {:noreply, %{state | partial: state.partial <> part}}

  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    line = state.partial <> line

    data =
      case JSON.decode(line) do
        {:ok, %{} = map} -> map
        _ -> %{"line" => line}
      end

    event = Hub.publish(state.source, data, state.hub)
    state.on_event.(event)
    {:noreply, %{state | partial: ""}}
  end

  # Its owner (a linked process) ended: stop, and terminate/2 KILLs the command. A Port's
  # EXIT (a short command it ran, such as `ps`) is no reason to.
  def handle_info({:EXIT, from, reason}, state) when is_pid(from), do: {:stop, reason, state}
  def handle_info({:EXIT, _port, _reason}, state), do: {:noreply, state}

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Hub.publish(:port, %{what: state.name, status: status}, state.hub)
    {:stop, :normal, %{state | port: nil}}
  end

  @impl true
  def terminate(_reason, %{port: port, os_pid: os_pid}) when is_port(port) do
    Port.close(port)
    Bench.signal(os_pid, "KILL")
    :ok
  catch
    _, _ -> :ok
  end

  def terminate(_reason, _state), do: :ok
end
