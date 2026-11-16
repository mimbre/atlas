defmodule AtlasRuntime.SocketJournalTest do
  # The journal on runtime.sock (design 2026-11-16-runtime-backend §13.1 Q3): `events` and
  # `follow` with the runtime.read/1 protocol, as read.sock serves them until S2 removes it.
  # A controlled contract test over the synthetic native CLI; it is not real worker proof.
  use ExUnit.Case, async: false

  alias AtlasRuntime.Agent.Native
  alias AtlasRuntime.{ExecutionEvents, Service}

  @moduletag capture_log: true
  # A missed signal would only show at a heartbeat, far beyond every receive bound here.
  @quiet [heartbeat: 60_000]
  @page ~w(api cursor events more op recording_started_at)

  setup do
    # Short: socket paths must fit a Unix socket name.
    dir =
      Path.join(
        System.tmp_dir!(),
        "arj-#{Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)}"
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

  defp launch(dir, options \\ [follow: @quiet], start \\ []) do
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
      "assignment" => "Synthetic journal fixture",
      "backend" => "claude",
      "questions_enabled" => questions
    })
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

  # One request line on the named socket; the first reply line as sent, newline included.
  defp raw(dir, name, line) do
    socket = connect(dir, name)
    :ok = :gen_tcp.send(socket, line <> "\n")
    {:ok, reply} = :gen_tcp.recv(socket, 0, 5_000)
    :gen_tcp.close(socket)
    reply
  end

  defp send_line(dir, line), do: JSON.decode!(raw(dir, "runtime.sock", line))

  # A runtime.read/1 request on runtime.sock, exactly as the CLI sends it.
  defp read(dir, op, fields),
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

  # Every regular file under the Runtime home, byte for byte; sockets are skipped.
  defp files(dir) do
    Path.wildcard(Path.join(dir, "**"), match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Map.new(&{&1, File.read!(&1)})
  end

  defp appended(dir, count) do
    Enum.reduce(1..count, ExecutionEvents.open(dir), fn n, store ->
      ExecutionEvents.append(dir, store, %{
        id: "turn-" <> String.pad_leading(Integer.to_string(n, 16), 16, "0"),
        worker_id: "alpha",
        backend: "codex",
        state: "running",
        started_at: "2026-11-09T10:00:00Z"
      })
    end)
  end

  test "events and a follow page on runtime.sock are byte-identical to read.sock's", %{dir: dir} do
    store = appended(dir, 5)
    launch(dir)

    # `atlas-runtime events --limit 2`, on both sockets.
    events = ~s({"api":"runtime.read/1","op":"events","limit":2})
    golden = raw(dir, "read.sock", events)
    assert raw(dir, "runtime.sock", events) == golden
    page = JSON.decode!(golden)
    assert Enum.sort(Map.keys(page)) == @page

    assert %{"op" => "events", "events" => [%{"sequence" => 1}, %{"sequence" => 2}]} = page
    assert %{"more" => true, "cursor" => cursor} = page
    assert cursor == store["epoch"] <> ":2"

    # One follow page, from that cursor and from another epoch (a reset), on both sockets.
    other = String.duplicate("0", 32) <> ":1"

    for fields <- [%{"cursor" => cursor}, %{"cursor" => other}] do
      line = JSON.encode!(Map.merge(%{"api" => "runtime.read/1", "op" => "follow"}, fields))
      golden = raw(dir, "read.sock", line)
      assert raw(dir, "runtime.sock", line) == golden
      frame = JSON.decode!(golden)
      assert %{"op" => "follow", "type" => "page", "more" => false} = frame
      assert Enum.sort(Map.keys(frame) -- ["reset", "type"]) == @page
      assert frame["cursor"] == store["epoch"] <> ":5"

      if fields["cursor"] == other,
        do: assert(%{"reset" => %{"reason" => "epoch_changed"}} = frame),
        else: assert([%{"sequence" => 3} | _] = frame["events"])
    end
  end

  test "runtime.sock serves no history read and leaves state and records unchanged", %{
    dir: dir
  } do
    service = launch(dir)
    run = start(service, dir, "alpha", true)
    await(fn -> :sys.get_state(service).workers["alpha"].run.pending_question end)
    before = {:sys.get_state(service), files(dir)}

    # Every other runtime.read/1 operation, and one that names none.
    for request <- [
          %{"op" => "turns"},
          %{"op" => "turn", "turn_id" => run.id},
          %{"op" => "workers"},
          %{"op" => "output", "turn_id" => run.id},
          %{"op" => "question"},
          %{}
        ] do
      reply = send_line(dir, JSON.encode!(Map.put(request, "api", "runtime.read/1")))
      assert %{"api" => "runtime.read/1", "error" => %{"code" => "not_journal"}} = reply
      assert map_size(reply) == 2
    end

    # A journal operation is still validated as runtime.read/1.
    assert send_line(dir, ~s({"op":"events"}))["error"]["code"] == "unsupported_api"
    assert read(dir, "events", %{"turn_id" => run.id})["error"]["code"] == "invalid_request"
    assert read(dir, "events", %{"limit" => 101})["error"]["code"] == "invalid_request"

    # The command form of turns is still refused.
    assert %{"command_error" => refused} = send_line(dir, ~s({"command":"turns"}))
    assert refused =~ "turns is not served on runtime.sock"

    assert {:sys.get_state(service), files(dir)} == before
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

    # The events command keeps its replies.
    assert_raise ArgumentError,
                 ~r/\Astale execution event cursor; earliest usable cursor: /,
                 fn ->
                   ExecutionEvents.query(store, early, 1)
                 end

    assert ExecutionEvents.query(store, nil, 1)["retention_gap"]
  end

  describe "follow" do
    defp follow(dir, fields \\ %{}) do
      socket = connect(dir, "runtime.sock")
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
      assert head == ExecutionEvents.head(:sys.get_state(service).events)

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

    test "heartbeats follow a service answer; a service stop ends the stream",
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
