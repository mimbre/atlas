Code.require_file("support.exs", __DIR__)

defmodule AtlasE2E.Pull.TiedTest do
  @moduledoc """
  Every child is tied to the run and ended on every exit path (gatefix 2026-11-18: on
  develop b4fd03e5 a setup that failed left `atlas-runtime events --follow` behind, in a
  group of its own its tether's KILL never reached, and the edge's listener open):

  - a tether leads a group of its own and its command stays in it;
  - a reader records that group, and its stop or the reaper's KILL of the group ends the
    command, also when the tether is the one KILLed;
  - what the run started is stopped when setup fails (no context), the last started first,
    whatever one stop does;
  - a tmux socket file with no server on it is no leak; one a server still answers on is.

  Liveness FIFOs show a real process gone (no `ps`); an injected process table stands in
  for `ps` where the reaper reads one.
  """
  use ExUnit.Case, async: true

  alias AtlasE2E.Pull.{Bench, Edge, Fixture, Reader, Run}
  alias AtlasE2E.PullTest.Support

  @t1 "Wed Nov 18 10:00:00 2026"

  setup do
    run = Support.tmp!("tied")
    on_exit(fn -> File.rm_rf!(run) end)
    %{run: run}
  end

  # A tethered reader whose command holds the liveness FIFO and then waits for a signal,
  # reading no stdin (as `events --follow`: the end of the tether's stdin pipe does not end
  # it; a `cat` would end with its tether and prove nothing).
  defp holding_reader(c, fifo, opts \\ []) do
    {:ok, reader} =
      Reader.start_link(
        [
          command: "/bin/sh",
          args: Support.holding(fifo, [Support.stub!(), "hold"]),
          stub: Support.stub!(),
          source: :rt,
          name: "probe",
          run: c.run,
          hub: Support.hub!(),
          lstart: fn _ -> @t1 end
        ] ++ opts
      )

    reader
  end

  test "a tether leads a group of its own, and its command stays in it" do
    port = Support.port!(Support.stub!(), ["ids"])
    {:os_pid, tether} = Port.info(port, :os_pid)
    assert_receive {^port, {:data, json}}
    assert_receive {^port, {:exit_status, 0}}
    ids = JSON.decode!(json)
    assert ids["pid"] != tether
    assert ids["pgid"] == tether
  end

  test "a reader records its tether's group: the reaper's KILL of it ends the command", c do
    {fifo, watcher} = Support.liveness!(c.run)
    reader = holding_reader(c, fifo)
    assert_receive {^watcher, {:data, "up\n"}}
    tether = Reader.os_pid(reader)
    assert [%{"what" => "port", "pid" => ^tether, "pgid" => ^tether}] = Bench.registry(c.run)

    # The reaper as on the failed setup: the tether is alive in the table, its group recorded.
    {_, _rows} =
      Bench.reap(c.run,
        fast: true,
        own_pgid: 1,
        ps: fn ->
          [%{pid: tether, ppid: 1, pgid: tether, stat: "S", lstart: @t1, command: "x"}]
        end,
        connect: fn _ -> true end
      )

    assert_receive {^watcher, {:exit_status, 0}}
  end

  test "stopping a reader ends its command: the group first, then the Port", c do
    {fifo, watcher} = Support.liveness!(c.run)
    reader = holding_reader(c, fifo)
    assert_receive {^watcher, {:data, "up\n"}}
    ref = Process.monitor(reader)
    Reader.stop(reader)
    assert_receive {:DOWN, ^ref, :process, ^reader, _}
    assert_receive {^watcher, {:exit_status, 0}}
  end

  test "what the run started is stopped when setup fails, the last started first", c do
    {fifo, watcher} = Support.liveness!(c.run)
    tls = Fixture.tls()
    {:ok, closed} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, upstream} = :inet.port(closed)
    :gen_tcp.close(closed)

    {:ok, edge} =
      Edge.start_link(upstream: {{127, 0, 0, 1}, upstream}, tls: tls, hub: Support.hub!())

    Bench.started("edge", fn -> Edge.stop(edge) end)
    edge_port = Edge.port(edge)
    refute Bench.refuses?(edge_port)
    test = self()
    Bench.started("raises", fn -> send(test, :raised) && raise "boom" end)
    reader = holding_reader(c, fifo)
    assert_receive {^watcher, {:data, "up\n"}}
    refs = for p <- [edge, reader], do: Process.monitor(p)

    # Setup failed: there is no context.
    stopped = Run.teardown(nil)

    assert [{"reader probe", :ok}, {"raises", {:error, _}}, {"edge", :ok}] = stopped
    assert_receive :raised
    for ref <- refs, do: assert_receive({:DOWN, ^ref, :process, _, _})
    assert_receive {^watcher, {:exit_status, 0}}
    assert Bench.refuses?(edge_port)
    # Nothing is tied any more: a second teardown stops nothing.
    assert Run.teardown(nil) == []
  end

  test "a tmux socket file no server answers on is removed, not a leak", c do
    path = Path.join(c.run, "s.tmux")
    {:ok, listen} = :gen_tcp.listen(0, ifaddr: {:local, path})
    :gen_tcp.close(listen)
    assert File.exists?(path)
    refute Bench.socket_answers?(path)
    Bench.record(c.run, "tmux_socket", %{socket: path})

    assert {:ok, _} =
             Bench.reap(c.run,
               fast: true,
               own_pgid: 1,
               ps: fn -> [] end,
               connect: fn _ -> true end
             )

    refute File.exists?(path)
  end

  test "a tmux socket a server still answers on is a leak, and is removed", c do
    path = Path.join(c.run, "s.tmux")
    {:ok, listen} = :gen_tcp.listen(0, ifaddr: {:local, path})
    on_exit(fn -> :gen_tcp.close(listen) end)
    assert Bench.socket_answers?(path)
    Bench.record(c.run, "tmux_socket", %{socket: path})

    assert {:error, rows} =
             Bench.reap(c.run,
               fast: true,
               own_pgid: 1,
               ps: fn -> [] end,
               connect: fn _ -> true end
             )

    assert [%{gone: false, pid: nil}] = Enum.filter(rows, &String.contains?(&1.what, path))
    refute File.exists?(path)
  end
end
