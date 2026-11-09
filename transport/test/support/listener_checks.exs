defmodule AtlasTransport.ListenerChecks do
  @moduledoc false
  import ExUnit.Assertions

  def eventually(check, attempts \\ 200)
  def eventually(check, 0), do: assert(check.())

  def eventually(check, attempts) do
    if check.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          eventually(check, attempts - 1)
        )
  end

  def exercise(server, port, connect, ping, stop) do
    state = :sys.get_state(server)
    peers = state.peers
    healthy = connect.()
    eventually(fn -> length(Task.Supervisor.children(peers)) == 1 end)
    [healthy_worker] = Task.Supervisor.children(peers)

    # This is the shipped preflight and the actual nc binary, on owned loopback.
    script =
      ~s(. "$1/bin/lib/env.sh"; host=127.0.0.1; port="$2"; prog=proof; env=test; fly_app=fixture; settings=fixture; reach_control)

    assert {"", 0} =
             System.cmd(
               "bash",
               ["-c", script, "proof", Path.expand("../../..", __DIR__), Integer.to_string(port)],
               stderr_to_stdout: true
             )

    for _ <- 1..3 do
      peer = raw(port)
      :gen_tcp.close(peer)
    end

    plaintext = raw(port)

    :ok =
      :gen_tcp.send(
        plaintext,
        ~s({"op":"hello","env":"test","environment":"test","client":"agent","spec":"0.16.0","machine":"fixture-machine","token":"synthetic-bus-token"}\n)
      )

    assert_closed(plaintext, 2_000)
    :gen_tcp.close(plaintext)

    eventually(fn -> length(Task.Supervisor.children(peers)) == 1 end)
    assert Process.alive?(state.acceptor)
    ping.(healthy)
    fresh = connect.()
    AtlasTransport.close(fresh)
    eventually(fn -> length(Task.Supervisor.children(peers)) == 1 end)

    IO.puts(
      "listener_proof #{inspect(server)}: actual env.sh/nc exit=0; earlyclose x3; authenticated exchange and held session pass"
    )

    idle = raw(port)
    eventually(fn -> length(Task.Supervisor.children(peers)) == 2 end)
    [idle_worker] = Task.Supervisor.children(peers) -- [healthy_worker]
    began = System.monotonic_time(:millisecond)
    fresh = connect.()
    elapsed = System.monotonic_time(:millisecond) - began
    assert elapsed < 2_000
    assert {:error, :timeout} = :gen_tcp.recv(idle, 0, 20)
    AtlasTransport.close(fresh)
    ping.(healthy)

    IO.puts(
      "listener_proof #{inspect(server)}: valid exchange with idle handshake elapsed_ms=#{elapsed} (<2000)"
    )

    # The worker owns the pre-TLS socket. An untrappable crash closes only it.
    Process.exit(idle_worker, :kill)
    assert_closed(idle, 2_000)
    :gen_tcp.close(idle)
    eventually(fn -> length(Task.Supervisor.children(peers)) == 1 end)
    ping.(healthy)

    # Admission recovery must leave both healthy sessions and pending peers alive.
    idle = raw(port)
    eventually(fn -> length(Task.Supervisor.children(peers)) == 2 end)
    Process.exit(state.acceptor, :kill)
    eventually(fn -> :sys.get_state(server).acceptor != state.acceptor end)
    assert {:error, :timeout} = :gen_tcp.recv(idle, 0, 20)
    ping.(healthy)
    fresh = connect.()
    AtlasTransport.close(fresh)
    :gen_tcp.close(idle)
    eventually(fn -> length(Task.Supervisor.children(peers)) == 1 end)

    IO.puts(
      "listener_proof #{inspect(server)}: handshake child crash closes peer; acceptor kill recovers; held session survives"
    )

    # Keep one peer idle through the existing five-second handshake deadline.
    idle = raw(port)
    began = System.monotonic_time(:millisecond)
    assert_closed(idle, 6_000)
    elapsed = System.monotonic_time(:millisecond) - began
    assert elapsed >= 4_500 and elapsed < 6_000
    :gen_tcp.close(idle)
    eventually(fn -> length(Task.Supervisor.children(peers)) == 1 end)
    IO.puts("listener_proof #{inspect(server)}: idle deadline closes peer elapsed_ms=#{elapsed}")

    # The finite limit includes established sessions, so no population can grow
    # without bound by completing TLS just before its handshake deadline.
    idles =
      for n <- 2..64 do
        socket = raw(port)
        eventually(fn -> length(Task.Supervisor.children(peers)) == n end)
        socket
      end

    excess = raw(port)
    assert_closed(excess, 2_000)
    :gen_tcp.close(excess)
    assert length(Task.Supervisor.children(peers)) == 64
    ping.(healthy)
    [released | held] = idles
    :gen_tcp.close(released)
    eventually(fn -> length(Task.Supervisor.children(peers)) == 63 end)
    fresh = connect.()
    AtlasTransport.close(fresh)
    eventually(fn -> length(Task.Supervisor.children(peers)) == 63 end)

    IO.puts(
      "listener_proof #{inspect(server)}: 64 peer bound; excess closed; held session works; capacity reclaimed"
    )

    # Control's supervised Session also follows the lifetime of its peer worker,
    # including the handoff boundary; Bus's task owns its socket directly.
    Process.exit(healthy_worker, :kill)
    assert {:error, :closed} = AtlasTransport.recv(healthy, 0, 2_000)
    AtlasTransport.close(healthy)
    eventually(fn -> length(Task.Supervisor.children(peers)) == 62 end)
    healthy = connect.()

    IO.puts(
      "listener_proof #{inspect(server)}: established worker crash closes owned socket; new authenticated exchange passes"
    )

    owned = [peers, :sys.get_state(server).acceptor | Task.Supervisor.children(peers)]
    stop.()
    eventually(fn -> Enum.all?(owned, &(not Process.alive?(&1))) end)
    assert {:error, :closed} = AtlasTransport.recv(healthy, 0, 2_000)
    AtlasTransport.close(healthy)

    for peer <- held do
      assert_closed(peer, 2_000)
      :gen_tcp.close(peer)
    end

    assert {:error, _} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 100)

    IO.puts(
      "listener_proof #{inspect(server)}: shutdown closes listener, all owned tasks and peers; owned_alive=0"
    )
  end

  defp raw(port) do
    {:ok, peer} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 1_000)
    peer
  end

  # SSL may send a TLS alert before closing the underlying TCP socket. It must
  # still close; application data (record type 23) never satisfies this check.
  defp assert_closed(socket, timeout) do
    drain_closed(socket, System.monotonic_time(:millisecond) + timeout, <<>>)
  end

  defp drain_closed(socket, deadline, bytes) do
    assert byte_size(bytes) < 1_024

    case :gen_tcp.recv(socket, 0, max(1, deadline - System.monotonic_time(:millisecond))) do
      {:error, :closed} -> assert_alerts(bytes)
      {:ok, data} -> drain_closed(socket, deadline, bytes <> data)
      other -> flunk("peer did not close: #{inspect(other)}")
    end
  end

  defp assert_alerts(<<>>), do: :ok

  defp assert_alerts(<<21, 3, _, length::16, _alert::binary-size(length), rest::binary>>),
    do: assert_alerts(rest)

  defp assert_alerts(other), do: flunk("unexpected pre-TLS data: #{inspect(other)}")
end
