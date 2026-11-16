defmodule AtlasRuntime.ReadApiTest do
  # A controlled contract test over the synthetic native CLI; it is not real worker proof.
  use ExUnit.Case, async: false

  alias AtlasRuntime.Agent.Native
  alias AtlasRuntime.{Output, Service}
  alias AtlasRuntime.Inspection.Reads

  @moduletag capture_log: true
  # Structural and private turn fields that runtime.read/1 must never project.
  @private ~w(assignment cwd permissions sandbox artifacts repository session_id selection quota
              request_id server last_answer resume_context id)

  setup do
    # Short: socket paths must fit a Unix socket name.
    dir =
      Path.join(
        System.tmp_dir!(),
        "arr-#{Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)}"
      )

    bin = Path.join(dir, "bin")
    Enum.each([bin, Path.join(dir, "alpha"), Path.join(dir, "beta")], &File.mkdir_p!/1)
    AtlasRuntime.FakeNative.install!(Path.join(bin, "claude"), "question")
    previous = System.fetch_env!("PATH")
    System.put_env("PATH", bin <> ":" <> previous)

    on_exit(fn ->
      System.put_env("PATH", previous)
      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  defp launch(dir) do
    File.rm(Path.join(dir, "runtime.sock"))
    {:ok, pid} = GenServer.start(Service, dir)
    on_exit(fn -> halt(pid) end)
    pid
  end

  defp launch(dir, options, start \\ []) do
    File.rm(Path.join(dir, "runtime.sock"))
    {:ok, pid} = GenServer.start(Service, {dir, nil, [], options}, start)
    on_exit(fn -> halt(pid) end)
    pid
  end

  defp halt(pid) do
    if Process.alive?(pid) do
      agents =
        for {_id, worker} <- :sys.get_state(pid).workers, is_pid(worker.agent), do: worker.agent

      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
      Enum.each(agents, &Native.stop/1)
    end
  end

  defp command(pid, request) do
    {reply, false} = GenServer.call(pid, request, 10_000)
    refute Map.has_key?(reply, :command_error), inspect(reply)
    reply
  end

  defp start(pid, dir, worker, questions) do
    command(pid, %{
      "command" => "start",
      "worker_id" => worker,
      "cwd" => Path.join(dir, worker),
      "assignment" => "Synthetic read fixture",
      "backend" => "claude",
      "questions_enabled" => questions
    })
  end

  # One request line per connection on read.sock, exactly as a viewer sends it.
  defp send_line(dir, line) do
    {:ok, socket} =
      :gen_tcp.connect({:local, Path.join(dir, "read.sock")}, 0, [
        :binary,
        active: false,
        packet: :line,
        buffer: 1_048_576
      ])

    :ok = :gen_tcp.send(socket, line <> "\n")
    {:ok, reply} = :gen_tcp.recv(socket, 0, 5_000)
    :gen_tcp.close(socket)
    JSON.decode!(reply)
  end

  defp read(dir, op, fields \\ %{}),
    do: send_line(dir, JSON.encode!(Map.merge(%{"api" => "runtime.read/1", "op" => op}, fields)))

  defp await(fun, remaining \\ 500) do
    case fun.() do
      result when result in [nil, false] ->
        if remaining == 0,
          do: flunk("condition not reached"),
          else:
            (
              Process.sleep(10)
              await(fun, remaining - 1)
            )

      result ->
        result
    end
  end

  defp worker(dir, id) do
    await(fn -> Enum.find(read(dir, "workers")["workers"], &(&1["worker_id"] == id)) end)
  end

  defp public!(turn) do
    assert turn["turn_id"] =~ ~r/\Aturn-[0-9a-f]{16}\z/
    for key <- @private, do: refute(Map.has_key?(turn, key), "#{key} projected")
    turn
  end

  # Every regular file under the Runtime home, byte for byte; sockets are skipped.
  defp files(dir) do
    Path.wildcard(Path.join(dir, "**"), match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Map.new(&{&1, File.read!(&1)})
  end

  test "a standalone worker's lifecycle, output and results are readable without Server", %{
    dir: dir
  } do
    service = launch(dir)
    run = start(service, dir, "alpha", true)

    alpha =
      await(fn ->
        w = worker(dir, "alpha")
        w["turn"]["pending_question"] && w
      end)

    turn = public!(alpha["turn"])
    assert alpha["state"] == "running"

    assert %{
             "turn_id" => id,
             "worker_id" => "alpha",
             "state" => "running",
             "backend" => "claude",
             "attempt" => nil,
             "pending_question" => %{"question_id" => "question-" <> _, "revision" => revision}
           } = turn

    assert id == run.id and is_integer(revision)
    assert map_size(turn["pending_question"]) == 2
    head = read(dir, "workers")["events_cursor"]

    output =
      await(fn ->
        o = read(dir, "output", %{"turn_id" => id})
        o["events"] != [] && o
      end)

    assert %{"turn_id" => ^id, "worker_id" => "alpha", "ended" => false} = output["stream"]
    refute Map.has_key?(output["stream"], "execution")

    assert %{"kind" => "tool", "tool_name" => "AskUserQuestion", "status" => "started"} in Enum.map(
             output["events"],
             &Map.delete(&1, "sequence")
           )

    # Local output is only in the local buffer, which no Bus endpoint serves.
    {buffer, execution} = Reads.output_stream(%{"id" => id, "worker_id" => "alpha"})
    assert {:ok, _} = Output.snapshot(execution, nil, buffer)
    assert {:error, "output_unavailable"} = Output.snapshot(execution)

    accepted = read(dir, "events")["events"]
    assert Enum.any?(accepted, &(&1["kind"] == "execution_accepted" and &1["turn_id"] == id))

    for event <- accepted,
        do: refute(Map.has_key?(event, "session_id") or Map.has_key?(event, "record_ref"))

    assert %{state: "stopping"} =
             command(service, %{"command" => "stop", "worker_id" => "alpha", "turn_id" => id})

    await(fn -> read(dir, "turn", %{"turn_id" => id})["turn"]["state"] == "stopped" end)
    stopped = public!(read(dir, "turn", %{"turn_id" => id})["turn"])
    assert %{"state" => "stopped", "pending_question" => nil} = stopped
    assert is_binary(stopped["ended_at"])

    # Resuming from earlier cursors yields only what followed them.
    later = read(dir, "output", %{"turn_id" => id, "cursor" => output["cursor"]})
    assert later["stream"]["ended"] and not Map.has_key?(later, "reset")
    last = List.last(output["events"])["sequence"]
    assert Enum.all?(later["events"], &(&1["sequence"] > last))
    after_head = read(dir, "events", %{"cursor" => head})
    refute Map.has_key?(after_head, "reset")

    assert Enum.any?(
             after_head["events"],
             &(&1["kind"] == "execution_stopped" and &1["turn_id"] == id)
           )

    refute Enum.any?(after_head["events"], &(&1["kind"] == "execution_accepted"))

    finished = start(service, dir, "beta", false)
    await(fn -> worker(dir, "beta")["state"] == "finished" end)
    beta = public!(read(dir, "turn", %{"turn_id" => finished.id})["turn"])

    assert %{
             "state" => "finished",
             "result" => "done",
             "answer" => "done",
             "answer_truncated" => false
           } = beta

    beta_output = read(dir, "output", %{"turn_id" => finished.id})
    assert beta_output["stream"]["ended"]
    assert Enum.any?(beta_output["events"], &(&1["text"] == "done"))

    turns = read(dir, "turns")["turns"]
    assert Enum.sort(Enum.map(turns, & &1["turn_id"])) == Enum.sort([id, finished.id])
    Enum.each(turns, &public!/1)
  end

  test "after a service restart, cursors resume, lost state is explicit and stale read.sock is replaced",
       %{dir: dir} do
    service = launch(dir)
    run = start(service, dir, "alpha", true)

    head =
      await(fn ->
        w = worker(dir, "alpha")
        w["turn"]["pending_question"] && read(dir, "workers")["events_cursor"]
      end)

    halt(service)

    # Restart reconciliation ends the turn only once its native process is provably gone. The
    # halt ended it; the probe, asked about exactly the recorded launch, states so without
    # racing `ps` for the exit.
    process = Path.join([dir, "turns", run.id, "process.json"])
    pid = process |> File.read!() |> JSON.decode!() |> Map.fetch!("pid")
    launched = File.stat!(process, time: :posix).mtime

    probe = fn
      ^pid, ^launched -> {:gone, "halted with the previous service"}
      _, _ -> :unknown
    end

    assert File.exists?(Path.join(dir, "read.sock"))
    restarted = launch(dir, process_probe: probe)
    assert read(dir, "workers")["workers"] == []
    resumed = read(dir, "events", %{"cursor" => head})
    refute Map.has_key?(resumed, "reset")

    # Recovery invalidates the dead turn's question and reports it, once, as interrupted by
    # the restart, which no ordinary failure is; nothing before the cursor is repeated.
    assert [
             %{"kind" => "question_invalidated", "turn_id" => invalidated},
             %{
               "kind" => "execution_failed",
               "turn_id" => failed,
               "worker_id" => "alpha",
               "backend" => "claude",
               "model" => "claude-sonnet-4-6",
               "interruption" => "service_restart"
             }
           ] = resumed["events"]

    assert invalidated == run.id and failed == run.id

    assert %{"state" => "failed", "recorded_state" => "running", "error" => "interrupted: " <> _} =
             read(dir, "turn", %{"turn_id" => run.id})["turn"]

    # A second restart finds the turn terminal and reports nothing again.
    halt(restarted)
    launch(dir, process_probe: probe)
    assert read(dir, "events", %{"cursor" => head})["events"] == resumed["events"]

    # A turn whose output was never retained here, and malformed or unknown targets.
    saved = "turn-00000000000000aa"
    File.mkdir_p!(Path.join([dir, "turns", saved]))

    File.write!(
      Path.join([dir, "turns", saved, "turn.json"]),
      JSON.encode!(%{"id" => saved, "worker_id" => "gamma", "state" => "finished"})
    )

    assert read(dir, "output", %{"turn_id" => saved})["error"]["code"] == "output_unavailable"

    assert read(dir, "turn", %{"turn_id" => "turn-00000000000000bb"})["error"]["code"] ==
             "unknown_turn"

    assert read(dir, "events", %{"cursor" => "not-a-cursor"})["error"]["code"] == "invalid_cursor"
  end

  test "read.sock refuses every mutation and leaves workers and records unchanged", %{dir: dir} do
    service = launch(dir)
    run = start(service, dir, "alpha", true)
    await(fn -> worker(dir, "alpha")["turn"]["pending_question"] end)
    question = :sys.get_state(service).workers["alpha"].run.pending_question
    before = {:sys.get_state(service), files(dir)}
    api = %{"api" => "runtime.read/1"}

    commands = [
      %{
        "command" => "start",
        "worker_id" => "beta",
        "cwd" => Path.join(dir, "beta"),
        "assignment" => "x",
        "backend" => "claude"
      },
      %{"command" => "stop", "worker_id" => "alpha"},
      %{"command" => "continue", "worker_id" => "alpha", "assignment" => "x"},
      %{
        "command" => "answer",
        "worker_id" => "alpha",
        "turn_id" => run.id,
        "question_id" => question.id,
        "answers" => %{"Choose?" => "A"}
      },
      %{
        "command" => "submit-handoff",
        "worker_id" => "alpha",
        "turn_id" => run.id,
        "handoff" => %{}
      },
      %{"command" => "preferences", "preferred" => "codex", "fallback" => "claude"},
      %{"command" => "service-stop"},
      %{
        "command" => "stop",
        "worker_id" => "alpha",
        "request_id" => "00000000-0000-4000-8000-000000000001"
      }
    ]

    for request <- commands do
      assert send_line(dir, JSON.encode!(request))["error"]["code"] == "not_a_read"

      wrapped =
        Map.merge(api, request) |> Map.delete("command") |> Map.put("op", request["command"])

      assert send_line(dir, JSON.encode!(wrapped))["error"]["code"] == "not_a_read"
    end

    for op <- ~w(route-peer-question peer-question bind-peer-reply question handoff status),
        do:
          assert(
            send_line(dir, JSON.encode!(Map.put(api, "op", op)))["error"]["code"] == "not_a_read"
          )

    smuggled = Map.merge(api, %{"op" => "turn", "turn_id" => run.id, "command" => "stop"})
    assert send_line(dir, JSON.encode!(smuggled))["error"]["code"] == "invalid_request"
    assert send_line(dir, "not json")["error"]["code"] == "invalid_request"

    assert {:sys.get_state(service), files(dir)} == before
    assert worker(dir, "alpha")["state"] == "running"
  end

  test "read.sock and runtime.sock share one limit of 32 followers", %{dir: dir} do
    service = launch(dir, follow: [heartbeat: 60_000])

    follow = fn name ->
      {:ok, socket} =
        :gen_tcp.connect({:local, Path.join(dir, name)}, 0, [
          :binary,
          active: false,
          packet: :line
        ])

      :ok = :gen_tcp.send(socket, ~s({"api":"runtime.read/1","op":"follow"}\n))
      assert {:ok, line} = :gen_tcp.recv(socket, 0, 5_000)
      {socket, JSON.decode!(line)}
    end

    sockets =
      for name <- List.duplicate("read.sock", 16) ++ List.duplicate("runtime.sock", 16) do
        {socket, frame} = follow.(name)
        assert frame["type"] == "page"
        socket
      end

    for name <- ["read.sock", "runtime.sock"] do
      {refused, frame} = follow.(name)
      assert frame["error"]["code"] == "too_many_followers"
      :gen_tcp.close(refused)
    end

    Enum.each(sockets, &:gen_tcp.close/1)
    await(fn -> :sys.get_state(service).followers == %{} end)
  end
end
