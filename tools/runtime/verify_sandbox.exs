# Model-free integration check: Runtime adapter -> protocol bridge -> official
# Codex sandbox -> real shell write. The bridge only replaces model scheduling.
# Run from beam/apps/atlas_runtime:
#   MIX_ENV=test mix run --no-start ../../../tools/runtime/verify_sandbox.exs
ExUnit.start()

defmodule AtlasRuntime.NativeSandboxVerification do
  use ExUnit.Case, async: true
  alias AtlasRuntime.Agent.Native
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    on_exit(fn -> File.rm_rf!(dir) end)
    assert File.exists?("/usr/bin/sandbox-exec"), "This retained check requires macOS Seatbelt"
    native = System.find_executable("codex") || flunk("Install the official Codex CLI")
    assert System.find_executable("python3"), "Python 3 is required by this script's bridge fixture"
    {version, 0} = System.cmd(native, ["--version"])
    IO.puts("Native sandbox verification: #{String.trim(version)}")
    workspace = Path.join(dir, "workspace") |> Path.expand()
    config = Path.join(dir, "codex-home") |> Path.expand()
    File.mkdir_p!(workspace)
    File.mkdir_p!(config)
    File.write!(Path.join(workspace, "proof.txt"), "before\n")
    bridge = Path.join(dir, "sandbox-probe") |> Path.expand()

    # `sandbox` requires permission profiles in Codex 0.166.0. Built-ins are
    # :read-only and :workspace, documented at developers.openai.com/codex/permissions.
    # Do not read the user's Codex home or launch `codex exec`/a model here.
    File.write!(bridge, """
    #!/usr/bin/env python3
    import json, os, subprocess, sys
    from pathlib import Path
    args = sys.argv[1:]
    mode = args[args.index('--sandbox') + 1]
    workspace = args[args.index('--cd') + 1]
    profiles = {'read-only': ':read-only', 'workspace-write': ':workspace'}
    result = subprocess.run(
        [#{JSON.encode!(native)}, 'sandbox', '-P', profiles[mode], '-C', workspace,
         '--', '/bin/sh', '-c', "printf 'after\\n' > proof.txt"],
        env=dict(os.environ, CODEX_HOME=#{JSON.encode!(config)}, LANG='C', LC_ALL='C'),
        capture_output=True, text=True, timeout=10)
    evidence = {'exit': result.returncode, 'stderr': result.stderr, 'stdout': result.stdout}
    Path(#{JSON.encode!(Path.join(dir, "native-result.json"))}).write_text(json.dumps(evidence))
    sys.stderr.write(result.stderr)
    print(json.dumps({'type': 'turn.completed' if result.returncode == 0 else 'turn.failed'}), flush=True)
    sys.exit(result.returncode)
    """)

    File.chmod!(bridge, 0o700)
    %{workspace: workspace, bridge: bridge}
  end

  for mode <- ["read-only", "workspace-write"] do
    test "#{mode} enforces the adapter-selected mode with a real native write", context do
      mode = unquote(mode)

      {:ok, pid} =
        Native.start(%{key: "turn-native-probe"},
          turns_dir: Path.join(context.tmp_dir, "turns"),
          agent: %{
            "command" => context.bridge,
            "workspace" => context.workspace,
            "goal" => "Perform the single bounded write",
            "sandbox" => mode
          }
        )

      on_exit(fn -> if Process.alive?(pid), do: Native.stop(pid) end)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 15_000

      result =
        context.tmp_dir |> Path.join("native-result.json") |> File.read!() |> JSON.decode!()

      bytes = File.read!(Path.join(context.workspace, "proof.txt"))

      if mode == "read-only" do
        assert reason == {:codex_failed, 0, 1}
        assert result["exit"] == 1
        assert result["stderr"] =~ "proof.txt: Operation not permitted"
        assert bytes == "before\n"
        refute_received {:agent, ^pid, {:ended, _}}
      else
        assert reason == :normal
        assert result["exit"] == 0
        assert result["stderr"] == ""
        assert bytes == "after\n"
        assert_received {:agent, ^pid, {:ended, _}}
      end

      IO.puts(
        JSON.encode!(%{
          sandbox: mode,
          native_exit: result["exit"],
          native_stderr: result["stderr"],
          file_bytes: bytes
        })
      )
    end
  end
end
