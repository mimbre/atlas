defmodule AtlasRuntime.Agent.Claude do
  @moduledoc """
  Claude Code, headless, as the agent behind a turn (IS-Atlas-18; the design part is
  `~/agent-reports/atlas/2026-11-04-is-18-claude-port-design.md`). One OS process per turn,
  owned by this process through an Erlang port:

  - it runs `claude -p` with `--output-format stream-json`, confined: `--restricted`, no MCP,
    Bash only for the `atlas` commands it is allowed, nobody asked for permission;
  - in a fresh folder of its own (`turns_dir/<turn key>`), with an environment cleared down
    to a few names (no token or other setting of the machine's reaches it), `ATLAS_AS` set
    to the agent, so what it writes through `atlas` is by it, and a PATH of one folder that
    holds only a wrapper `atlas`: the machine's instance alone (it refuses `--env`, another
    `ATLAS_ENV_FILE`, and any command but get, list and set), never prod or test;
  - the agent's own commands run through a shell prefix (`CLAUDE_CODE_SHELL_PREFIX`) that
    keeps their PATH to that one folder (IS-Atlas-92): what Claude Code needs for itself
    (`sys`) is on its own PATH only, and every command it ran is kept (`<turn key>.commands`);
  - and in an OS sandbox (IS-Atlas-94, macOS `sandbox-exec`) that lets them run bash and the
    turn's `atlas` alone, read nothing of the machine's, write nothing, and reach only the
    turn's broker (`AtlasRuntime.Agent.Claude.Broker`), which runs the build's `atlas`
    outside it; where there is no sandbox, none of the agent's commands runs;
  - every line it prints is kept in its folder (`stream.jsonl`), for what it ran and cost;
  - every line it prints is activity; it exiting 0 ends the turn with its result, any other
    exit is a crash;
  - `stop/1` ends it: SIGTERM, then SIGKILL after a grace.

  The command is the agent's settings' `command`, and there is no default: nothing runs
  Claude Code unless a machine's settings name it (`"command": "claude"`); tests give a fake
  that prints the same stream. Its `model`, `budget_usd` and `allowed` (the `atlas`
  commands, `get list set` by default) come from there too.
  """
  @behaviour AtlasRuntime.Agent

  use GenServer

  require Logger

  alias AtlasRuntime.Agent.Claude.Broker
  alias AtlasRuntime.Integrations.AtlasServer.Commands

  @grace 5_000

  @impl AtlasRuntime.Agent
  def start(turn, opts), do: GenServer.start(__MODULE__, {self(), turn, opts})

  @impl AtlasRuntime.Agent
  def start_monitor(turn, opts),
    do: :gen_server.start_monitor(__MODULE__, {self(), turn, opts}, [])

  @impl AtlasRuntime.Agent
  def stop(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    :ok
  catch
    :exit, _ -> :ok
  end

  @doc """
  The command line for a turn: `{executable, args}` (for tests and the design). `forms` is
  what `AtlasRuntime.Integrations.AtlasServer.Commands.forms/2` read from `atlas help`, for the rules.
  """
  def command(turn, settings, forms \\ "") do
    allowed =
      for tool <- String.split(settings["allowed"] || "get list set"),
          do: "Bash(atlas #{tool}:*)"

    args =
      ["-p", Commands.prompt(turn), "--output-format", "stream-json", "--verbose"] ++
        ["--restricted", "--strict-mcp-config", "--tools", "Bash"] ++
        ["--allowedTools" | allowed] ++
        ["--permission-mode", "dontAsk", "--no-session-persistence"] ++
        ["--model", settings["model"] || "sonnet"] ++
        ["--max-budget-usd", to_string(settings["budget_usd"] || 0.5)] ++
        ["--append-system-prompt", Commands.rules(turn, forms)]

    {settings["command"], args}
  end

  @impl GenServer
  def init({turn_pid, turn, opts}) do
    settings = Keyword.get(opts, :agent, %{})
    folder = Path.join(Keyword.fetch!(opts, :turns_dir), turn.key)
    File.mkdir_p!(folder)
    command = settings["command"]

    # A script run by node (Claude Code's cli.js) when the settings name node, so the
    # process's PATH need not hold node either.
    {exe, first} =
      case settings["node"] do
        node when is_binary(node) ->
          {node, [command]}

        _ ->
          {command && (System.find_executable(command) || (File.exists?(command) && command)), []}
      end

    broker = Commands.config(turn, settings, opts, folder)

    with true <- is_binary(exe) and File.exists?(exe),
         {:ok, %{port: port}} <- Broker.open(broker),
         :ok <- Commands.wrapper(folder, opts, port) do
      {_, args} = command(turn, settings, Commands.forms(broker, turn[:kind]))
      # Its stdin is /dev/null (else Claude Code waits 3 s for one); exec keeps the pid.
      args = ["-c", ~s(exec "$0" "$@" < /dev/null), exe | first ++ args]

      port =
        Port.open({:spawn_executable, "/bin/sh"}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          {:line, 65_536},
          {:args, args},
          {:cd, folder},
          {:env, port_env(Commands.environment(turn, opts, folder))}
        ])

      # nil when the process exited already (its exit status still comes as a message).
      os_pid =
        case Port.info(port, :os_pid) do
          {:os_pid, os_pid} -> os_pid
          _ -> nil
        end

      log = File.open!(Path.join(folder, "stream.jsonl"), [:write, :utf8])

      {:ok, %{turn_pid: turn_pid, port: port, os_pid: os_pid, result: nil, partial: "", log: log}}
    else
      {:error, why} -> {:stop, why}
      _ -> {:stop, {:no_command, command}}
    end
  end

  # Every name of the machine's environment is unset but those given.
  defp port_env(env) do
    unset = for {name, _} <- System.get_env(), not Map.has_key?(env, name), do: {name, false}

    for {name, value} <- Enum.to_list(env) ++ unset,
        do: {String.to_charlist(name), if(value, do: String.to_charlist(value), else: false)}
  end

  @impl GenServer
  def handle_info({port, {:data, {:noeol, part}}}, %{port: port} = state),
    do: {:noreply, %{state | partial: state.partial <> part}}

  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    line = state.partial <> line
    IO.write(state.log, line <> "\n")
    {what, result, output} = event(line)
    AtlasRuntime.Agent.emit(state.turn_pid, what, output)
    {:noreply, %{state | partial: "", result: result || state.result}}
  end

  def handle_info({port, {:exit_status, 0}}, %{port: port} = state) do
    send(state.turn_pid, {:agent, self(), {:ended, state.result || "it exited"}})
    {:stop, :normal, %{state | os_pid: nil}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state),
    do: {:stop, {:exit, status}, %{state | os_pid: nil}}

  def handle_info(_message, state), do: {:noreply, state}

  # Stopped from Runtime's side (or crashed here): the process goes too.
  @impl GenServer
  def terminate(_reason, %{os_pid: os_pid}) when is_integer(os_pid) do
    pid = Integer.to_string(os_pid)
    System.cmd("kill", ["-TERM", pid], stderr_to_stdout: true)

    spawn(fn ->
      Process.sleep(@grace)
      System.cmd("kill", ["-KILL", pid], stderr_to_stdout: true)
    end)

    :ok
  end

  def terminate(_reason, _state), do: :ok

  # Native lines stay in their existing artifact. Persisted activity is generic and
  # the live projection admits only public assistant text and safe tool metadata.
  defp event(line) do
    case JSON.decode(line) do
      {:ok, %{"type" => "result", "subtype" => "success", "result" => text} = event}
      when is_binary(text) ->
        result = first_line(text) <> cost(event)
        {"claude: completed", result, [%{"kind" => "text", "text" => text}]}

      {:ok, %{"type" => "result"}} ->
        {"claude: finished", "Claude finished", []}

      {:ok, %{"type" => "assistant", "message" => %{"content" => content}}}
      when is_list(content) ->
        {"claude: assistant activity", nil, Enum.flat_map(content, &part/1)}

      _ ->
        {"claude: activity", nil, []}
    end
  end

  defp part(%{"type" => "tool_use", "name" => name}),
    do: [
      %{
        "kind" => "tool",
        "tool_name" => AtlasRuntime.Agent.tool_name(name),
        "status" => "started"
      }
    ]

  defp part(%{"type" => "text", "text" => text}) when is_binary(text),
    do: [%{"kind" => "text", "text" => text}]

  defp part(_), do: []

  # What Claude Code says the turn cost, kept with its result.
  defp cost(%{"total_cost_usd" => usd}) when is_number(usd),
    do: " (cost $#{:erlang.float_to_binary(usd / 1, decimals: 4)})"

  defp cost(_event), do: ""

  defp first_line(text), do: text |> to_string() |> String.split("\n") |> hd() |> short()
  defp short(text), do: text |> to_string() |> String.slice(0, 120)
end
