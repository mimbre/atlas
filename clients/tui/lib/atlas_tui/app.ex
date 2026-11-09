defmodule AtlasTui.App do
  @moduledoc """
  The running TUI: raw terminal input, the connection to Control, and the screen.

  - Every key goes through `AtlasTui.Model`; Control messages go through `AtlasTui.Console`.
  - Every `reconcile_seconds` it asks Control to refresh the page from Facts, so a lost
    hint only delays what the screen shows.
  - A link's key opens its web address in the browser (`AtlasTui.Browser`).
  - When the connection drops it says so, retries every 2 seconds, and on return opens
    the page it was on.
  - The first `:` starts the agent (`atlas steer`, a Control client of its own) as a
    child process, and keeps it while the TUI runs. They talk in JSON lines on its stdin
    and stdout (`AtlasAgent.Steer`); its stderr goes to `steer.log` beside the
    environment's other logs.
  """

  alias AtlasTui.{Console, Keys, Model, View, WorkerConversation, WorkerOutputConnection}

  # How long a lone escape byte waits for the rest of a key's sequence (`\e[B` is Down)
  # before it counts as Escape: `escape_ms` in the settings. The input is read a byte at
  # a time, so on a busy machine the bytes of one key can come further apart than this.
  @escape_wait 30
  @reconnect 2_000
  @root Path.expand("../../../..", __DIR__)

  def run(env, settings) do
    with {:error, reason} <- :shell.start_interactive({:noshell, :raw}) do
      IO.puts(:stderr, "atlas: the TUI needs a terminal (#{inspect(reason)})")
      System.halt(1)
    end

    Logger.configure(level: :error)
    IO.write("\e[?1049h\e[?25l")
    parent = self()
    spawn_link(fn -> read_input(parent) end)
    AtlasTui.Resize.watch(parent)
    reconcile = settings["reconcile_seconds"] || 5
    :timer.send_interval(reconcile * 1_000, :reconcile)

    state = %{
      model: Model.new(env),
      settings: settings,
      reconcile: reconcile,
      socket: nil,
      output: nil,
      output_target: nil,
      output_monitor: nil,
      output_tick: nil,
      output_retry: nil,
      buffer: "",
      escape_wait: settings["escape_ms"] || @escape_wait,
      agent: nil,
      agent_buffer: ""
    }

    state = connect(state)

    try do
      loop(draw(state))
    after
      IO.write("\e[0m\e[?25h\e[?1049l")
    end
  end

  defp read_input(parent) do
    case IO.getn(:stdio, "", 1) do
      data when is_binary(data) ->
        send(parent, {:input, data})
        read_input(parent)

      _eof ->
        send(parent, {:input, <<3>>})
    end
  end

  defp loop(state) do
    receive do
      {:input, data} ->
        {keys, rest} = Keys.parse(state.buffer <> data)
        if rest != "", do: Process.send_after(self(), {:flush, rest}, state.escape_wait)
        keys(%{state | buffer: rest}, keys)

      {:flush, rest} when rest == state.buffer ->
        keys(%{state | buffer: ""}, Keys.flush(rest))

      {:flush, _old} ->
        loop(state)

      {:tcp, socket, line} when socket == state.socket ->
        case JSON.decode(line) do
          {:ok, message} ->
            {model, effects} = Console.receive(state.model, message)

            loop(draw(effects(%{state | model: model}, effects)))

          _ ->
            loop(state)
        end

      {:tcp_closed, socket} when socket == state.socket ->
        Process.send_after(self(), :reconnect, @reconnect)
        loop(draw(%{state | socket: nil, model: Model.disconnected(state.model)}))

      {:boot_timeout, socket, serial} when socket == state.socket ->
        if state.model.console.boot_pending && state.model.console.boot_serial == serial do
          loop(draw(connection_timeout(state, "Console boot timed out")))
        else
          loop(state)
        end

      {:handshake_timeout, socket} when socket == state.socket ->
        if state.model.console.phase in [:welcome, :compatibility] do
          loop(draw(connection_timeout(state, "Console handshake timed out")))
        else
          loop(state)
        end

      {:boot_timeout, _socket, _serial} ->
        loop(state)

      {:handshake_timeout, _socket} ->
        loop(state)

      {:tcp, _old_socket, _line} ->
        loop(state)

      {:tcp_closed, _old_socket} ->
        loop(state)

      :resized ->
        loop(draw(state))

      {:worker_output_connection, pid, :ready} when pid == state.output ->
        {model, outgoing} = WorkerConversation.output_connected(state.model)
        loop(draw(effects(%{state | model: model}, outgoing)))

      {:worker_output_connection, pid, {:message, message}} when pid == state.output ->
        {model, outgoing} = WorkerConversation.output_receive(state.model, message)
        loop(draw(effects(%{state | model: model}, outgoing)))

      {:worker_output_connection, pid, {:closed, reason}} when pid == state.output ->
        loop(draw(output_failed(state, reason)))

      {:worker_output_connection, pid, {:rejected, _id, reason}} when pid == state.output ->
        loop(draw(output_failed(state, reason)))

      {:worker_output_connection, _old, _message} ->
        loop(state)

      {:DOWN, monitor, :process, pid, reason}
      when monitor == state.output_monitor and pid == state.output ->
        loop(draw(output_failed(state, reason)))

      {:worker_output_poll, pid, token} when pid == state.output ->
        case state.output_tick do
          {_timer, ^token} ->
            {model, outgoing} = WorkerConversation.output_next(state.model)
            loop(effects(%{state | model: model, output_tick: nil}, outgoing))

          _ ->
            loop(state)
        end

      {:worker_output_retry, target, token} ->
        case state.output_retry do
          {_timer, ^token} when target == state.output_target ->
            loop(draw(%{state | output_retry: nil}))

          _ ->
            loop(state)
        end

      {:worker_output_poll, _old, _token} ->
        loop(state)

      :reconnect ->
        loop(draw(connect(state)))

      {port, {:data, {:eol, line}}} when port == state.agent ->
        line = state.agent_buffer <> line
        state = %{state | agent_buffer: ""}

        case JSON.decode(line) do
          {:ok, message} -> loop(draw(%{state | model: Model.agent(state.model, message)}))
          _ -> loop(state)
        end

      {port, {:data, {:noeol, part}}} when port == state.agent ->
        loop(%{state | agent_buffer: state.agent_buffer <> part})

      {port, {:exit_status, status}} when port == state.agent ->
        why = "it exited with #{status}; see #{agent_log()}"

        loop(
          draw(%{state | agent: nil, agent_buffer: "", model: Model.agent_gone(state.model, why)})
        )

      :reconcile ->
        {model, outgoing} = Console.refresh(state.model)
        state = effects(%{state | model: model}, outgoing)

        if state.socket && model.connected && model.console.phase == :ready &&
             is_nil(model.console.expected) && !Console.draft?(model),
           do: send_line(state, %{"op" => "refresh"})

        loop(state)
    end
  end

  defp keys(state, []), do: loop(draw(state))

  defp keys(state, [key | rest]) do
    {model, effects} = Model.key(state.model, key)
    state = %{state | model: model}

    if :quit in effects do
      stop_output(state)
      if state.socket, do: :gen_tcp.close(state.socket)
      if state.agent, do: Port.close(state.agent)
      :ok
    else
      state = effects(state, effects)

      keys(state, rest)
    end
  end

  defp effects(state, effects) do
    Enum.reduce(effects, state, fn
      {:send, %{"op" => "boot"} = message}, state ->
        send_line(state, message)

        Process.send_after(
          self(),
          {:boot_timeout, state.socket, state.model.console.boot_serial},
          5_000
        )

        state

      {:send, message}, state ->
        send_line(state, message)
        state

      {:worker_output_send, message}, state ->
        if state.output do
          WorkerOutputConnection.send_request(state.output, message)
          state
        else
          output_failed(state, :not_connected)
        end

      {:worker_output_poll, delay}, state ->
        schedule_output_poll(state, delay)

      :worker_output_restart, state ->
        stop_output(state)

      {:worker_output_retry, delay}, state ->
        output_failed(state, :output_unavailable, delay)

      {:open_url, url}, state ->
        AtlasTui.Browser.open(url, state.settings)
        state

      {:agent, message}, state ->
        to_agent(state, message)
    end)
  end

  # The agent, started when it is first needed.
  defp to_agent(state, message) do
    state = if state.agent, do: state, else: %{state | agent: start_agent(state.model.env)}
    Port.command(state.agent, [JSON.encode!(message), "\n"])
    state
  end

  defp start_agent(env) do
    atlas = Path.join(System.get_env("ATLAS_ROOT") || @root, "bin/atlas")

    Port.open({:spawn_executable, "/bin/sh"}, [
      :binary,
      :exit_status,
      {:line, 1_048_576},
      args: ["-c", ~s|exec "$0" steer --env "$1" 2>>"$2"|, atlas, env, agent_log()]
    ])
  end

  # Beside the environment's other logs (bin/atlas names their folder), else in tmp.
  defp agent_log,
    do: Path.join(System.get_env("ATLAS_TEST_ROOT") || System.tmp_dir!(), "steer.log")

  defp connect(state) do
    host = state.settings["control"]["host"] |> String.to_charlist()
    port = state.settings["control"]["port"]
    options = [:binary, packet: :line, active: true, buffer: 4_194_304]

    case :gen_tcp.connect(host, port, options, 2_000) do
      {:ok, socket} ->
        state = %{state | socket: socket, model: Model.disconnected(state.model)}

        send_line(state, Console.hello(state.model))
        Process.send_after(self(), {:handshake_timeout, socket}, 5_000)

        state

      {:error, _} ->
        Process.send_after(self(), :reconnect, @reconnect)
        %{state | socket: nil, model: Model.disconnected(state.model)}
    end
  end

  defp connection_timeout(state, reason) do
    if state.socket, do: :gen_tcp.close(state.socket)
    Process.send_after(self(), :reconnect, @reconnect)
    model = Model.disconnected(state.model)
    %{state | socket: nil, model: %{model | console: %{model.console | error: reason}}}
  end

  defp send_line(%{socket: nil}, _message), do: :ok

  defp send_line(%{socket: socket}, message),
    do: :gen_tcp.send(socket, [JSON.encode!(message), "\n"])

  defp draw(state) do
    {width, height} = size()
    state = %{state | model: AtlasTui.Legend.resize(state.model, width, height)}

    theme = AtlasTui.Palette.theme(state.settings["tui_theme"])

    {rows, model} = View.frame(state.model, width, height, state.reconcile)
    rows |> View.to_ansi(theme) |> IO.write()

    sync_output(%{state | model: model})
  end

  defp sync_output(state) do
    target = WorkerConversation.output_target(state.model)

    cond do
      target == nil ->
        stop_output(state)

      target == state.output_target and (state.output != nil or state.output_retry != nil) ->
        state

      true ->
        state = stop_output(state)
        {:ok, pid} = WorkerOutputConnection.start(self(), state.model.env, state.settings)
        %{state | output: pid, output_target: target, output_monitor: Process.monitor(pid)}
    end
  end

  defp stop_output(
         %{output: nil, output_target: nil, output_tick: nil, output_retry: nil} = state
       ),
       do: state

  defp stop_output(state) do
    if state.output, do: WorkerOutputConnection.stop(state.output)
    if state.output_monitor, do: Process.demonitor(state.output_monitor, [:flush])
    cancel_output_timer(state.output_tick)
    cancel_output_timer(state.output_retry)

    model =
      if state.model.conversation != nil and
           state.model.conversation.execution == state.output_target,
         do: WorkerConversation.output_disconnected(state.model),
         else: state.model

    %{
      state
      | model: model,
        output: nil,
        output_target: nil,
        output_monitor: nil,
        output_tick: nil,
        output_retry: nil
    }
  end

  defp output_failed(state, reason, delay \\ @reconnect) do
    target = state.output_target
    state = stop_output(state)
    token = make_ref()
    timer = Process.send_after(self(), {:worker_output_retry, target, token}, delay)

    notice = %{
      tone: "error",
      source: :worker_output,
      text: "Worker output disconnected (#{inspect(reason)}); guidance is independent."
    }

    %{
      state
      | output_target: target,
        output_retry: {timer, token},
        model: %{state.model | notice: notice}
    }
  end

  defp schedule_output_poll(%{output_tick: nil, output: pid} = state, delay) when pid != nil do
    token = make_ref()
    timer = Process.send_after(self(), {:worker_output_poll, pid, token}, delay)
    %{state | output_tick: {timer, token}}
  end

  defp schedule_output_poll(state, _delay), do: state
  defp cancel_output_timer(nil), do: :ok
  defp cancel_output_timer({timer, _token}), do: Process.cancel_timer(timer)

  defp size do
    with {:ok, width} <- :io.columns(), {:ok, height} <- :io.rows() do
      {width, height}
    else
      _ -> {100, 30}
    end
  end
end
