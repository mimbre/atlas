defmodule AtlasRuntime.CodexModelTest do
  # The adapter cases change CODEX_HOME/HOME, which the native child inherits.
  use ExUnit.Case, async: false

  alias AtlasRuntime.Agent.Native
  alias AtlasRuntime.Providers.Codex

  @moduletag :tmp_dir
  @session "01a1b578-c3b5-7972-9664-1d250bf64cdf"
  @started ~U[2026-11-07 10:05:54.000000Z]

  defp rollout(home, records, opts \\ []) do
    session = Keyword.get(opts, :session, @session)
    name = Keyword.get(opts, :name, "rollout-2026-11-07T11-05-53-#{@session}.jsonl")
    path = Path.join([home, "sessions/2026/11/07", name])
    File.mkdir_p!(Path.dirname(path))
    meta = %{"type" => "session_meta", "payload" => %{"id" => session}}
    File.write!(path, Enum.map_join([meta | records], &(JSON.encode!(&1) <> "\n")))
    path
  end

  defp context(timestamp, cwd, model),
    do: %{
      "type" => "turn_context",
      "timestamp" => timestamp,
      "payload" => %{"cwd" => cwd, "model" => model}
    }

  defp model(home, workspace, session \\ @session),
    do: Codex.model(session, workspace, home, @started)

  test "only this invocation's turn context in the launch workspace is evidence", %{tmp_dir: dir} do
    # Shape and model from native Codex 0.166.0 rollout, with fixture-only cwd.
    rollout(dir, [context("2026-11-07T10:05:55.213Z", dir, "gpt-6.1-sol")])
    assert model(dir, dir) == "gpt-6.1-sol"

    rollout(dir, [
      context("2026-11-07T10:05:53.848Z", dir, "old-model"),
      context("2026-11-07T10:05:55.213Z", "/other", "foreign-model")
    ])

    assert model(dir, dir) == nil

    rollout(dir, [
      context("2026-11-07T10:05:53.848Z", dir, "old-model"),
      context("2026-11-07T10:05:54Z", dir, "boundary"),
      context("2026-11-07T11:05:55+01:00", dir, "offset-current"),
      %{"type" => "event_msg", "payload" => "not a context"}
    ])

    assert model(dir, dir) == "offset-current"
  end

  test "missing, foreign, naive, synthetic and malformed evidence stays unknown", %{tmp_dir: dir} do
    assert model(dir, dir) == nil
    assert model(dir, dir, "../../*") == nil

    rollout(dir, [context("2026-11-07T10:05:55Z", dir, "model")], session: "different-session")
    assert model(dir, dir) == nil

    for {timestamp, value} <- [
          {"2026-11-07T10:05:55", "model"},
          {"2026-11-07", "model"},
          {"2026-11-07T10:05:55Z", nil},
          {"2026-11-07T10:05:55Z", ""},
          {"2026-11-07T10:05:55Z", "<synthetic>"}
        ] do
      rollout(dir, [context(timestamp, dir, value)])
      assert model(dir, dir) == nil, inspect({timestamp, value})
    end

    # Unreadable evidence makes the whole lookup unknown, even after a valid record.
    for bad <- [
          ~s({"type":"turn_context","timestamp":"bad-date","payload":{}}),
          ~s({"type":"turn_context","timestamp":7,"payload":{}}),
          ~s({"type":"turn_context","timestamp":"2026-11-07T10:05:56Z","payload":"x"}),
          "[]",
          "{truncated",
          ""
        ] do
      path = rollout(dir, [context("2026-11-07T10:05:55Z", dir, "valid")])
      File.write!(path, File.read!(path) <> bad <> "\nmore\n")
      assert model(dir, dir) == nil, bad
    end

    File.write!(rollout(dir, []), "")
    assert model(dir, dir) == nil
  end

  test "rollouts outside the session file pattern are not evidence", %{tmp_dir: dir} do
    for name <- [
          "rollout-#{@session}.jsonl",
          "other-x-#{@session}.jsonl",
          "rollout-x-#{@session}.json"
        ] do
      File.rm_rf!(Path.join(dir, "sessions"))
      rollout(dir, [context("2026-11-07T10:05:55Z", dir, "model")], name: name)
      assert model(dir, dir) == nil, name
    end
  end

  defp launch(dir, script, settings) do
    command = Path.join(dir, "fake-codex")
    File.write!(command, "#!/bin/sh\n" <> script)
    File.chmod!(command, 0o700)
    workspace = Path.join(dir, "workspace")
    File.mkdir_p!(workspace)

    agent =
      Map.merge(%{"command" => command, "workspace" => workspace, "goal" => "Explain"}, settings)

    Native.start(%{key: "TU-CODEX-MODEL", item: "work", agent: "worker"},
      turns_dir: Path.join(dir, "turns"),
      agent: agent
    )
  end

  # The child writes stale and current turn contexts where its own environment points.
  # The current context is stamped a minute after the script is written, so after launch.
  defp native_evidence(home_expression, workspace) do
    stamp = DateTime.utc_now() |> DateTime.add(60) |> DateTime.to_iso8601()

    records =
      Enum.map_join(
        [
          %{"type" => "session_meta", "payload" => %{"id" => @session}},
          %{"type" => "turn_context", "timestamp" => "2020-01-01T00:00:00Z",
            "payload" => %{"cwd" => workspace, "model" => "stale-model"}},
          %{"type" => "turn_context", "timestamp" => stamp,
            "payload" => %{"cwd" => workspace, "model" => "native-confirmed"}}
        ],
        &(JSON.encode!(&1) <> "\n")
      )

    """
    sessions="#{home_expression}/sessions/2026/11/08"
    mkdir -p "$sessions"
    cat > "$sessions/rollout-2026-11-08T10-00-00-#{@session}.jsonl" <<'EOF'
    #{records}EOF
    printf '%s\\n' '{"type":"thread.started","thread_id":"#{@session}"}'
    """
  end

  defp with_env(values, fun) do
    previous = Map.new(values, fn {key, _} -> {key, System.get_env(key)} end)

    Enum.each(values, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)

    try do
      fun.()
    after
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end
  end

  defp messages(pid, acc \\ []) do
    receive do
      {:agent, ^pid, message} -> messages(pid, [message | acc])
      {:DOWN, _, :process, ^pid, reason} -> {Enum.reverse(acc), reason}
    after
      10_000 -> flunk("native execution did not end")
    end
  end

  test "identity from the child CODEX_HOME precedes completion; requested model is not evidence",
       %{tmp_dir: dir} do
    home = Path.join(dir, "codex-home")
    workspace = Path.join(dir, "workspace")

    with_env([{"CODEX_HOME", home}], fn ->
      {:ok, pid} =
        launch(
          dir,
          native_evidence("$CODEX_HOME", workspace) <>
            ~S"""
            printf '%s\n' '{"type":"turn.completed"}'
            """,
          %{"session_id" => @session, "model" => "requested-model"}
        )

      Process.monitor(pid)
      {received, :normal} = messages(pid)
      identity = Enum.find_index(received, &(&1 == {:identity, "codex", "native-confirmed"}))
      ended = Enum.find_index(received, &match?({:ended, _}, &1))
      assert identity && ended && identity < ended
      refute Enum.any?(received, &match?({:identity, _, "requested-model"}, &1))
    end)
  end

  test "without CODEX_HOME the child HOME locates evidence, even for a failed exit", %{
    tmp_dir: dir
  } do
    home = Path.join(dir, "home")
    workspace = Path.join(dir, "workspace")

    with_env([{"CODEX_HOME", nil}, {"HOME", home}], fn ->
      {:ok, pid} =
        launch(
          dir,
          native_evidence("$HOME/.codex", workspace) <> "exit 3\n",
          %{}
        )

      Process.monitor(pid)
      {received, reason} = messages(pid)
      assert {:identity, "codex", "native-confirmed"} in received
      assert reason == {:codex_failed, 0, 3}
    end)
  end

  test "a stopped execution never acquires identity", %{tmp_dir: dir} do
    home = Path.join(dir, "codex-home")
    workspace = Path.join(dir, "workspace")
    ready = Path.join(dir, "ready")

    with_env([{"CODEX_HOME", home}], fn ->
      {:ok, pid} =
        launch(
          dir,
          native_evidence("$CODEX_HOME", workspace) <> "touch #{ready}\nsleep 60\n",
          %{}
        )

      Process.monitor(pid)

      wait = fn wait ->
        if File.exists?(ready),
          do: :ok,
          else:
            (
              Process.sleep(20)
              wait.(wait)
            )
      end

      wait.(wait)
      assert_receive {:agent, ^pid, {:session, @session}}, 5_000
      assert :ok = Native.stop(pid)
      {received, _} = messages(pid)
      refute Enum.any?(received, &match?({:identity, _, _}, &1))
    end)
  end
end
