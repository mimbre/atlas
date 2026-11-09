defmodule AtlasRuntime.ClaudeTest do
  # The `claude` port with a fake Claude Code: a script that prints stream-json lines. No
  # real Claude Code runs in any test.
  use ExUnit.Case, async: true

  alias AtlasRuntime.Agent.Claude
  alias AtlasRuntime.Agent.Claude.Broker
  alias AtlasRuntime.Integrations.AtlasServer.Commands

  @moduletag :tmp_dir

  defp fake(dir, body) do
    path = Path.join(dir, "fake-claude")
    File.write!(path, "#!/bin/sh\n" <> body)
    File.chmod!(path, 0o755)
    path
  end

  # A stand-in for the build's `atlas`: it says how it was called.
  defp atlas_bin(dir) do
    bin = Path.join(dir, "build-bin")
    File.mkdir_p!(bin)
    path = Path.join(bin, "atlas")
    File.write!(path, "#!/bin/sh\necho \"build atlas: $* (file=$ATLAS_ENV_FILE as=$ATLAS_AS)\"\n")
    File.chmod!(path, 0o755)
    bin
  end

  defp opts(dir, command) do
    [
      agent: %{"command" => command},
      turns_dir: Path.join(dir, "turns"),
      env_file: Path.join(dir, "instance.json"),
      atlas_bin: atlas_bin(dir)
    ]
  end

  @turn %{key: "TU-1", item: "AS-1", agent: "trial"}

  defp messages(pid, acc \\ []) do
    receive do
      {:agent, ^pid, message} -> messages(pid, [message | acc])
    after
      2_000 -> Enum.reverse(acc)
    end
  end

  test "its stream is activity; exiting 0 ends the turn with its result; the stream is kept",
       %{tmp_dir: dir} do
    command =
      fake(dir, ~S"""
      printf '%s\n' '{"type":"system","subtype":"init"}'
      printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"atlas get AS-1"}}]}}'
      printf '%s\n' '{"type":"result","subtype":"success","result":"Handed it back.\nMore.","total_cost_usd":0.01}'
      """)

    {:ok, pid} = Claude.start(@turn, opts(dir, command))

    assert [
             {:activity, "claude: activity"},
             {:output, %{"kind" => "activity", "text" => "claude: activity"}},
             {:activity, "claude: assistant activity"},
             {:output, %{"kind" => "tool", "tool_name" => "Bash", "status" => "started"}},
             {:activity, "claude: completed"},
             {:output, %{"kind" => "text", "text" => "Handed it back.\nMore."}},
             {:ended, "Handed it back. (cost $0.0100)"}
           ] = messages(pid)

    stream = File.read!(Path.join([dir, "turns", "TU-1", "stream.jsonl"]))
    assert stream =~ ~s("total_cost_usd":0.01)
  end

  test "reasoning, tool inputs/results and raw diagnostic lines stay out of live output",
       %{tmp_dir: dir} do
    command =
      fake(dir, ~S"""
      printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"PRIVATE_REASONING"},{"type":"text","text":"Public progress"},{"type":"tool_use","name":"Bash","input":{"command":"PRIVATE_COMMAND","environment":"PRIVATE_ENV"}}]}}'
      printf '%s\n' '{"type":"user","message":{"content":[{"type":"tool_result","content":"PRIVATE_RESULT"}]}}'
      printf '%s\n' 'PRIVATE_DIAGNOSTIC'
      printf '%s\n' '{"type":"result","subtype":"error_during_execution","result":"PRIVATE_ERROR"}'
      """)

    {:ok, pid} = Claude.start(@turn, opts(dir, command))
    messages = messages(pid)
    assert {:output, %{"kind" => "text", "text" => "Public progress"}} in messages

    assert {:output, %{"kind" => "tool", "tool_name" => "Bash", "status" => "started"}} in messages

    refute inspect(messages) =~ "PRIVATE_"
    assert File.read!(Path.join([dir, "turns", @turn.key, "stream.jsonl"])) =~ "PRIVATE_COMMAND"
  end

  test "any other exit is a crash; stop kills the process", %{tmp_dir: dir} do
    # Monitored as it starts: a fake that exits at once can be gone before a later
    # Process.monitor/1, whose DOWN then says :noproc, not why it ended. Its exit always
    # comes: no deadline.
    {:ok, {pid, ref}} = Claude.start_monitor(@turn, opts(dir, fake(dir, "exit 3\n")))

    assert {:exit, 3} == receive(do: ({:DOWN, ^ref, :process, ^pid, reason} -> reason))

    # The adapter intentionally removes system tools from PATH. exec also keeps the
    # long-lived fake on the exact port PID that stop must terminate.
    {:ok, pid} =
      Claude.start(%{@turn | key: "TU-2"}, opts(dir, fake(dir, "exec /bin/sleep 30\n")))

    %{os_pid: os_pid} = :sys.get_state(pid)
    :ok = Claude.stop(pid)
    Process.sleep(300)
    {_, status} = System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)
    assert status != 0
  end

  test "no command in the settings: nothing starts", %{tmp_dir: dir} do
    assert {:error, {:no_command, nil}} =
             Claude.start(@turn, Keyword.put(opts(dir, nil), :agent, %{}))
  end

  # The turn's files, with its broker (owned by the test process, as by the port).
  defp turn_files(dir) do
    folder = Path.join(dir, "turn")
    File.mkdir_p!(folder)
    o = opts(dir, "unused")
    atlas = Path.join(o[:atlas_bin], "atlas")

    {:ok, %{port: port}} =
      Broker.open(%{atlas: atlas, env_file: o[:env_file], agent: "trial", folder: folder})

    :ok = Commands.wrapper(folder, o, port)
    {folder, o, Commands.environment(@turn, o, folder)}
  end

  # As Claude Code runs a command: its snapshot first, which sets PATH back to its own
  # (Claude Code 2.1.280 builds `source <snapshot> 2>/dev/null || true && … && eval …`).
  defp through_prefix(dir, folder, env) do
    snapshot = Path.join(dir, "snapshot.sh")
    File.write!(snapshot, "export PATH=#{env["PATH"]}:/usr/bin:/bin\n")

    fn command ->
      System.cmd(
        env["CLAUDE_CODE_SHELL_PREFIX"],
        ["source \"#{snapshot}\" 2>/dev/null || true && eval #{inspect(command)}"],
        env: Enum.to_list(env),
        stderr_to_stdout: true,
        cd: folder
      )
    end
  end

  test "the turn's atlas asks its broker: the instance and the agent are the broker's",
       %{tmp_dir: dir} do
    {folder, o, env} = turn_files(dir)

    assert env["PATH"] == Path.join(folder, "bin") <> ":" <> Path.join(folder, "sys")
    # Its sys folder holds what Claude Code needs for itself (macOS: security) and no more.
    assert File.ls!(Path.join(folder, "sys")) -- ["security"] == []
    assert env["ATLAS_AS"] == "trial" and env["ATLAS_ENV_FILE"] == o[:env_file]
    assert env["CLAUDE_CODE_TMPDIR"] == Commands.tmp(folder)
    refute Map.has_key?(env, "GITHUB_TOKEN") or Map.has_key?(env, "MIX_ENV")

    # Beside the folder, not in it: what the agent's commands may not write.
    for file <- [Commands.shell(folder), Commands.profile(folder), Commands.tmp(folder)],
        do: refute(String.starts_with?(file, folder <> "/"))

    # The client alone, without the sandbox: what the broker answers.
    run = fn command ->
      System.cmd("/bin/bash", ["-c", command], env: Enum.to_list(env), stderr_to_stdout: true)
    end

    for command <- [
          "atlas get SC-Atlas-01 --env prod",
          "atlas list widget --env test",
          "atlas set IS-Atlas-01 title=x --env=prod",
          "atlas put widget --title x",
          "atlas help",
          "atlas"
        ] do
      {out, status} = run.(command)
      assert status == 2 and out =~ "atlas (turn): refused", "#{command}: #{out}"
    end

    {out, 0} = run.("atlas get X")
    assert out == "build atlas: get X (file=#{o[:env_file]} as=trial)\n"

    # What the agent sets in its environment does not reach the command.
    {out, 0} = run.("ATLAS_ENV_FILE=/elsewhere.json ATLAS_AS=coordinator atlas get X")
    assert out == "build atlas: get X (file=#{o[:env_file]} as=trial)\n"

    {out, 0} = run.(~s(atlas set X "title=two words" --cause "a\nb"))
    assert out =~ "build atlas: set X title=two words --cause a\nb (file="
  end

  @tag :sandbox
  @tag skip: AtlasRuntime.TestHost.missing(:nested_sandbox)
  test "in the sandbox the agent's commands run bash and the turn's atlas, and no more",
       %{tmp_dir: dir} do
    {folder, o, env} = turn_files(dir)
    run = through_prefix(dir, folder, env)

    # Names: only atlas is on PATH, and PATH stays so.
    for tool <- ~w(security head ls git) do
      {out, status} = run.("#{tool} --version")
      assert status == 127 and out =~ "#{tool}: command not found", "#{tool}: #{out}"
    end

    {out, 127} = run.("PATH=/usr/bin:$PATH head -1 /etc/hosts")
    assert out =~ "PATH: readonly variable"

    # Full paths: the sandbox runs nothing but bash and the turn's atlas.
    for command <- ["/usr/bin/security help", "/usr/bin/head -1 /etc/hosts", "/bin/ls ~"] do
      {out, status} = run.(command)
      assert status == 126 and out =~ "Operation not permitted", "#{command}: #{out}"
    end

    # Bash's own reads and writes reach nothing.
    {out, _} = run.(~s(echo x > "#{Path.join(dir, "f")}"))
    assert out =~ "Operation not permitted" and not File.exists?(Path.join(dir, "f"))
    {out, _} = run.(~s(echo x > "#{Path.join(Commands.tmp(folder), "other")}"))
    assert out =~ "Operation not permitted"
    {out, _} = run.("while read l; do echo \"$l\"; done < /etc/hosts")
    assert out =~ "Operation not permitted"

    # The network: the broker alone, not another port, even on 127.0.0.1.
    {:ok, other} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, other_port} = :inet.port(other)
    {out, _} = run.("exec 3<>/dev/tcp/127.0.0.1/#{other_port}")
    assert out =~ "Operation not permitted"

    # What it may: the turn's atlas, and Claude Code's cwd file after each command.
    {out, 0} = run.("atlas get X")
    assert out == "build atlas: get X (file=#{o[:env_file]} as=trial)\n"
    cwd = Path.join(Commands.tmp(folder), "claude-ab12-cwd")
    {_, 0} = run.(~s(pwd -P >| "#{cwd}"))
    assert File.read!(cwd) =~ "turn"

    # Every command it ran is kept beside the folder, one line each.
    kept = File.read!(Commands.commands(folder)) |> String.split("\n", trim: true)
    assert List.last(kept) =~ "pwd\\ -P"
  end

  @tag :no_sandbox
  test "where there is no sandbox, none of the agent's commands runs", %{tmp_dir: dir} do
    {folder, _o, env} = turn_files(dir)
    {out, 126} = through_prefix(dir, folder, env).("atlas get X")
    assert out =~ "no sandbox on this machine, so no command runs"
    refute out =~ "build atlas"
    assert File.read!(Commands.commands(folder)) =~ "atlas\\ get\\ X"
  end

  # A stand-in for the build's `atlas` that answers help as the real one does (its output,
  # taken from a private instance, 4 Nov 2026).
  defp helpful_atlas(dir) do
    path = Path.join(dir, "helpful-atlas")

    File.write!(path, ~S"""
    #!/bin/sh
    case "$1 $2" in
      "get --help") cat <<'EOF'
        atlas put  <kind> [--in <key>] --<field> <text> ...  create; prints the new item
        atlas set  <key> <field>=<text> ...                  change; prints the item
                   <association>=<key>                       link (empty: remove the link)
                   --cause <text>                            why (put and set), kept with it
        atlas get  <key>                                     one item, with what hangs under it
        atlas list <kind> [--in <key>]                       the items of a kind (under <key>)
        atlas delete <key>                                   delete; refused while anything hangs under it
        atlas tools                                          the agent's tools: Control's actions
        atlas plan --on <key or path> <request ...>          what the agent proposes; writes nothing

    Kinds (from rela's description, through Control):

    Widget (widget)
      Kind: widget
    EOF
      ;;
      "help card") cat <<'EOF'
    Kinds (from rela's description, through Control):

    Card (card)
      Kind: card
      Fields:
        of: text; required; asked on create
      Links: owned_by: to clerk, at most one; set owned_by=<key>, empty removes it
    EOF
      ;;
      "turn --json") echo '{"key":"TU-1","on":"C-1","read_first":"Read first.\\nRests on:\\n- M-1 Ship safely."}' ;;
      *) echo "atlas: no" >&2; exit 2 ;;
    esac
    """)

    File.chmod!(path, 0o755)
    path
  end

  test "its rules show the allowed atlas commands and the item's kind, as atlas help says",
       %{tmp_dir: dir} do
    config = %{atlas: helpful_atlas(dir), env_file: "/i.json", agent: "trial", folder: dir}
    forms = Commands.forms(config, "card")

    # The usage lines of get, list and set, and what goes on from set's line.
    for line <- [
          "atlas set  <key> <field>=<text> ...",
          "<association>=<key>                       link (empty: remove the link)",
          "--cause <text>                            why (put and set), kept with it",
          "atlas get  <key>",
          "atlas list <kind> [--in <key>]"
        ],
        do: assert(forms =~ line, line)

    # Not the commands the turn may not use, nor the other kinds.
    for line <- ["atlas put", "atlas delete", "atlas tools", "atlas plan", "Widget", "Kinds ("],
        do: refute(forms =~ line, line)

    # The kind's part, links included: how a link is set.
    assert forms =~ "What your item's kind, card, has (from `atlas help card`):"
    assert forms =~ "Links: owned_by: to clerk, at most one; set owned_by=<key>"

    # What the worker reads first, as `atlas turn` says it, before the commands.
    assert forms =~
             "\n\nRead first.\nRests on:\n- M-1 Ship safely.\n\nThe atlas commands you may use"

    # In the turn's rules, after what is expected of it.
    {_, args} = Claude.command(@turn, %{"command" => "claude"}, forms)
    rules = Enum.at(args, Enum.find_index(args, &(&1 == "--append-system-prompt")) + 1)
    assert String.ends_with?(rules, "empty removes it")

    # A turn whose atlas does not answer runs with the rules alone.
    assert Commands.forms(config, "nothing") =~ "atlas set"
    refute Commands.forms(config, "nothing") =~ "What your item's kind"
    assert Commands.forms(%{config | atlas: Path.join(dir, "no-atlas")}, "card") == ""
  end

  test "its command: confined, headless, with the agent's model and budget" do
    {exe, args} =
      Claude.command(@turn, %{"command" => "claude", "model" => "sonnet", "budget_usd" => 0.5})

    assert exe == "claude"

    for flag <- ~w(-p --restricted --strict-mcp-config --no-session-persistence --verbose),
        do: assert(flag in args)

    assert ["--tools", "Bash" | _] = Enum.drop_while(args, &(&1 != "--tools"))

    assert ["--permission-mode", "dontAsk" | _] =
             Enum.drop_while(args, &(&1 != "--permission-mode"))

    assert ["--allowedTools", "Bash(atlas get:*)", "Bash(atlas list:*)", "Bash(atlas set:*)" | _] =
             Enum.drop_while(args, &(&1 != "--allowedTools"))

    assert ["--max-budget-usd", "0.5" | _] = Enum.drop_while(args, &(&1 != "--max-budget-usd"))
  end
end
