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
    {version, 0} = System.cmd(native, ["--version"])
    IO.puts("Native sandbox verification: #{String.trim(version)}")
    workspace = Path.join(dir, "workspace") |> Path.expand()
    config = Path.join(dir, "codex-home") |> Path.expand()
    File.mkdir_p!(workspace)
    File.mkdir_p!(config)
    File.write!(Path.join(workspace, "proof.txt"), "before\n")
    bridge = Path.join(dir, "sandbox-probe") |> Path.expand()
    shell = &("'" <> String.replace(&1, "'", "'\\''") <> "'")
    evidence = Path.join(dir, "native") |> Path.expand()

    # `sandbox` requires permission profiles in Codex 0.166.0. Built-ins are
    # :read-only and :workspace, documented at developers.openai.com/codex/permissions.
    # Do not read the user's Codex home or launch `codex exec`/a model here.
    File.write!(bridge, """
    #!/bin/sh
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --sandbox) mode=$2 ;;
        --cd) workspace=$2 ;;
      esac
      shift
    done
    case "$mode" in
      read-only) profile=:read-only ;;
      workspace-write) profile=:workspace ;;
      *) exit 2 ;;
    esac
    CODEX_HOME=#{shell.(config)} LANG=C LC_ALL=C #{shell.(native)} sandbox -P "$profile" -C "$workspace" \\
      -- /bin/sh -c "printf 'after\\\\n' > proof.txt" >#{shell.(evidence <> "-stdout")} 2>#{shell.(evidence <> "-stderr")}
    code=$?
    printf '%s' "$code" >#{shell.(evidence <> "-exit")}
    cat #{shell.(evidence <> "-stderr")} >&2
    if [ "$code" -eq 0 ]; then
      printf '%s\\n' '{"type":"turn.completed"}'
    else
      printf '%s\\n' '{"type":"turn.failed"}'
    fi
    exit "$code"
    """)

    File.chmod!(bridge, 0o700)
    %{workspace: workspace, bridge: bridge, evidence: evidence}
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

      result = %{
        "exit" => String.to_integer(File.read!(context.evidence <> "-exit")),
        "stderr" => File.read!(context.evidence <> "-stderr")
      }

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
