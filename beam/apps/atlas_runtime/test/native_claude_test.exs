defmodule AtlasRuntime.NativeClaudeTest do
  use ExUnit.Case, async: true
  alias AtlasRuntime.Agent.Native
  @moduletag :tmp_dir
  @init %{
    "type" => "system",
    "subtype" => "init",
    "session_id" => "claude-session",
    "model" => "claude-sonnet-4-6"
  }
  @result %{
    "type" => "result",
    "subtype" => "success",
    "is_error" => false,
    "result" => "Read the sample."
  }
  @weekly __DIR__
          |> Path.join("fixtures/claude_weekly_quota.json")
          |> File.read!()
          |> JSON.decode!()

  defp launch(dir, events, settings \\ %{}) do
    command = Path.join(dir, "native-fixture")

    File.write!(
      command,
      "#!/bin/sh\ncat <<'EVENTS'\n" <>
        Enum.map_join(events, "\n", &JSON.encode!/1) <> "\nEVENTS\n"
    )

    File.chmod!(command, 0o700)

    Native.start(%{key: "claude-turn"},
      turns_dir: Path.join(dir, "turns"),
      agent:
        Map.merge(
          %{
            "backend" => "claude",
            "command" => command,
            "workspace" => dir,
            "goal" => "Read the sample"
          },
          settings
        )
    )
  end

  test "Claude completion requires native identity and exposes no private assistant parts", %{
    tmp_dir: dir
  } do
    assistant = %{
      "type" => "assistant",
      "message" => %{
        "model" => "claude-sonnet-4-6",
        "content" => [
          %{"type" => "thinking", "thinking" => "private reasoning"},
          %{"type" => "tool_use", "name" => "Read", "input" => %{"file_path" => "private path"}}
        ]
      }
    }

    {:ok, pid} = launch(dir, [@init, assistant, @result])
    ref = Process.monitor(pid)
    assert_receive {:agent, ^pid, {:session, "claude-session"}}, 5_000
    assert_receive {:agent, ^pid, {:identity, "claude", "claude-sonnet-4-6"}}
    assert_receive {:agent, ^pid, {:ended, "Read the sample."}}, 5_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    assert File.read!(Path.join(dir, "turns/claude-turn/answer.txt")) == "Read the sample."
    public = drain(pid) |> inspect()
    refute public =~ "private reasoning"
    refute public =~ "private path"
    assert public =~ "tool_name"
    assert File.read!(Path.join(dir, "turns/claude-turn/stream.jsonl")) =~ "private reasoning"
  end

  test "each result overwrites the answer before terminal notification, errors included", %{
    tmp_dir: dir
  } do
    answer = Path.join(dir, "turns/claude-turn/answer.txt")
    first = %{@result | "result" => "First draft."}

    {:ok, pid} = launch(dir, [@init, first, @result])
    ref = Process.monitor(pid)
    assert_receive {:agent, ^pid, {:ended, "Read the sample."}}, 5_000
    assert File.read!(answer) == "Read the sample."
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

    error = %{
      @result
      | "subtype" => "error_during_execution",
        "is_error" => true,
        "result" => "Native failure text."
    }

    {:ok, pid} = launch(dir, [@init, @result, error])
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, {:claude_failed, 0, 0}}, 5_000
    refute_received {:agent, ^pid, {:ended, _}}
    assert File.read!(answer) == "Native failure text."
  end

  test "an unsaved answer cannot complete the turn", %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, "turns/claude-turn/answer.txt"))
    {:ok, pid} = launch(dir, [@init, @result])
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, {:claude_failed, 0, 0}}, 5_000
    refute_received {:agent, ^pid, {:ended, _}}
  end

  test "zero exit cannot mask errors, missing identity or another vendor's terminal events", %{
    tmp_dir: dir
  } do
    cases = [
      [@init, Map.put(@result, "is_error", true)],
      [@result],
      [Map.delete(@init, "model"), @result],
      [@init, %{"type" => "error"}, @result],
      [
        %{"type" => "thread.started", "thread_id" => "codex-session"},
        %{"type" => "turn.completed"}
      ]
    ]

    for {events, index} <- Enum.with_index(cases) do
      folder = Path.join(dir, Integer.to_string(index))
      File.mkdir_p!(folder)
      {:ok, pid} = launch(folder, events)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, {:claude_failed, 0, 0}}, 5_000
      refute_received {:agent, ^pid, {:ended, _}}
    end
  end

  test "native identity overrides requested alias and ignores synthetic error identity", %{
    tmp_dir: dir
  } do
    init = Map.put(@init, "model", "claude-opus-5-5[1m]")

    synthetic = %{
      "type" => "assistant",
      "message" => %{"model" => "<synthetic>", "content" => []}
    }

    {:ok, pid} = launch(dir, [init, synthetic, @result], %{"model" => "opus[1m]"})
    ref = Process.monitor(pid)
    assert_receive {:agent, ^pid, {:identity, "claude", "claude-opus-5-5[1m]"}}, 5_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
    refute_received {:agent, ^pid, {:identity, _, _}}
  end

  test "observed weekly rejection emits exact quota once without retrying the turn", %{
    tmp_dir: dir
  } do
    init = Map.put(@init, "model", "claude-opus-5-5[1m]")

    synthetic = %{
      "type" => "assistant",
      "message" => %{
        "model" => "<synthetic>",
        "content" => [%{"type" => "text", "text" => "Weekly limit reached"}],
        "usage" => %{"input_tokens" => 0, "output_tokens" => 0}
      }
    }

    {:ok, pid} =
      launch(dir, [init, @weekly, synthetic, @weekly, Map.put(@result, "is_error", true)])

    ref = Process.monitor(pid)
    evidence = @weekly["rate_limit_info"]
    assert_receive {:agent, ^pid, {:quota, ^evidence}}, 5_000
    assert_receive {:DOWN, ^ref, :process, ^pid, {:claude_failed, 0, 0}}, 5_000
    refute_received {:agent, ^pid, {:quota, _}}
    refute_received {:agent, ^pid, {:identity, "claude", "<synthetic>"}}
    refute_received {:agent, ^pid, {:ended, _}}
  end

  test "generic, auth, network and other rate limits are not weekly quota", %{tmp_dir: dir} do
    info = @weekly["rate_limit_info"]

    events = [
      %{"type" => "error", "message" => "weekly quota exceeded"},
      %{"type" => "error", "error" => %{"type" => "authentication_error"}},
      %{"type" => "error", "message" => "Network timeout"},
      %{"type" => "rate_limit_event", "rate_limit_info" => Map.put(info, "status", "allowed")},
      %{"type" => "rate_limit_event", "rate_limit_info" => Map.put(info, "isUsingOverage", true)},
      %{
        "type" => "rate_limit_event",
        "rate_limit_info" => Map.put(info, "overageStatus", "allowed")
      },
      %{
        "type" => "rate_limit_event",
        "rate_limit_info" => Map.put(info, "rateLimitType", "five_hour")
      },
      %{"type" => "rate_limit_event", "rate_limit_info" => %{"status" => "rejected"}},
      %{"type" => "rate_limit_event", "rate_limit_info" => nil}
    ]

    {:ok, pid} = launch(dir, [@init | events] ++ [Map.put(@result, "is_error", true)])
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, {:claude_failed, 0, 0}}, 5_000
    refute_received {:agent, ^pid, {:quota, _}}
  end

  test "weekly quota never parses localized reset text", %{tmp_dir: dir} do
    for {reset, index} <- Enum.with_index([nil, "November 7 at 6pm", "1794052800", -1, true]) do
      folder = Path.join(dir, Integer.to_string(index))
      File.mkdir_p!(folder)
      event = put_in(@weekly, ["rate_limit_info", "resetsAt"], reset)
      {:ok, pid} = launch(folder, [@init, event, Map.put(@result, "is_error", true)])
      ref = Process.monitor(pid)
      assert_receive {:agent, ^pid, {:quota, %{"resetsAt" => nil}}}, 5_000
      assert_receive {:DOWN, ^ref, :process, ^pid, {:claude_failed, 0, 0}}, 5_000
    end
  end

  test "Claude resume requires the exact native session and model", %{tmp_dir: dir} do
    session = "a1a1b578-c3b5-7972-9664-1d250bf64cdf"
    init = Map.put(@init, "session_id", session)
    {:ok, first} = launch(dir, [init, @result])
    first_ref = Process.monitor(first)
    assert_receive {:DOWN, ^first_ref, :process, ^first, :normal}, 5_000

    context =
      Path.join(dir, "turns/claude-turn/claude-context.json") |> File.read!() |> JSON.decode!()

    settings = %{"session_id" => session, "model" => @init["model"], "resume_context" => context}

    {:ok, resumed} = launch(dir, [init, @result], settings)
    resumed_ref = Process.monitor(resumed)
    assert_receive {:agent, ^resumed, {:session, ^session}}, 5_000
    assert_receive {:DOWN, ^resumed_ref, :process, ^resumed, :normal}, 5_000

    for events <- [
          [Map.put(init, "session_id", "different-session"), @result],
          [Map.put(init, "model", "different-model"), @result],
          [@result],
          [%{"type" => "error", "error" => "Session not found"}]
        ] do
      {:ok, failed} = launch(dir, events, settings)
      failed_ref = Process.monitor(failed)
      assert_receive {:DOWN, ^failed_ref, :process, ^failed, {:claude_failed, 1, _}}, 5_000
      refute_receive {:agent, ^failed, {:ended, _}}
    end
  end

  test "assistant base model preserves the native context modifier for continuation", %{
    tmp_dir: dir
  } do
    session = "a1a1b578-c3b5-7972-9664-1d250bf64cdf"
    model = "claude-opus-5-5[1m]"
    init = Map.merge(@init, %{"session_id" => session, "model" => model})

    assistant = %{
      "type" => "assistant",
      "session_id" => session,
      "message" => %{"model" => "claude-opus-5-5", "content" => []}
    }

    {:ok, first} = launch(dir, [init, assistant, @result])
    first_ref = Process.monitor(first)
    assert_receive {:agent, ^first, {:identity, "claude", ^model}}, 5_000
    assert_receive {:DOWN, ^first_ref, :process, ^first, :normal}, 5_000
    refute_received {:agent, ^first, {:identity, "claude", "claude-opus-5-5"}}

    context =
      Path.join(dir, "turns/claude-turn/claude-context.json") |> File.read!() |> JSON.decode!()

    settings = %{"session_id" => session, "model" => model, "resume_context" => context}
    {:ok, resumed} = launch(dir, [init, assistant, @result], settings)
    resumed_ref = Process.monitor(resumed)
    assert_receive {:DOWN, ^resumed_ref, :process, ^resumed, :normal}, 5_000
    assert_receive {:agent, ^resumed, {:identity, "claude", ^model}}
    refute_received {:agent, ^resumed, {:identity, "claude", "claude-opus-5-5"}}

    for events <- [
          [Map.put(init, "model", "claude-opus-5-5"), assistant, @result],
          [init, put_in(assistant, ["message", "model"], "claude-sonnet-5-5"), @result]
        ] do
      {:ok, failed} = launch(dir, events, settings)
      failed_ref = Process.monitor(failed)
      assert_receive {:DOWN, ^failed_ref, :process, ^failed, {:claude_failed, 1, _}}, 5_000
      refute_received {:agent, ^failed, {:ended, _}}
    end
  end

  test "unsupported permissions, unscoped provisioning, resume and unknown vendors never launch",
       %{
         tmp_dir: dir
       } do
    for settings <- [
          %{"sandbox" => "workspace-write"},
          %{"sandbox" => nil, "permissions" => %{"root" => dir}},
          %{"repository" => %{"url" => "https://github.com/eyra/atlas.git"}},
          %{"session_id" => "existing-session"},
          %{"backend" => "unknown"},
          %{"backend" => "codex", "questions_enabled" => true},
          %{"questions_enabled" => "true"},
          %{"questions_enabled" => nil},
          %{"model" => ""},
          %{"model" => "--dangerously-skip-permissions"},
          %{"model" => "opus\n--tools Bash"},
          %{"model" => ["opus"]},
          %{"model" => String.duplicate("x", 201)}
        ] do
      base = %{
        "backend" => "claude",
        "command" => System.find_executable("sh"),
        "workspace" => dir,
        "goal" => "Never execute"
      }

      assert {:error, _} =
               Native.start(%{key: "refused"},
                 turns_dir: Path.join(dir, "turns"),
                 agent: Map.merge(base, settings)
               )

      refute File.exists?(Path.join(dir, "turns"))
    end
  end

  test "workspace launch validation permits only existing or scoped provisioned workspaces", %{
    tmp_dir: dir
  } do
    alias AtlasRuntime.Workspaces
    missing = Path.join(dir, "not-provisioned")
    scope = %{"profile" => "dedicated-repository", "root" => missing}
    repository = %{"url" => "https://github.com/eyra/atlas.git"}

    assert Workspaces.valid_request?(dir, "read-only", nil, nil)
    assert Workspaces.valid_request?(dir, "workspace-write", nil, nil)
    assert Workspaces.valid_request?(missing, nil, scope, repository)
    refute Workspaces.valid_request?(missing, "read-only", nil, nil)
    refute Workspaces.valid_request?(missing, nil, nil, repository)
    refute Workspaces.valid_request?(dir, "read-only", scope, nil)
    refute Workspaces.valid_request?(dir, nil, nil, nil)
    refute Workspaces.valid_request?(nil, nil, scope, repository)
  end

  defp drain(pid) do
    receive do
      {:agent, ^pid, event} -> [event | drain(pid)]
    after
      0 -> []
    end
  end
end
