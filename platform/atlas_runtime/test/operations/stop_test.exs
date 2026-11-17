defmodule AtlasRuntime.Operations.StopTest do
  # stop through the facade (design §13.1 Q9, O1 9–12): no new work and no start, buffered
  # work stays; running attempts get the signal and, after cancel_grace, the kill (with
  # force, the kill at once) and end interrupted/runtime_stop, retryable; then the
  # Service's own service stop ends the process. A repeat answers the same.
  use ExUnit.Case, async: false

  import AtlasRuntime.WorkHarness
  alias AtlasRuntime.Boundary.Operations, as: F
  alias AtlasRuntime.Boundary.Work, as: W
  alias AtlasRuntime.Service
  alias AtlasRuntime.Work.Store
  alias AtlasRuntimeBoundary.Generator.NotPermitted

  @moduletag capture_log: true
  @operator {"local:op", [:inspect, :operate]}

  defmodule Recorder do
    @moduledoc false
    # In front of the Service: tells the test of every command and message the core sends
    # it, and passes each on unchanged.
    use GenServer

    @impl true
    def init({service, test}), do: {:ok, {service, test}}

    @impl true
    def handle_call(request, _from, {service, test} = state) do
      if is_map(request), do: send(test, {:service_command, request["command"]})
      {:reply, GenServer.call(service, request, :infinity), state}
    end

    @impl true
    def handle_info(message, {service, test} = state) do
      send(test, {:service_message, message})
      send(service, message)
      {:noreply, state}
    end
  end

  # The bench's Service and core again, the Service's exit reported to the test instead of
  # stopping this VM, and the core talking to it through `Recorder`.
  defp bench!(grace_ms) do
    bench = start!()
    stop_all()
    test = self()
    File.rm(Path.join(bench.dir, "runtime.sock"))
    File.rm(Path.join(bench.dir, "read.sock"))

    {:ok, service} =
      GenServer.start(Service, {bench.dir, nil, [], [halt: &send(test, {:halted, &1})]})

    {:ok, recorder} = GenServer.start(Recorder, {service, test})
    on_exit(fn -> Process.exit(recorder, :kill) end)
    start_work!(%{bench | service: recorder}, cancel_grace_ms: grace_ms, heartbeat_ms: 60_000)
    %{bench | service: service}
  end

  # s1 runs a turn that ends on the signal, s2 one that only a kill ends; a third waits.
  defp running!(bench) do
    soft = submit!(bench, "hang until stopped", %{slot: "s1"}, client("c1", [:choose_slot]))
    hard = submit!(bench, "stubborn until killed", %{slot: "s2"}, client("c1", [:choose_slot]))

    for work <- [soft, hard] do
      [%{turn_id: turn}] = await_launch(bench, work).attempts
      await(fn -> turn(bench, turn)["session_id"] end)
    end

    waiting = submit!(bench, "complete after the stop")
    assert work!(waiting.work_id).state == :buffered
    flush()
    {soft, hard, waiting}
  end

  defp flush do
    receive do
      {:service_command, _} -> flush()
      {:service_message, _} -> flush()
    after
      0 -> :ok
    end
  end

  defp commands do
    receive do
      {:service_command, command} -> [command | commands()]
    after
      0 -> []
    end
  end

  # The commands that signal or stop (a turn ending meanwhile also asks for a release).
  defp signals, do: Enum.filter(commands(), &(&1 in ["service-stop", "stop", "kill"]))

  defp termination(bench, work) do
    [%{turn_id: turn}] = work!(work.work_id).attempts
    turn(bench, turn)["termination"]
  end

  defp at(text), do: text |> DateTime.from_iso8601() |> elem(1)

  test "without force: the signal, the kill only after the grace; interrupted, runtime_stop; buffered stays; then the exit" do
    bench = bench!(800)
    {soft, hard, waiting} = running!(bench)
    held = work!(waiting.work_id)

    assert %F.Outcome.Stopping{mode: :stopping} = F.stop(@operator, %{})

    for work <- [soft, hard] do
      [attempt] = await_state(work.work_id, :interrupted).attempts
      assert attempt.result.reason == :runtime_stop
      assert attempt.result.retryable
      refute attempt.result.never_started
      assert attempt.quiescent
      assert %W.ResumePoint{turn_id: turn} = attempt.resume_point
      assert turn == attempt.turn_id
      # A stop is not a cancel.
      assert {attempt.cancel_stage, attempt.cancel_reason} == {nil, nil}
    end

    # The signal first; the stubborn one is killed only once the grace has passed.
    assert %{"stop_requested_at" => stop, "kill_requested_at" => kill} = termination(bench, hard)
    assert DateTime.diff(at(kill), at(stop), :millisecond) >= 800
    assert %{"mode" => "stop", "kill_requested_at" => nil} = termination(bench, soft)

    # The Service's service stop ends the process, once nothing runs.
    assert_receive {:halted, 0}, 5_000
    assert "service-stop" in commands()

    # Buffered work stays stored, unchanged, and never launched.
    assert work!(waiting.work_id) == held
    assert [%{state: :buffered}] = Store.read_work(bench.dir, waiting.work_id).attempts
    refute Enum.any?(launches(bench), &(&1["goal"] == "complete after the stop"))
  end

  test "with force: the kill at once, without the grace" do
    bench = bench!(5_000)
    {_soft, hard, _waiting} = running!(bench)
    started = System.monotonic_time(:millisecond)

    assert %F.Outcome.Stopping{mode: :stopping} = F.stop(@operator, %{force: true})

    [attempt] = await_state(hard.work_id, :interrupted).attempts
    assert System.monotonic_time(:millisecond) - started < 2_500
    assert attempt.result.reason == :runtime_stop
    assert %{"mode" => "kill", "stop_requested_at" => nil} = termination(bench, hard)
    assert_receive {:halted, 0}, 5_000
  end

  test "while stopping: not accepting, a submit is refused, and a free slot takes no buffered work" do
    bench = bench!(5_000)
    {soft, _hard, waiting} = running!(bench)
    held = work!(waiting.work_id)

    assert %F.Outcome.Stopping{} = F.stop(@operator, %{})
    assert %{mode: :stopping} = F.runtime_info(@operator)
    assert %{accepting: false} = W.capacity(client())

    assert %W.Outcome.AtCapacity{reason: :not_accepting} =
             W.submit(client(), request(bench, "complete during the stop"))

    # s1 is free once its turn ended on the signal; the buffered work stays where it was.
    await_state(soft.work_id, :interrupted)
    assert %{slots: %{free: 1}} = W.capacity(client())

    # The core has handled all it was sent (no heartbeat comes: 60 s); none of it started the work.
    core_idle()
    assert work!(waiting.work_id) == held
    refute Enum.any?(launches(bench), &(&1["goal"] == "complete after the stop"))
  end

  test "a repeated stop answers the same and signals nothing again" do
    bench = bench!(5_000)
    {_soft, _hard, _waiting} = running!(bench)

    assert %F.Outcome.Stopping{mode: :stopping, incarnation: incarnation} =
             first = F.stop(@operator, %{})

    assert signals() == ["service-stop"]

    assert %F.Outcome.Stopping{mode: :stopping, incarnation: ^incarnation} =
             again = F.stop(@operator, %{force: true})

    assert Map.delete(again, :slots) == Map.delete(first, :slots)
    core_idle()
    assert signals() == []
  end

  defp mode_file(bench), do: Path.join(bench.dir, "mode.json")

  # After the stop's exit: the Runtime starts again on the same home.
  defp restart(bench) do
    stop_all()
    bench = %{bench | service: start_service!(bench)}
    start_work!(bench)
    bench
  end

  # O2 10b, 11 for O1's own stop (dev2 review F1): the stop never writes `mode.json`.
  test "the stop leaves mode.json as it was: the same bytes when paused, also after a restart" do
    bench = bench!(800)
    {_soft, _hard, waiting} = running!(bench)
    assert %{mode: :paused} = F.pause(@operator)
    bytes = File.read!(mode_file(bench))
    assert %{"entries" => [%{"mode" => "paused"}]} = JSON.decode!(bytes)

    assert %F.Outcome.Stopping{mode: :stopping} = F.stop(@operator, %{})
    assert File.read!(mode_file(bench)) == bytes
    assert_receive {:halted, 0}, 5_000
    assert File.read!(mode_file(bench)) == bytes

    bench = restart(bench)
    assert %{mode: :paused} = F.runtime_info(@operator)
    assert File.read!(mode_file(bench)) == bytes
    core_idle()
    assert work!(waiting.work_id).state == :buffered
  end

  test "the stop leaves mode.json as it was: absent when open, also after a restart" do
    bench = bench!(800)
    {_soft, _hard, waiting} = running!(bench)
    refute File.exists?(mode_file(bench))

    assert %F.Outcome.Stopping{mode: :stopping} = F.stop(@operator, %{})
    refute File.exists?(mode_file(bench))
    assert_receive {:halted, 0}, 5_000
    refute File.exists?(mode_file(bench))

    restart(bench)
    assert %{mode: :open} = F.runtime_info(@operator)
    # Open again: the buffered work starts and completes now.
    await_state(waiting.work_id, :completed)
    refute File.exists?(mode_file(bench))
  end

  # The draining dispatch also asks whether the stop may end the process (merge §2.6, dev2
  # review F2): a Runtime that drains before its stop (the §6 procedure) still exits.
  test "a stop while draining: running turns end on it and the process exits" do
    bench = bench!(800)
    {soft, hard, waiting} = running!(bench)
    assert %{mode: :draining} = F.drain(@operator)
    assert [%{state: :returned}] = await_state(waiting.work_id, :returned).attempts
    bytes = File.read!(mode_file(bench))

    assert %F.Outcome.Stopping{mode: :stopping} = F.stop(@operator, %{})

    for work <- [soft, hard] do
      [attempt] = await_state(work.work_id, :interrupted).attempts
      assert attempt.result.reason == :runtime_stop
    end

    assert_receive {:halted, 0}, 5_000
    assert "service-stop" in commands()
    assert File.read!(mode_file(bench)) == bytes
  end

  test "operate is the right it needs: without it nothing stops" do
    _bench = bench!(5_000)

    assert %NotPermitted{capability: :stop, right: :operate} =
             F.stop({"remote:x", [:inspect]}, %{force: true})

    assert %{mode: :open} = F.runtime_info(@operator)
    assert %{accepting: true} = W.capacity(client())
    refute_received {:halted, _}
  end
end
