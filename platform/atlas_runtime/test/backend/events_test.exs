Code.require_file("support.exs", __DIR__)

defmodule AtlasRuntime.BackendTest.Events do
  @moduledoc """
  The event stream (design §8.4) end to end on a real Bandit listener on a Unix socket:
  `AtlasRuntime.Backend.Events` writing what the test facade's fake sends. The window,
  resets and visibility are the fake's (the work core's, later); these tests show the
  backend carries them: resume with Last-Event-ID, reset, every notification (the core's
  heartbeat included) as an event, no timer of the loop's own, and per-client streams.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AtlasRuntime.Backend.{Listener, TestSocket}
  alias AtlasRuntime.Test.FakeWork
  alias AtlasRuntime.Test.WorkFacade, as: F

  # A listener whose client is named by a request header, so two clients can subscribe.
  defmodule ClientFromHeader do
    @behaviour Plug
    def init(opts), do: opts

    def call(conn, _opts) do
      [id] = Plug.Conn.get_req_header(conn, "x-client")
      rights = if String.ends_with?(id, "-all"), do: [:read, :read_all], else: [:read]

      conn
      |> Plug.Conn.assign(:client, {id, rights})
      |> AtlasRuntime.Test.WorkRest.call([])
    end
  end

  setup do
    FakeWork.reset_all()
    FakeWork.owner(self())
    on_exit(&FakeWork.reset_all/0)

    home = TestSocket.home()
    on_exit(fn -> File.rm_rf!(home) end)
    %{home: home}
  end

  defp listen(%{home: home}, size) do
    start_supervised!(FakeWork.window(size))
    start_supervised!({Listener, home: home, router: AtlasRuntime.Test.WorkRest})
    Listener.path(home)
  end

  # The client the listener names: the user name of this process's uid.
  defp me do
    {name, 0} = System.cmd("id", ["-un"])
    "local:" <> String.trim(name)
  end

  defp changed(owner, work_id \\ "w-1", state \\ :running),
    do:
      FakeWork.notify(
        owner,
        &%F.WorkChanged{sequence: &1, work_id: work_id, revision: &1, state: state}
      )

  defp subscribe(path, headers \\ []) do
    stream = TestSocket.open(path, "/v1/events", headers)
    assert_receive {:fake_work, :subscribe, client, input}, 2_000
    {stream, client, input}
  end

  defp frame(id, work_id \\ "w-1", state \\ "running"),
    do:
      "event: work\nid: #{id}\ndata: " <>
        JSON.encode!(%{
          "sequence" => id,
          "work_id" => work_id,
          "revision" => id,
          "state" => state
        }) <> "\n\n"

  test "the stream opens as text/event-stream; id: is the change sequence", ctx do
    path = listen(ctx, 10)
    {stream, {id, rights}, %F.SubscribeInput{from: nil}} = subscribe(path)
    assert id == me()
    assert :read_all in rights and :choose_slot in rights

    {stream, head} = TestSocket.await(stream, "\r\n\r\n")
    assert head =~ "HTTP/1.1 200"
    assert head =~ "content-type: text/event-stream"
    assert head =~ "cache-control: no-cache"

    changed(me())
    {stream, _} = TestSocket.await(stream, frame(1))

    FakeWork.notify(:all, &%F.CapacityAvailable{sequence: &1, capacity: FakeWork.a_capacity()})
    {stream, seen} = TestSocket.await(stream, "event: capacity\nid: 2\ndata: {")
    assert seen =~ ~s("incarnation":"i-1")
    TestSocket.close(stream)
  end

  test "resume inside the window with Last-Event-ID: the missed changes, then live ones", ctx do
    path = listen(ctx, 10)
    for _ <- 1..3, do: changed(me())

    {stream, _client, %F.SubscribeInput{from: 1}} = subscribe(path, [{"last-event-id", "1"}])
    {stream, seen} = TestSocket.await(stream, frame(3))
    assert seen =~ frame(2)
    refute seen =~ frame(1)
    refute seen =~ "event: reset"

    changed(me())
    {stream, _} = TestSocket.await(stream, frame(4))
    TestSocket.close(stream)
  end

  test "reset when Last-Event-ID is behind the window; the stream then goes on", ctx do
    path = listen(ctx, 2)
    for _ <- 1..5, do: changed(me())

    {stream, _client, _} = subscribe(path, [{"last-event-id", "1"}])

    {stream, seen} =
      TestSocket.await(stream, "event: reset\nid: 5\ndata: {\"current_sequence\":5}\n\n")

    refute seen =~ "event: work"

    changed(me())
    {stream, _} = TestSocket.await(stream, frame(6))
    TestSocket.close(stream)
  end

  test "reset across an incarnation, resume within the new one", ctx do
    path = listen(ctx, 10)
    changed(me())
    changed(me())
    FakeWork.restart()
    changed(me())

    {old, _client, _} = subscribe(path, [{"last-event-id", "2"}])
    {old, _} = TestSocket.await(old, "event: reset\nid: 3\n")
    TestSocket.close(old)

    {new, _client, _} = subscribe(path, [{"last-event-id", "3"}])
    changed(me())
    {new, seen} = TestSocket.await(new, frame(4))
    refute seen =~ "event: reset"
    TestSocket.close(new)
  end

  defp heartbeat(at) do
    FakeWork.broadcast(fn _client ->
      %F.Heartbeat{
        at: at,
        capacity: FakeWork.a_capacity(),
        running: [%F.RunningAttempt{work_id: "w-1", attempt: 1, state: :running, alive: true}]
      }
    end)
  end

  test "every boundary notification is an event, the core's heartbeat included", ctx do
    path = listen(ctx, 10)
    {stream, _client, _} = subscribe(path)

    changed(me())
    FakeWork.notify(:all, &%F.CapacityAvailable{sequence: &1, capacity: FakeWork.a_capacity()})
    heartbeat(~U[2026-11-16 10:00:15Z])
    # A reset the core sends mid-stream (the subscriber fell behind its window).
    FakeWork.notify(:all, &%F.Reset{current_sequence: &1})

    {stream, seen} =
      TestSocket.await(stream, "event: reset\nid: 3\ndata: {\"current_sequence\":3}\n\n")

    assert seen =~ frame(1)
    assert seen =~ "event: capacity\nid: 2\ndata: {"

    # The heartbeat has no sequence, so no id: line.
    [_, after_heartbeat] = String.split(seen, "event: heartbeat\n", parts: 2)
    assert after_heartbeat =~ ~r/\Adata: \{"at":"2026-11-16T10:00:15Z"/

    assert after_heartbeat =~
             ~s("running":[{"alive":true,"attempt":1,"state":"running","work_id":"w-1"}])

    TestSocket.close(stream)
  end

  test "the loop has no timer: silence writes nothing, until the core's next heartbeat", ctx do
    path = listen(ctx, 10)
    {stream, _client, _} = subscribe(path)
    {stream, head} = TestSocket.await(stream, "\r\n\r\n")

    {_socket, quiet} = TestSocket.drain(stream, 500)
    assert quiet == head

    heartbeat(~U[2026-11-16 10:00:30Z])

    {stream, seen} =
      TestSocket.await(stream, ~s(event: heartbeat\ndata: {"at":"2026-11-16T10:00:30Z"))

    refute seen =~ "keepalive"
    TestSocket.close(stream)
  end

  @tag capture_log: true
  test "anything that is no event is not written", ctx do
    path = listen(ctx, 10)
    {stream, _client, _} = subscribe(path)
    [{pid, _}] = FakeWork.subscribers()
    send(pid, {:atlas_runtime_work, %F.Outcome.Subscribed{}})
    send(pid, {:other, :message})
    changed(me())
    {stream, seen} = TestSocket.await(stream, frame(1))
    assert seen |> String.split("event: ") |> length() == 2
    TestSocket.close(stream)
  end

  test "each stream is filtered by its client's rights", %{home: home} do
    start_supervised!(FakeWork.window(10))
    path = Path.join(home, "clients.sock")

    start_supervised!(
      {Bandit, plug: ClientFromHeader, ip: {:local, path}, port: 0, startup_log: false}
    )

    {a, {"a", [:read]}, _} = subscribe(path, [{"x-client", "a"}])
    {b, {"b", [:read]}, _} = subscribe(path, [{"x-client", "b"}])
    {all, {"c-all", _}, _} = subscribe(path, [{"x-client", "c-all"}])

    changed("a", "w-a")
    changed("b", "w-b")

    {a, seen_a} = TestSocket.await(a, frame(1, "w-a"))
    {b, seen_b} = TestSocket.await(b, frame(2, "w-b"))
    {all, seen_all} = TestSocket.await(all, frame(2, "w-b"))

    {a, seen_a} = {a, TestSocket.drain(a, 100) |> elem(1) |> Kernel.<>(seen_a)}
    refute seen_a =~ "w-b"
    refute seen_b =~ "w-a"
    assert seen_all =~ frame(1, "w-a")

    for s <- [a, b, all], do: TestSocket.close(s)
  end

  test "stopping the listener ends an open stream at once, not after a shutdown timeout", ctx do
    path = listen(ctx, 10)
    {stream, _client, _} = subscribe(path)
    [{pid, _}] = FakeWork.subscribers()
    ref = Process.monitor(pid)

    {{micros, :ok}, log} =
      with_log(fn -> :timer.tc(fn -> stop_supervised(Listener) end) end)

    assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}, 1_000
    # ThousandIsland's own shutdown timeout is 15 s.
    assert micros < 2_000_000
    refute File.exists?(path)
    # A normal stop is no error: nothing logged for the open stream.
    refute log =~ "[error]"
    TestSocket.close(stream)
  end

  # The process the connection's exit signals come from: its supervisor.
  defp parent_of(pid) do
    {:dictionary, dictionary} = Process.info(pid, :dictionary)
    [parent | _] = Keyword.fetch!(dictionary, :"$ancestors")
    parent
  end

  test "a supervisor exit that is no shutdown still stops the stream, and is logged", ctx do
    path = listen(ctx, 10)
    {stream, _client, _} = subscribe(path)
    [{pid, _}] = FakeWork.subscribers()
    ref = Process.monitor(pid)

    log =
      capture_log(fn ->
        send(pid, {:EXIT, parent_of(pid), :boom})
        assert_receive {:DOWN, ^ref, :process, ^pid, :boom}, 1_000
      end)

    assert log =~ "[error]"
    assert log =~ ":boom"
    TestSocket.close(stream)
  end

  @tag capture_log: true
  test "another linked process: a normal end leaves the stream open, a failure ends it", ctx do
    path = listen(ctx, 10)
    {stream, _client, _} = subscribe(path)
    [{pid, _}] = FakeWork.subscribers()
    ref = Process.monitor(pid)

    send(pid, {:EXIT, self(), :normal})
    changed(me())
    {stream, _} = TestSocket.await(stream, frame(1))
    refute_received {:DOWN, ^ref, _, _, _}

    send(pid, {:EXIT, self(), :boom})
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
    TestSocket.close(stream)
  end

  test "a client that leaves ends its stream", ctx do
    path = listen(ctx, 10)
    {stream, _client, _} = subscribe(path)
    [{pid, _}] = FakeWork.subscribers()
    ref = Process.monitor(pid)
    TestSocket.close(stream)
    # Noticed at the next write: the core's heartbeat.
    heartbeat(~U[2026-11-16 10:00:45Z])
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000
  end
end
