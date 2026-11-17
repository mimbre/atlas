defmodule AtlasRuntime.Work.ModeRestartTest do
  # S2 O2 acceptance 10 and 11: the mode outlasts a restart, and a stop leaves it alone
  # (design §13.1 Q6).
  use ExUnit.Case, async: false

  import AtlasRuntime.WorkHarness
  alias AtlasRuntime.Service
  alias AtlasRuntime.Work

  @moduletag capture_log: true

  setup do
    %{bench: start!(%{"slots" => ["s1"]})}
  end

  def gone(_pid, _launched), do: {:gone, "test: the process is gone"}

  defp mode_file(bench), do: Path.join(bench.dir, "mode.json")

  # The Runtime dies (core, Service and helpers) and starts again on the same home.
  defp restart(bench) do
    stop_all()
    bench = %{bench | service: start_service!(bench, &__MODULE__.gone/2)}
    start_work!(bench)
    bench
  end

  # A Service stop as `service stop` asks it, on a Service whose exit only tells the test.
  defp service_stop(bench) do
    stop_all()
    test = self()
    File.rm(Path.join(bench.dir, "runtime.sock"))
    File.rm(Path.join(bench.dir, "read.sock"))

    {:ok, service} =
      GenServer.start(Service, {bench.dir, nil, [], [halt: &send(test, {:halted, &1})]})

    bench = %{bench | service: service}
    start_work!(bench)
    assert Work.mode() in [:open, :paused, :draining]
    # As the socket does: the reply says whether to shut down, and the socket then asks.
    assert {%{service: "stopping"}, true} =
             GenServer.call(service, %{"command" => "service-stop"})

    send(service, :shutdown)
    assert_receive {:halted, 0}, 5_000
    await(fn -> Work.mode() == :stopping end)
    bench
  end

  test "pause, restart: still paused, and buffered work does not start", %{bench: bench} do
    first = submit!(bench, "hang first")
    await_launch(bench, first)
    second = submit!(bench, "complete second")
    assert Work.set_mode(:paused, "local:op") == :paused

    bench = restart(bench)
    assert Work.mode() == :paused
    # The hung turn is gone with the old Runtime: the slot is free.
    await_state(first.work_id, :interrupted)
    heartbeats(8)

    assert work!(second.work_id).state == :buffered
    refute Enum.any?(launches(bench), &(&1["goal"] == "complete second"))
  end

  test "drain, stop, restart: still draining", %{bench: bench} do
    assert Work.set_mode(:draining, "local:op") == :draining
    bench = service_stop(bench)
    restart(bench)
    assert Work.mode() == :draining
  end

  test "a stop leaves mode.json as it was: absent when open", %{bench: bench} do
    refute File.exists?(mode_file(bench))
    service_stop(bench)
    refute File.exists?(mode_file(bench))
  end

  test "a stop leaves mode.json as it was: the same bytes when paused", %{bench: bench} do
    assert Work.set_mode(:paused, "local:op") == :paused
    bytes = File.read!(mode_file(bench))

    assert %{"entries" => [%{"mode" => "paused", "changed_by" => "local:op"}]} =
             JSON.decode!(bytes)

    service_stop(bench)
    assert File.read!(mode_file(bench)) == bytes

    bench = restart(bench)
    assert Work.mode() == :paused
    assert File.read!(mode_file(bench)) == bytes
  end

  test "a mode.json that does not decode is refused, never read as open", %{bench: bench} do
    stop_work()
    File.write!(mode_file(bench), ~s({"entries":[{"mode":"stopping"}]}))

    assert {:error, {:mode, _why}} =
             AtlasRuntime.Work.start_link(bench.dir, service: bench.service)
  end
end
