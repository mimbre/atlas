defmodule AtlasRuntime.Integrations.AtlasServer.Commands do
  @moduledoc "Atlas-only command access, help discovery and confined turn environment."
  alias AtlasRuntime.Agent.Claude.Broker

  def prompt(turn) do
    "You are #{turn.agent}, in a turn on #{turn.item} (turn #{turn.key}). " <>
      "Start with `atlas get #{turn.item}`: its What to do part says what is expected of you."
  end

  def rules(turn, forms) do
    "You act on Atlas only through the atlas commands you are allowed. Do what is " <>
      "expected of you on #{turn.item}, then end your turn with one change on it, with a " <>
      "cause that says what you did and why (`atlas set #{turn.item} … --cause \"…\"`), and stop." <>
      forms
  end

  @doc """
  How to call the allowed `atlas` commands, and what the item's kind has (IS-Atlas-95), as
  `atlas help` says it: its usage lines for those commands (`atlas get --help`), and the
  kind's section (`atlas help <kind>`: its fields, and how a link such as `assigned_to` is
  set). First, what the worker reads before it acts, as `atlas turn` says it (the item's
  anchors and the standing rules, its `read_first`). Read through the build's `atlas`, so
  nothing of it is written here. Empty where `atlas` does not answer: the turn then runs
  with the rules alone.
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

    first =
      case Broker.run(["turn", "--json"], config) do
        {out, 0} ->
          case JSON.decode(out) do
            {:ok, %{"read_first" => text}} when is_binary(text) and text != "" -> text
            _ -> nil
          end

        _ ->
          nil
      end

    Enum.join(
      [
        if(first, do: "\n\n" <> first),
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

  def config(turn, settings, opts, folder) do
    %{
      atlas: Keyword.get(opts, :atlas_bin) && Path.join(Keyword.get(opts, :atlas_bin), "atlas"),
      env_file: Keyword.get(opts, :env_file),
      agent: turn.agent,
      allowed: settings["allowed"],
      folder: folder
    }
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
end
