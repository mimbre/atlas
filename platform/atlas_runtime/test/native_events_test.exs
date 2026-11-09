defmodule AtlasRuntime.NativeEventsTest do
  use ExUnit.Case, async: true
  alias AtlasRuntime.Providers.NativeEvents
  @moduletag :tmp_dir

  # Recorded from codex exec --json 0.167.1: stdout and stderr of one invocation each.
  @fixtures Path.join(__DIR__, "fixtures/codex_0_167_1")

  @timeout "every tool call failed before execution: timed out negotiating with the code-mode host"
  @missing "every tool call failed before execution: failed to spawn code-mode host " <>
             "/tmp/cxfix/bin/codex-code-mode-host: No such file or directory (os error 2)"

  @router_line "2026-11-11T13:19:30.017295Z ERROR codex_core::tools::router: error=timed out negotiating with the code-mode host\n"
  @answer ~s({"type":"item.completed","item":{"id":"m","type":"agent_message","text":"Found no problems."}})
  @done ~s({"type":"turn.completed","usage":{"input_tokens":1}})

  # Consumes stdout records as the native host forwards them, then the clean process end
  # with stderr as the host left it in the turn folder.
  defp run(dir, stdout, stderr) do
    File.write!(Path.join(dir, "stderr.log"), stderr)

    state = %{
      owner: self(),
      backend: "codex",
      folder: dir,
      session: nil,
      launch: nil,
      completed: false,
      failed: false,
      tool_seen: false,
      router_error: nil,
      result: nil
    }

    state =
      stdout
      |> String.split("\n", trim: true)
      |> Enum.map(&%{"type" => "runtime.event", "event" => JSON.decode!(&1)})
      |> Enum.reduce(state, &NativeEvents.consume/2)

    NativeEvents.ended(%{"type" => "runtime.process_ended", "stopped" => false}, state)
  end

  defp fixture(name), do: File.read!(Path.join(@fixtures, name))

  test "an unanswering code-mode host fails the turn from stderr router errors", %{tmp_dir: dir} do
    state =
      run(dir, fixture("host-timeout.stdout.jsonl"), fixture("host-timeout.stderr.log"))

    assert state.completed and not state.failed
    assert NativeEvents.dispatch_failure(state) == @timeout
  end

  test "a missing code-mode host fails the turn citing the router error", %{tmp_dir: dir} do
    state =
      run(dir, fixture("missing-host.stdout.jsonl"), fixture("missing-host.stderr.log"))

    assert state.completed and not state.failed
    assert NativeEvents.dispatch_failure(state) == @missing
  end

  test "router errors beside an executed tool call leave the turn unchanged", %{tmp_dir: dir} do
    for executed <- [
          ~s({"type":"item.completed","item":{"id":"c","type":"command_execution","aggregated_output":"ok","exit_code":0,"status":"completed"}}),
          ~s({"type":"item.completed","item":{"id":"c","type":"command_execution","aggregated_output":"FAIL","exit_code":1,"status":"failed"}}),
          ~s({"type":"item.started","item":{"id":"c","type":"mcp_tool_call","server":"s","tool":"read","status":"in_progress"}})
        ] do
      state = run(dir, Enum.join([executed, @answer, @done], "\n"), @router_line)
      assert state.completed and not state.failed
      assert NativeEvents.dispatch_failure(state) == nil, executed
    end
  end

  test "other stderr output is not a dispatch error", %{tmp_dir: dir} do
    stderr = """
    Reading additional input from stdin...
    2026-11-11T13:19:30.017295Z ERROR codex_core::other: error=timed out negotiating with the code-mode host
    2026-11-11T13:19:30.017295Z  WARN codex_core::tools::router: error=slow
    timed out negotiating with the code-mode host
    """

    assert NativeEvents.dispatch_failure(run(dir, Enum.join([@answer, @done], "\n"), stderr)) ==
             nil
  end

  test "a turn without tool calls, whatever its answer, is unchanged", %{tmp_dir: dir} do
    state =
      run(dir, Enum.join([@answer, @done], "\n"), "Reading additional input from stdin...\n")

    assert state.completed and state.result == "Found no problems."
    assert NativeEvents.dispatch_failure(state) == nil
  end

  test "a normal turn with executed tool calls is unchanged", %{tmp_dir: dir} do
    state =
      run(
        dir,
        """
        {"type":"item.started","item":{"id":"c1","type":"command_execution","command":"cat a.txt","status":"in_progress"}}
        {"type":"item.completed","item":{"id":"c1","type":"command_execution","aggregated_output":"text","exit_code":0,"status":"completed"}}
        {"type":"item.completed","item":{"id":"f1","type":"file_change","changes":[],"status":"completed"}}
        #{@answer}
        #{@done}
        """,
        ""
      )

    assert state.completed and not state.failed
    assert NativeEvents.dispatch_failure(state) == nil
  end

  test "a missing stderr log reports no router error", %{tmp_dir: dir} do
    assert NativeEvents.router_error(Path.join(dir, "absent.log")) == nil
  end
end
