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

  @grace 5_000

  @impl AtlasRuntime.Agent
  def start(turn, opts), do: GenServer.start(__MODULE__, {self(), turn, opts})

  @impl AtlasRuntime.Agent
  def stop(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    :ok
  catch
    :exit, _ -> :ok
  end

  @doc """
  The command line for a turn: `{executable, args}` (for tests and the design). `forms` is
  what `forms/2` read from `atlas help`, for the rules.
  """
  def command(turn, settings, forms \\ "") do
    allowed =
      for tool <- String.split(settings["allowed"] || "get list set"),
          do: "Bash(atlas #{tool}:*)"

    args =
      ["-p", prompt(turn), "--output-format", "stream-json", "--verbose"] ++
        ["--restricted", "--strict-mcp-config", "--tools", "Bash"] ++
        ["--allowedTools" | allowed] ++
        ["--permission-mode", "dontAsk", "--no-session-persistence"] ++
        ["--model", settings["model"] || "sonnet"] ++
        ["--max-budget-usd", to_string(settings["budget_usd"] || 0.5)] ++
        ["--append-system-prompt", rules(turn, forms)]

    {settings["command"], args}
  end

  defp prompt(turn) do
    "You are #{turn.agent}, in a turn on #{turn.item} (turn #{turn.key}). " <>
      "Start with `atlas get #{turn.item}`: its What to do part says what is expected of you."
  end

  defp rules(turn, forms) do
    "You act on Atlas only through the atlas commands you are allowed. Do what is " <>
      "expected of you on #{turn.item}, then end your turn with one change on it, with a " <>
      "cause that says what you did and why (`atlas set #{turn.item} … --cause \"…\"`), and stop." <>
      forms
  end

  @doc """
  How to call the allowed `atlas` commands, and what the item's kind has (IS-Atlas-95), as
  `atlas help` says it: its usage lines for those commands (`atlas get --help`), and the
  kind's section (`atlas help <kind>`: its fields, and how a link such as `assigned_to` is
  set). Read through the build's `atlas`, so nothing of it is written here. Empty where
  `atlas` does not answer: the turn then runs with the rules alone.
  """
  def forms(config, kind) do
    allowed = String.split(config[:allowed] || "get list set")

    usage =
      case Broker.run(["get", "--help"], config) do
        {out, 0} -> usage_lines(out, allowed)
        _ -> []
      end

    section =
      case kind && Broker.run(["help", kind], config) do
        {out, 0} -> out |> String.split("\n") |> Enum.drop_while(&(&1 =~ ~r/^Kinds |^$/))
        _ -> []
      end

    Enum.join(
      [
        if(usage != [],
          do:
            "\n\nThe atlas commands you may use (from `atlas help`):\n" <> Enum.join(usage, "\n")
        ),
        if(section != [],
          do:
            "\n\nWhat your item's kind, #{kind}, has (from `atlas help #{kind}`):\n" <>
              String.trim_trailing(Enum.join(section, "\n"))
        )
      ],
      ""
    )
  end

  # Its usage block (before the kinds): the lines of the allowed commands, each with the
  # lines that go on from it (indented, no `atlas` of their own).
  defp usage_lines(out, allowed) do
    out
    |> String.split("\n")
    |> Enum.take_while(&(not String.starts_with?(&1, "Kinds ")))
    |> Enum.reduce({[], false}, fn line, {kept, keep?} ->
      case Regex.run(~r/^\s*atlas\s+(\S+)/, line) do
        [_, command] ->
          {if(command in allowed, do: [line | kept], else: kept), command in allowed}

        nil when keep? and line != "" ->
          {[line | kept], true}

        nil ->
          {kept, false}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
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

    broker = %{
      atlas: Keyword.get(opts, :atlas_bin) && Path.join(Keyword.get(opts, :atlas_bin), "atlas"),
      env_file: Keyword.get(opts, :env_file),
      agent: turn.agent,
      allowed: settings["allowed"],
      folder: folder
    }

    with true <- is_binary(exe) and File.exists?(exe),
         {:ok, %{port: port}} <- Broker.open(broker),
         :ok <- wrapper(folder, opts, port) do
      {_, args} = command(turn, settings, forms(broker, turn[:kind]))
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
          {:env, port_env(environment(turn, opts, folder))}
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

  @kept ~w(HOME USER LOGNAME TMPDIR LANG LC_ALL LC_CTYPE TERM)
  # What Claude Code runs by name for itself: macOS's keychain tool, for its login.
  @sys ["/usr/bin/security"]

  @doc """
  The turn's whole environment: a few names kept from the machine's (home, user, language),
  then which agent it is, the instance's settings file, no update of the build, and a PATH
  of the turn's own `bin` folder, which holds the wrapper `atlas`, and its `sys` folder,
  which holds only what Claude Code itself needs: on macOS `security`, with which it reads
  its login from the keychain (without it: "Not logged in"). The agent's own commands do
  not see `sys`: they run through the turn's shell prefix (`shell/1`).
  """
  def environment(turn, opts, folder) do
    kept = for name <- @kept, value = System.get_env(name), into: %{}, do: {name, value}

    Map.merge(kept, %{
      "ATLAS_AS" => turn.agent,
      "ATLAS_ENV_FILE" => Keyword.get(opts, :env_file) || "",
      "ATLAS_NO_UPDATE" => "1",
      "PATH" => Path.join(folder, "bin") <> ":" <> Path.join(folder, "sys"),
      "CLAUDE_CODE_SHELL_PREFIX" => shell(folder),
      "CLAUDE_CODE_TMPDIR" => tmp(folder),
      "SHELL" => "/bin/bash"
    })
  end

  # Every name of the machine's environment is unset but those given.
  defp port_env(env) do
    unset = for {name, _} <- System.get_env(), not Map.has_key?(env, name), do: {name, false}

    for {name, value} <- Enum.to_list(env) ++ unset,
        do: {String.to_charlist(name), if(value, do: String.to_charlist(value), else: false)}
  end

  @doc """
  The turn's sandbox and the files around it (IS-Atlas-92, IS-Atlas-94), given the port of
  its broker (`AtlasRuntime.Agent.Claude.Broker`):

  - `<folder>/bin/atlas`: the turn's only `atlas`, a few lines of bash that hand their
    arguments to the broker over `/dev/tcp` and print what it answers;
  - `<folder>/sys`: what Claude Code needs for itself (macOS: `security`);
  - beside the folder, where the agent's commands cannot write: the shell prefix
    (`shell/1`), the sandbox's profile (`profile/1`), the log of every command it ran
    (`commands/1`) and Claude Code's own temporary folder (`tmp/1`).
  """
  def wrapper(folder, opts, port) do
    if is_binary(Keyword.get(opts, :env_file)) and is_binary(Keyword.get(opts, :atlas_bin)) do
      dir = Path.join(folder, "bin")
      File.mkdir_p!(dir)
      atlas = Path.join(dir, "atlas")
      File.write!(atlas, client_script(port))
      File.chmod!(atlas, 0o755)
      sys = Path.join(folder, "sys")
      File.mkdir_p!(sys)

      for tool <- @sys, File.exists?(tool) do
        link = Path.join(sys, Path.basename(tool))
        File.rm(link)
        :ok = File.ln_s(tool, link)
      end

      File.mkdir_p!(tmp(folder))
      File.chmod!(tmp(folder), 0o700)

      File.write!(
        profile(folder),
        profile_text(real(folder), real(atlas), real(tmp(folder)), port)
      )

      File.write!(shell(folder), shell_script(dir, commands(folder), profile(folder)))
      File.chmod!(shell(folder), 0o755)
      :ok
    else
      {:error, :no_instance}
    end
  end

  # Inside the sandbox bash has no other way out: its own /dev/tcp, to the broker alone.
  defp client_script(port) do
    """
    #!/bin/bash
    # This turn's only atlas (IS-Atlas-94): the turn's broker, outside the sandbox, runs the
    # build's atlas on this machine's instance, as this turn's agent, and answers here.
    exec 3<>/dev/tcp/127.0.0.1/#{port} || { echo "atlas (turn): its broker does not answer" >&2; exit 2; }
    printf '%d\\0' $# >&3
    [ $# -gt 0 ] && printf '%s\\0' "$@" >&3
    IFS= read -r -d '' out <&3
    IFS= read -r -d '' status <&3
    printf '%s' "$out"
    exit "${status:-2}"
    """
  end

  @doc """
  The turn's shell prefix, beside its folder, not in it. Claude Code runs each of the agent's
  Bash commands as `<prefix> '<its command string>'` (`CLAUDE_CODE_SHELL_PREFIX`).
  """
  def shell(folder), do: folder <> ".shell"

  @doc "What the prefix ran, one command string per line (shell-quoted), beside the folder."
  def commands(folder), do: folder <> ".commands"

  @doc "The sandbox's profile (macOS `sandbox-exec`), beside the folder."
  def profile(folder), do: folder <> ".sb"

  @doc "Claude Code's own temporary folder (`CLAUDE_CODE_TMPDIR`), beside the folder."
  def tmp(folder), do: folder <> ".tmp"

  # Each command is kept first, with builtins only, so a turn shows that it went through
  # here; then it runs in the sandbox, or not at all where there is none (fail closed). Its
  # PATH is the turn's bin alone, readonly: the shell snapshot Claude Code sources first
  # sets PATH back to its own (with sys), and so could the agent.
  defp shell_script(bin, log, profile) do
    """
    #!/bin/bash
    # This turn's agent's own commands (IS-Atlas-92, IS-Atlas-94): in the turn's sandbox,
    # with only the turn's atlas on their PATH.
    printf '%q\\n' "$1" >> #{sh(log)}
    if [ ! -x /usr/bin/sandbox-exec ]; then
      echo "atlas (turn): no sandbox on this machine, so no command runs" >&2
      exit 126
    fi
    exec /usr/bin/sandbox-exec -f #{sh(profile)} /bin/bash -c \
      'PATH=#{String.replace(sh(bin), "'", "'\\''")}; export PATH; readonly PATH; eval "$1"' turn "$1"
    """
  end

  # Nothing is allowed but what bash itself needs to start and print, the turn's atlas,
  # the broker's port on 127.0.0.1, and the file Claude Code writes its cwd to after each
  # command. Bash reads `/`, and its cwd's path for `pwd`: only the turn folder's own,
  # so nothing else shows even whether it exists. Paths are the real ones: the sandbox sees
  # no symbolic links.
  defp profile_text(folder, atlas, tmp, port) do
    path = for dir <- ancestors(folder), do: "(literal #{sb(dir)})"

    """
    (version 1)
    ; This turn's sandbox (IS-Atlas-94).
    (deny default)
    (allow process-fork)
    (allow process-exec (literal "/bin/bash") (literal #{sb(atlas)}))
    (allow file-read* (literal #{sb(atlas)})
      (subpath "/usr/lib") (subpath "/System") (subpath "/private/var/db/dyld")
      (literal "/") (literal "/dev") (literal "/dev/null") (literal "/dev/urandom"))
    (allow file-read-metadata (literal "/") (literal "/dev") #{Enum.join(path, " ")})
    (allow file-write* (literal "/dev/null")
      (require-all (subpath #{sb(tmp)}) (regex #"/claude-[^/]+-cwd$")))
    (allow sysctl-read)
    (allow network-outbound (remote ip "localhost:#{port}"))
    """
  end

  defp ancestors("/"), do: []
  defp ancestors(dir), do: [dir | ancestors(Path.dirname(dir))]

  defp sb(text), do: ~s(") <> String.replace(text, ~w(\\ "), &("\\" <> &1)) <> ~s(")

  # The path with its symbolic links resolved (macOS: /tmp and /var are /private's).
  defp real(path) do
    case System.find_executable("realpath") do
      nil ->
        path

      realpath ->
        case System.cmd(realpath, [path], stderr_to_stdout: true) do
          {out, 0} -> String.trim(out)
          _ -> path
        end
    end
  end

  defp sh(text), do: "'" <> String.replace(text, "'", "'\\''") <> "'"

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
