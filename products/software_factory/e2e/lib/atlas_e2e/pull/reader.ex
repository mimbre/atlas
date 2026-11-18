defmodule AtlasE2E.Pull.Reader do
  @moduledoc """
  A Port that turns an OS command's output lines into `AtlasE2E.Pull.Hub` events: the stub
  agents' FIFO (`:stub`) and `atlas-runtime events --follow` (`:rt`). Each line is decoded
  as JSON (a line that is not JSON is published as `%{"line" => text}`); `on_event` sees each
  published event (the stub registry). With `stub:` the command runs tethered
  (`pull-stub tether --`) in the tether's group, whose id is the Port's os pid: when this
  BEAM ends, however it ends, the tether sees its stdin end and KILLs that group, so a `cat`
  on a FIFO never outlives it. The Reader traps its owner's exit, and `terminate/2` KILLs the
  group (the tether with its command; KILLing the tether alone would leave the command
  behind) before it closes the Port. The group is recorded (`pgid`), so the reaper KILLs it
  and its proof looks in it. A Reader is tied to the process that starts it (the run:
  `AtlasE2E.Pull.Bench.started/2`), which stops it on every outcome, also when setup fails
  while that process lives on. When the command ends, a `:port` event
  `%{what: name, status: status}` is published, so its end is an event too (S4 waits for the
  Runtime's events reader to end after the crash). Its OS pid is recorded in the registry.
  """
  use GenServer

  alias AtlasE2E.Pull.{Bench, Hub}

  def start_link(opts) do
    with {:ok, reader} <- GenServer.start_link(__MODULE__, opts) do
      Bench.started("reader #{opts[:name]}", fn -> stop(reader) end)
      {:ok, reader}
    end
  end

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
    # Tethered, the command runs in the tether's group: its id is the tether's pid.
    group = if opts[:stub], do: os_pid

    if run = opts[:run] do
      line = %{pid: os_pid, pgid: group, name: opts[:name]}

      Bench.record(
        run,
        "port",
        Map.reject(line, &is_nil(elem(&1, 1))),
        Keyword.take(opts, [:lstart])
      )
    end

    {:ok,
     %{
       port: port,
       os_pid: os_pid,
       group: group,
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
  def terminate(_reason, %{port: port, os_pid: os_pid} = state) when is_port(port) do
    # The group first, while the tether leads it: the command ends with the tether. (Closing
    # the Port first and KILLing the tether races the tether's own KILL of its group.) The
    # pid too, for a tether not yet in a group of its own.
    if state.group, do: Bench.signal(-state.group, "KILL")
    Bench.signal(os_pid, "KILL")
    Port.close(port)
    :ok
  catch
    _, _ -> :ok
  end

  def terminate(_reason, _state), do: :ok
end
