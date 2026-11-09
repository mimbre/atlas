defmodule AtlasRuntime.ReadApiTest do
  # A controlled contract test over the synthetic native CLI; it is not real worker proof.
  use ExUnit.Case, async: false

  alias AtlasRuntime.Agent.Native
  alias AtlasRuntime.Execution.RestartReconciliation
  alias AtlasRuntime.{ExecutionEvents, Output, Service}
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

  # Reconciliation judges the dead turn's process from a `ps` listing.
  @tag skip: AtlasRuntime.TestHost.missing(:process_listing)
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

    # Restart reconciliation ends the turn only once its native process is provably gone.
    process = Path.join([dir, "turns", run.id, "process.json"])
    pid = process |> File.read!() |> JSON.decode!() |> Map.fetch!("pid")
    launched = File.stat!(process, time: :posix).mtime

    await(
      fn -> match?({:gone, _}, RestartReconciliation.process_state(pid, launched)) end,
      3_000
    )

    assert File.exists?(Path.join(dir, "read.sock"))
    restarted = launch(dir)
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
    launch(dir)
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

  test "events report retention gaps and replaced journals as resets, keeping CLI replies", %{
    dir: dir
  } do
    store = ExecutionEvents.open(dir)
    early = ExecutionEvents.head(store)

    run = fn n ->
      %{
        id: "turn-" <> String.pad_leading(Integer.to_string(n, 16), 16, "0"),
        worker_id: "alpha",
        backend: "codex",
        state: "running",
        started_at: "2026-11-09T10:00:00Z"
      }
    end

    store = Enum.reduce(1..260, store, &ExecutionEvents.append(dir, &2, run.(&1)))

    assert {:ok,
            %{
              "reset" => %{"reason" => "retention_gap", "from_sequence" => 1, "to_sequence" => 4},
              "events" => [%{"sequence" => 5}]
            }} = ExecutionEvents.read(store, nil, 1)

    assert {:ok,
            %{
              "reset" => %{"reason" => "retention_gap", "from_sequence" => 1, "to_sequence" => 4},
              "events" => [%{"sequence" => 5}],
              "cursor" => next
            }} = ExecutionEvents.read(store, early, 1)

    assert {:ok, %{"events" => [%{"sequence" => 6}]} = page} =
             ExecutionEvents.read(store, next, 1)

    refute Map.has_key?(page, "reset")
    other = String.duplicate("0", 32) <> ":1"

    assert {:ok, %{"reset" => %{"reason" => "epoch_changed"}}} =
             ExecutionEvents.read(store, other, 1)

    assert {:error, "invalid_cursor"} = ExecutionEvents.read(store, store["epoch"] <> ":999", 1)

    # The existing events command keeps its replies.
    assert_raise ArgumentError,
                 ~r/\Astale execution event cursor; earliest usable cursor: /,
                 fn ->
                   ExecutionEvents.query(store, early, 1)
                 end

    assert ExecutionEvents.query(store, nil, 1)["retention_gap"]
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

  describe "follow" do
    # A missed signal would only show at a heartbeat, far beyond every receive bound here.
    @quiet [heartbeat: 60_000]

    defp launch(dir, options, start \\ []) do
      File.rm(Path.join(dir, "runtime.sock"))
      {:ok, pid} = GenServer.start(Service, {dir, nil, [], options}, start)
      on_exit(fn -> halt(pid) end)
      pid
    end

    defp connect(dir, name) do
      {:ok, socket} =
        :gen_tcp.connect({:local, Path.join(dir, name)}, 0, [
          :binary,
          active: false,
          packet: :line,
          buffer: 1_048_576
        ])

      socket
    end

    defp follow(dir, fields \\ %{}) do
      socket = connect(dir, "read.sock")
      request = Map.merge(%{"api" => "runtime.read/1", "op" => "follow"}, fields)
      :ok = :gen_tcp.send(socket, JSON.encode!(request) <> "\n")
      socket
    end

    defp frame(socket, timeout \\ 5_000) do
      assert {:ok, line} = :gen_tcp.recv(socket, 0, timeout)
      assert %{"api" => "runtime.read/1"} = frame = JSON.decode!(line)
      frame
    end

    defp page(socket) do
      assert %{"op" => "follow", "type" => "page", "events" => events} = page = frame(socket)

      for event <- events,
          do: refute(Map.has_key?(event, "session_id") or Map.has_key?(event, "record_ref"))

      page
    end

    # Pages until every kind in `kinds` was seen on this connection; `{events, cursor}`.
    defp collect(socket, kinds, {events, cursor}) do
      if kinds -- Enum.map(events, & &1["kind"]) == [] do
        {events, cursor}
      else
        page = page(socket)
        collect(socket, kinds, {events ++ page["events"], page["cursor"]})
      end
    end

    defp sequences(events), do: Enum.map(events, & &1["sequence"])

    defp increasing!(events) do
      numbers = sequences(events)
      assert numbers == Enum.sort(Enum.uniq(numbers))
    end

    defp journal(dir, cursor, events \\ []) do
      page = read(dir, "events", %{"cursor" => cursor, "limit" => 100})
      events = events ++ page["events"]
      if page["more"], do: journal(dir, page["cursor"], events), else: events
    end

    defp pending!(service, worker) do
      await(fn -> :sys.get_state(service).workers[worker].run.pending_question end)
    end

    defp declaration do
      %{
        "kind" => "completion",
        "repository_url" => "https://github.com/owner/repo.git",
        "branch" => "work/task",
        "base_sha" => String.duplicate("a", 40),
        "head_sha" => String.duplicate("b", 40),
        "result" => "Declared work complete",
        "verification" => ["Not independently verified"],
        "limits" => [],
        "remaining_processes" => []
      }
    end

    defp sequence(cursor), do: cursor |> String.split(":") |> List.last() |> String.to_integer()

    defp closed!(socket), do: assert({:error, :closed} = :gen_tcp.recv(socket, 0, 5_000))

    test "every journal kind arrives live, in order, and a reconnect with the last cursor skips nothing",
         %{dir: dir} do
      for worker <- ~w(gamma delta epsilon), do: File.mkdir_p!(Path.join(dir, worker))
      service = launch(dir, follow: @quiet)
      socket = follow(dir)
      first = page(socket)
      assert %{"events" => [], "more" => false, "cursor" => head} = first
      refute Map.has_key?(first, "reset")
      assert head == read(dir, "workers")["events_cursor"]

      # A command append, then question_available from the agent message path, which stores
      # its events before the checkpoint.
      alpha = start(service, dir, "alpha", true)
      seen = collect(socket, ["execution_accepted", "question_available"], {[], head})
      question = pending!(service, "alpha")

      command(service, %{
        "command" => "answer",
        "worker_id" => "alpha",
        "turn_id" => alpha.id,
        "question_id" => question.id,
        "answers" => %{"Choose?" => "A"}
      })

      seen = collect(socket, ["answer_accepted"], seen)
      File.write!(Path.join([dir, "alpha", "process-answer"]), "")
      {before, cursor} = collect(socket, ["execution_finished"], seen)
      increasing!(before)

      # Drop the connection; what happens meanwhile is delivered on reconnect.
      :gen_tcp.close(socket)
      delta = start(service, dir, "delta", true)
      pending!(service, "delta")
      command(service, %{"command" => "kill", "worker_id" => "delta", "turn_id" => delta.id})

      await(fn ->
        Enum.any?(journal(dir, cursor), &(&1["kind"] == "execution_killed"))
      end)

      socket = follow(dir, %{"cursor" => cursor})
      resumed = page(socket)
      refute Map.has_key?(resumed, "reset")
      assert hd(sequences(resumed["events"])) == sequence(cursor) + 1

      seen =
        collect(
          socket,
          ["execution_killed", "question_invalidated"],
          {resumed["events"], resumed["cursor"]}
        )

      start(service, dir, "epsilon", true)
      pending!(service, "epsilon")
      Process.exit(:sys.get_state(service).workers["epsilon"].agent, :kill)
      seen = collect(socket, ["execution_failed"], seen)

      gamma = start(service, dir, "gamma", true)
      routed = pending!(service, "gamma")

      command(service, %{
        "command" => "route-peer-question",
        "worker_id" => "gamma",
        "turn_id" => gamma.id,
        "question_id" => routed.id,
        "peer_worker_id" => "alpha",
        "peer_source_turn_id" => alpha.id
      })

      seen = collect(socket, ["peer_question_routed"], seen)

      command(service, %{
        "command" => "submit-handoff",
        "worker_id" => "alpha",
        "turn_id" => alpha.id,
        "handoff" => declaration()
      })

      seen = collect(socket, ["handoff_submitted"], seen)
      command(service, %{"command" => "stop", "worker_id" => "gamma", "turn_id" => gamma.id})
      {after_reconnect, last} = collect(socket, ["execution_stopped"], seen)
      increasing!(after_reconnect)
      :gen_tcp.close(socket)

      # Nothing after the head was skipped; repeats are only of events after the cursor.
      recorded = journal(dir, head)
      assert List.last(recorded)["sequence"] == sequence(last)
      assert sequences(Enum.uniq(before ++ after_reconnect)) == sequences(recorded)
      assert Enum.all?(sequences(after_reconnect), &(&1 > sequence(cursor)))

      for kind <- ~w(execution_accepted execution_finished execution_failed execution_stopped
                     execution_killed question_available answer_accepted question_invalidated
                     peer_question_routed handoff_submitted),
          do: assert(Enum.any?(before ++ after_reconnect, &(&1["kind"] == kind)), kind)
    end

    test "follow reports retention gaps and replaced journals as resets, then the earliest events",
         %{dir: dir} do
      store = ExecutionEvents.open(dir)
      early = ExecutionEvents.head(store)

      store =
        Enum.reduce(1..260, store, fn n, store ->
          ExecutionEvents.append(dir, store, %{
            id: "turn-" <> String.pad_leading(Integer.to_string(n, 16), 16, "0"),
            worker_id: "alpha",
            backend: "codex",
            state: "running",
            started_at: "2026-11-09T10:00:00Z"
          })
        end)

      launch(dir, follow: @quiet)
      other = String.duplicate("0", 32) <> ":1"

      for {cursor, reset} <- [
            {early, %{"reason" => "retention_gap", "from_sequence" => 1, "to_sequence" => 4}},
            {store["epoch"] <> ":2",
             %{"reason" => "retention_gap", "from_sequence" => 3, "to_sequence" => 4}},
            {other, %{"reason" => "epoch_changed"}}
          ] do
        socket = follow(dir, %{"cursor" => cursor})
        first = page(socket)
        assert first["reset"] == reset
        assert [%{"sequence" => 5} | _] = first["events"]
        assert first["more"]
        rest = Enum.map(1..2, fn _ -> page(socket) end)
        refute Enum.any?(rest, &Map.has_key?(&1, "reset"))
        events = first["events"] ++ Enum.flat_map(rest, & &1["events"])
        assert sequences(events) == Enum.to_list(5..260)
        refute List.last(rest)["more"]
        :gen_tcp.close(socket)
      end

      for cursor <- [store["epoch"] <> ":999", "not-a-cursor"] do
        socket = follow(dir, %{"cursor" => cursor})
        assert frame(socket)["error"]["code"] == "invalid_cursor"
        closed!(socket)
      end

      for fields <- [%{"limit" => 1}, %{"cursor" => ""}, %{"turn_id" => "x"}] do
        socket = follow(dir, fields)
        assert frame(socket)["error"]["code"] == "invalid_request"
        closed!(socket)
      end
    end

    # 1,000 real appends: each persists the whole journal, so this test is IO-bound.
    @tag timeout: 600_000
    test "a stalled follower never delays commands; it is closed and removed", %{dir: dir} do
      turns =
        for n <- 1..1_000 do
          turn = "turn-" <> String.pad_leading(String.downcase(Integer.to_string(n, 16)), 16, "0")
          folder = Path.join([dir, "turns", turn])
          File.mkdir_p!(folder)

          File.write!(
            Path.join(folder, "turn.json"),
            JSON.encode!(%{
              "id" => turn,
              "worker_id" => "alpha",
              "state" => "finished",
              "backend" => "codex",
              "artifacts" => folder
            })
          )

          turn
        end

      service = launch(dir, [follow: Keyword.put(@quiet, :send, 200)], name: Service)
      # A reader that takes its first page and then nothing more.
      socket = follow(dir)
      page(socket)
      [follower] = Map.keys(:sys.get_state(service).followers)
      ref = Process.monitor(follower)

      latencies =
        for {turn, n} <- Enum.with_index(turns, 1) do
          command(service, %{
            "command" => "submit-handoff",
            "worker_id" => "alpha",
            "turn_id" => turn,
            "handoff" => declaration()
          })

          if rem(n, 50) == 0, do: status_latency(dir)
        end

      assert :sys.get_state(service).events["sequence"] == 1_000
      assert Enum.max(Enum.reject(latencies, &is_nil/1)) < 100
      assert_receive {:DOWN, ^ref, :process, ^follower, _}, 5_000
      await(fn -> :sys.get_state(service).followers == %{} end)
      assert status_latency(dir) < 100
    end

    # One service-status round trip over runtime.sock, in milliseconds.
    defp status_latency(dir) do
      status = connect(dir, "runtime.sock")
      started = System.monotonic_time(:millisecond)
      :ok = :gen_tcp.send(status, ~s({"command":"service-status"}\n))
      assert {:ok, line} = :gen_tcp.recv(status, 0, 5_000)
      elapsed = System.monotonic_time(:millisecond) - started
      assert %{"service" => "running"} = JSON.decode!(line)
      :gen_tcp.close(status)
      elapsed
    end

    test "32 followers at most; a closed follower frees its slot", %{dir: dir} do
      service = launch(dir, follow: @quiet)
      sockets = for _ <- 1..32, do: tap(follow(dir), &page/1)
      refused = follow(dir)
      assert frame(refused)["error"]["code"] == "too_many_followers"
      closed!(refused)
      assert map_size(:sys.get_state(service).followers) == 32

      :gen_tcp.close(hd(sockets))
      await(fn -> map_size(:sys.get_state(service).followers) == 31 end)
      admitted = follow(dir)
      assert %{"events" => []} = page(admitted)
      Enum.each([admitted | tl(sockets)], &:gen_tcp.close/1)
      await(fn -> :sys.get_state(service).followers == %{} end)
    end

    test "heartbeats follow a service answer; a service stop ends the stream; runtime.sock has no follow",
         %{dir: dir} do
      test = self()

      launch(dir, [follow: [heartbeat: 20], halt: &send(test, {:halted, &1})], name: Service)
      socket = follow(dir)
      assert %{"cursor" => cursor} = page(socket)

      for _ <- 1..2,
          do:
            assert(
              frame(socket) == %{
                "api" => "runtime.read/1",
                "op" => "follow",
                "type" => "heartbeat",
                "cursor" => cursor
              }
            )

      command = connect(dir, "runtime.sock")
      :ok = :gen_tcp.send(command, ~s({"api":"runtime.read/1","op":"follow"}\n))
      assert {:ok, line} = :gen_tcp.recv(command, 0, 5_000)
      assert %{"command_error" => _} = JSON.decode!(line)
      closed!(command)

      stop = connect(dir, "runtime.sock")
      :ok = :gen_tcp.send(stop, ~s({"command":"service-stop"}\n))
      assert {:ok, _} = :gen_tcp.recv(stop, 0, 5_000)
      assert_receive {:halted, 0}, 5_000

      assert Enum.find(Stream.repeatedly(fn -> frame(socket) end), &(&1["type"] == "end")) ==
               %{
                 "api" => "runtime.read/1",
                 "op" => "follow",
                 "type" => "end",
                 "reason" => "service_stopping"
               }

      closed!(socket)
    end

    # The exit after a service stop is asynchronous (and waits for Server ends first), so the
    # service still answers calls then. A follower's reconnect in that window must not get a
    # page, or it reports the stopping Runtime reachable again.
    test "once a service stop began, a new follow ends service_stopping and is not admitted",
         %{dir: dir} do
      test = self()
      service = launch(dir, [follow: @quiet, halt: &send(test, {:halted, &1})], name: Service)
      first = follow(dir)
      assert %{"cursor" => cursor} = page(first)

      stop = connect(dir, "runtime.sock")
      :ok = :gen_tcp.send(stop, ~s({"command":"service-stop"}\n))
      assert {:ok, _} = :gen_tcp.recv(stop, 0, 5_000)
      assert_receive {:halted, 0}, 5_000
      assert %{"type" => "end", "reason" => "service_stopping"} = frame(first)
      closed!(first)

      for fields <- [%{}, %{"cursor" => cursor}] do
        again = follow(dir, fields)

        assert frame(again) == %{
                 "api" => "runtime.read/1",
                 "op" => "follow",
                 "type" => "end",
                 "reason" => "service_stopping"
               }

        closed!(again)
      end

      assert :sys.get_state(service).followers == %{}
    end
  end
end
