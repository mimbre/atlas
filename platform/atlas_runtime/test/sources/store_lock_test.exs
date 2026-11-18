defmodule AtlasRuntime.Sources.StoreLockTest do
  @moduledoc """
  The source stores' one-writer lock (`AtlasRuntime.Sources.StoreLock`): one holder per
  `{home, source}`, waiters in order, other sources and homes free, and the lock released
  however its holder ends, a kill included. Each test has a server of its own.
  """
  use ExUnit.Case, async: true

  alias AtlasRuntime.Sources.StoreLock
  alias AtlasTestAwait, as: Await

  setup do
    %{server: start_supervised!({StoreLock, name: nil})}
  end

  # A process that takes the lock and holds it until it is sent `:done`; it tells the test
  # `{:holding, pid}` once it holds it. Sent `:raise`, its work raises: it rescues that,
  # tells the test `{:raised, pid}` and lives on until `:done`. Not linked to the test, so
  # a test can kill it; the server's link ends it with the server.
  defp take(server, home, name) do
    test = self()

    spawn(fn ->
      try do
        StoreLock.hold(
          home,
          name,
          fn ->
            send(test, {:holding, self()})

            receive do
              :done -> :ok
              :raise -> raise "the holder failed"
            end
          end,
          server
        )
      rescue
        RuntimeError ->
          send(test, {:raised, self()})
          receive do: (:done -> :ok)
      end

      send(test, {:released, self()})
    end)
  end

  defp queued(server, home, name, pids),
    do:
      Await.until(fn -> StoreLock.waiting(home, name, server) == pids end, wake: {:trace, server})

  test "one holder per source store; the others wait in order", %{server: server} do
    one = take(server, "/h", "flow-prod")
    assert_receive {:holding, ^one}

    two = take(server, "/h", "flow-prod")
    queued(server, "/h", "flow-prod", [two])
    three = take(server, "/h", "flow-prod")
    queued(server, "/h", "flow-prod", [two, three])
    refute_received {:holding, _}

    send(one, :done)
    assert_receive {:holding, ^two}
    assert StoreLock.waiting("/h", "flow-prod", server) == [three]
    send(two, :done)
    assert_receive {:holding, ^three}
    send(three, :done)
    assert_receive {:released, ^three}
    assert StoreLock.holder("/h", "flow-prod", server) == nil
  end

  test "another source, or the same source in another home, never waits", %{server: server} do
    one = take(server, "/h", "flow-prod")
    assert_receive {:holding, ^one}

    other_source = take(server, "/h", "source-b")
    assert_receive {:holding, ^other_source}
    other_home = take(server, "/other", "flow-prod")
    assert_receive {:holding, ^other_home}
    # The home is expanded: the same folder, written another way, is the same store.
    same = take(server, "/h/../h/.", "flow-prod")
    queued(server, "/h", "flow-prod", [same])

    for pid <- [one, other_source, other_home], do: send(pid, :done)
    assert_receive {:holding, ^same}
    send(same, :done)
    assert_receive {:released, ^same}
  end

  test "a holder whose work raises releases the lock, though it lives on", %{server: server} do
    one = take(server, "/h", "flow-prod")
    assert_receive {:holding, ^one}
    two = take(server, "/h", "flow-prod")
    queued(server, "/h", "flow-prod", [two])

    send(one, :raise)
    assert_receive {:raised, ^one}
    assert_receive {:holding, ^two}
    assert Process.alive?(one)

    send(two, :done)
    assert_receive {:released, ^two}
    send(one, :done)
    assert_receive {:released, ^one}
  end

  test "a holder that is killed releases the lock; a waiter that is killed leaves the queue",
       %{server: server} do
    one = take(server, "/h", "flow-prod")
    assert_receive {:holding, ^one}
    two = take(server, "/h", "flow-prod")
    queued(server, "/h", "flow-prod", [two])
    three = take(server, "/h", "flow-prod")
    queued(server, "/h", "flow-prod", [two, three])

    Process.exit(two, :kill)
    queued(server, "/h", "flow-prod", [three])

    Process.exit(one, :kill)
    assert_receive {:holding, ^three}
    refute_received {:holding, ^two}
    assert StoreLock.holder("/h", "flow-prod", server) == three
    send(three, :done)
    assert_receive {:released, ^three}
    assert StoreLock.holder("/h", "flow-prod", server) == nil
  end

  test "a process asks for one lock at a time: a nested request is refused, not deadlocked",
       %{server: server} do
    assert_raise ArgumentError, fn ->
      StoreLock.hold(
        "/h",
        "flow-prod",
        fn -> StoreLock.hold("/h", "source-b", fn -> :ok end, server) end,
        server
      )
    end

    # The refusal left the outer lock released.
    assert StoreLock.holder("/h", "flow-prod", server) == nil
    assert StoreLock.hold("/h", "flow-prod", fn -> :again end, server) == :again
  end

  test "the server's end ends its holders: none keeps writing unlocked", %{server: server} do
    one = take(server, "/h", "flow-prod")
    assert_receive {:holding, ^one}
    ref = Process.monitor(one)

    :ok = stop_supervised(StoreLock)
    assert_receive {:DOWN, ^ref, :process, ^one, :shutdown}
    refute Process.alive?(server)
  end
end
