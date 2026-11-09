defmodule AtlasRuntime.CodexTest do
  use ExUnit.Case, async: true
  alias AtlasRuntime.Agent.Native
  @moduletag :tmp_dir
  @turn %{key: "TU-CODEX-1", item: "work", agent: "worker"}

  # Monitored as it starts: a fake that exits at once can be gone before a later
  # Process.monitor/1, whose DOWN then says :noproc instead of why it ended.
  defp launch(dir, script, owner \\ nil, settings \\ %{}) do
    command = Path.join(dir, "fake-codex")
    File.write!(command, "#!/bin/sh\n" <> script)
    File.chmod!(command, 0o700)

    opts = [
      turns_dir: Path.join(dir, "turns"),
      agent:
        Map.merge(
          %{"command" => command, "workspace" => dir, "goal" => "Explain the sample"},
          settings
        )
    ]

    if owner, do: send(owner, {:launch, opts}), else: Native.start_monitor(@turn, opts)
  end

  test "clean exit and completed event preserve the real final answer", %{tmp_dir: dir} do
    {:ok, {pid, ref}} =
      launch(dir, ~S"""
      printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"The sample totals prices and applies tax."}}'
      printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":1}}'
      """)

    assert_receive {:agent, ^pid, {:ended, "The sample totals prices and applies tax."}}, 5_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
  end

  test "requested Codex model and Claude quota-shaped events cannot fabricate evidence", %{
    tmp_dir: dir
  } do
    {:ok, {pid, ref}} =
      launch(
        dir,
        ~S"""
        printf '%s\n' '{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","rateLimitType":"seven_day","resetsAt":1794052800}}'
        printf '%s\n' '{"type":"turn.completed"}'
        """,
        nil,
        %{"model" => "requested-model"}
      )

    assert_receive {:agent, ^pid, {:ended, _}}, 5_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
    refute_received {:agent, ^pid, {:identity, _, _}}
    refute_received {:agent, ^pid, {:quota, _}}
  end

  test "normal completion terminates descendants with redirected output", %{tmp_dir: dir} do
    {:ok, {pid, _}} =
      launch(dir, ~S"""
      sleep 60 </dev/null >/dev/null 2>&1 &
      printf '{"type":"item.started","item":{"text":"child=%s"}}\n' "$!"
      printf '%s\n' '{"type":"turn.completed"}'
      """)

    assert_receive {:agent, ^pid, {:activity, "codex: item started"}}, 5_000
    child = native_child(dir)
    on_exit(fn -> System.cmd("kill", ["-KILL", child], stderr_to_stdout: true) end)
    assert_receive {:agent, ^pid, {:ended, _}}, 5_000
    assert_dead(child)
  end

  test "zero exit without completion is not success", %{tmp_dir: dir} do
    {:ok, {pid, ref}} = launch(dir, "exit 0\n")
    assert_receive {:DOWN, ^ref, :process, ^pid, {:codex_failed, 0, 0}}, 5_000
    refute_received {:agent, ^pid, {:ended, _}}
  end

  test "a failure event or nonzero exit cannot be reported as completion", %{tmp_dir: dir} do
    for {suffix, script, code} <- [
          {"failed",
           ~S"""
           printf '%s\n' '{"type":"turn.failed","error":{"message":"Login expired"}}' '{"type":"turn.completed"}'
           """, 0},
          {"exit", "printf '%s\\n' '{\"type\":\"turn.completed\"}'\nexit 7\n", 7}
        ] do
      path = Path.join(dir, suffix)
      File.mkdir_p!(path)
      {:ok, {pid, ref}} = launch(path, script)
      assert_receive {:DOWN, ^ref, :process, ^pid, {:codex_failed, 0, ^code}}, 5_000
      refute_received {:agent, ^pid, {:ended, _}}
    end
  end

  test "recorded clean exits whose tool calls all failed at dispatch are not completion", %{
    tmp_dir: dir
  } do
    fixtures = Path.join(__DIR__, "fixtures/codex_0_167_1")

    for {name, error} <- [
          {"host-timeout", "timed out negotiating with the code-mode host"},
          {"missing-host",
           "failed to spawn code-mode host /tmp/cxfix/bin/codex-code-mode-host: " <>
             "No such file or directory (os error 2)"}
        ] do
      path = Path.join(dir, name)
      File.mkdir_p!(path)
      recording = Path.join(fixtures, name)

      {:ok, {pid, ref}} =
        launch(path, "cat '#{recording}.stderr.log' >&2\ncat '#{recording}.stdout.jsonl'\n")

      reason = "every tool call failed before execution: " <> error
      assert_receive {:DOWN, ^ref, :process, ^pid, {:codex_failed, ^reason}}, 5_000
      refute_received {:agent, ^pid, {:ended, _}}
    end
  end

  test "a recorded error item without a router error leaves the turn finished", %{tmp_dir: dir} do
    recording = Path.join(__DIR__, "fixtures/codex_0_167_1/missing-host.stdout.jsonl")
    {:ok, {pid, ref}} = launch(dir, "cat '#{recording}'\n")
    assert_receive {:agent, ^pid, {:ended, _}}, 5_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
  end

  test "stop waits for the child process group to terminate", %{tmp_dir: dir} do
    {:ok, {pid, _}} =
      launch(dir, ~S"""
      sleep 60 &
      child=$!
      printf '{"type":"item.started","item":{"text":"child=%s"}}\n' "$child"
      wait
      """)

    assert_receive {:agent, ^pid, {:activity, "codex: item started"}}, 5_000
    child = native_child(dir)
    assert :ok = Native.stop(pid)
    refute Process.alive?(pid)
    assert_dead(String.trim(child))
    refute_received {:agent, ^pid, {:ended, _}}
  end

  test "losing the turn owner stops the worker too", %{tmp_dir: dir} do
    parent = self()

    owner =
      spawn(fn ->
        receive do
          {:launch, opts} ->
            {:ok, adapter} = Native.start(@turn, opts)
            send(parent, {:adapter, adapter})

            receive do
              {:agent, ^adapter, {:activity, activity}} -> send(parent, {:activity, activity})
            end

            receive do
              :done -> :ok
            end
        end
      end)

    launch(
      dir,
      ~S"""
      printf '{"type":"item.started","item":{"text":"child=%s"}}\n' "$$"
      sleep 60
      """,
      owner
    )

    assert_receive {:adapter, adapter}, 5_000
    ref = Process.monitor(adapter)
    assert_receive {:activity, "codex: item started"}, 5_000
    child = native_child(dir)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^adapter, :normal}, 8_000
    assert_dead(String.trim(child))
  end

  test "an unsupported sandbox is refused before launching a process", %{tmp_dir: dir} do
    opts = [
      turns_dir: Path.join(dir, "turns"),
      agent: %{
        "command" => System.find_executable("sh"),
        "workspace" => dir,
        "goal" => "Do not execute",
        "sandbox" => "danger-full-access"
      }
    ]

    assert {:error, _} = Native.start(@turn, opts)
    refute File.exists?(Path.join(dir, "turns"))
  end

  test "resume refuses a different native session instead of completing a replacement", %{
    tmp_dir: dir
  } do
    {:ok, {pid, ref}} =
      launch(
        dir,
        ~S"""
        printf '%s\n' '{"type":"thread.started","thread_id":"different-session"}'
        printf '%s\n' '{"type":"turn.completed"}'
        """,
        nil,
        %{"session_id" => "expected-session"}
      )

    assert_receive {:DOWN, ^ref, :process, ^pid, {:codex_failed, 1, nil}}, 5_000
    refute_received {:agent, ^pid, {:session, _}}
    refute_received {:agent, ^pid, {:ended, _}}
  end

  test "resume cannot report success without native session confirmation", %{tmp_dir: dir} do
    {:ok, {pid, ref}} =
      launch(
        dir,
        ~S"""
        printf '%s\n' '{"type":"turn.completed"}'
        """,
        nil,
        %{"session_id" => "expected-session"}
      )

    assert_receive {:DOWN, ^ref, :process, ^pid, {:codex_failed, 1, nil}}, 5_000
    refute_received {:agent, ^pid, {:ended, _}}
  end

  test "only public assistant text and safe tool metadata leave the native stream", %{
    tmp_dir: dir
  } do
    {:ok, {pid, _}} =
      launch(dir, ~S"""
      printf '%s\n' '{"type":"item.completed","item":{"type":"reasoning","text":"PRIVATE_REASONING"}}'
      printf '%s\n' '{"type":"item.started","item":{"type":"command_execution","command":"PRIVATE_COMMAND","text":"PRIVATE_INPUT","status":"in_progress"}}'
      printf '%s\n' '{"type":"item.completed","item":{"type":"command_execution","aggregated_output":"PRIVATE_RESULT","status":"completed"}}'
      printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"Public answer"}}'
      printf '%s\n' '{"type":"turn.completed"}'
      """)

    assert_receive {:agent, ^pid, {:ended, "Public answer"}}, 5_000
    messages = drain(pid)

    assert {:output, %{"kind" => "text", "text" => "Public answer"}} in messages

    assert {:output,
            %{"kind" => "tool", "tool_name" => "command_execution", "status" => "started"}} in messages

    assert {:output,
            %{"kind" => "tool", "tool_name" => "command_execution", "status" => "completed"}} in messages

    refute inspect(messages) =~ "PRIVATE_"
    assert File.read!(Path.join([dir, "turns", @turn.key, "stream.jsonl"])) =~ "PRIVATE_REASONING"
  end

  defp drain(pid) do
    receive do
      {:agent, ^pid, message} -> [message | drain(pid)]
    after
      0 -> []
    end
  end

  # Process cleanup probes use the private native artifact, not public activity.
  defp native_child(dir) do
    dir
    |> Path.join("turns/#{@turn.key}/stream.jsonl")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> hd()
    |> JSON.decode!()
    |> get_in(["item", "text"])
    |> String.replace_prefix("child=", "")
    |> String.trim()
  end

  defp assert_dead(pid) do
    {state, _} = System.cmd("ps", ["-p", pid, "-o", "stat="], stderr_to_stdout: true)
    assert String.trim(state) == "" or String.starts_with?(String.trim(state), "Z")
  end
end
