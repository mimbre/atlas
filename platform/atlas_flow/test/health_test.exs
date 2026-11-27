defmodule AtlasFlow.HealthTest do
  # IS-Atlas-117: what Flow says about its health, for Control's health page. The Engine
  # notes when its round was due and when it finished, Dispatch each Runtime's poll, and
  # `_health` answers from that table alone, also while the Engine is held mid-round.
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias AtlasBus.Envelope
  alias AtlasFlow.{Engine, FakeFacts, Health, ManualClock, WorkSource}
  alias AtlasFlow.FakeFacts.Leasing, as: L

  @every 60_000

  defp health!(endpoint \\ nil) do
    name = :"health_#{System.unique_integer([:positive])}"
    start_supervised!({Health, name: name, endpoint: endpoint})
    name
  end

  defp at(clock),
    do: ManualClock.now(clock) |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  # The round ended, and the Engine has also set its next one (after answering).
  defp idle(engine) do
    Engine.idle(engine)
    :sys.get_state(engine)
  end

  describe "the Engine's round" do
    setup do
      Application.put_env(:atlas_bus, :store, "health-#{System.unique_integer([:positive])}")
      :ok = AtlasBus.attach("tester-#{System.unique_integer([:positive])}")
      start_supervised!({FakeFacts, description: AtlasFlow.Workshop.description()})
      FakeFacts.put("maker", %{"key" => "mia"})
      FakeFacts.put("widget", %{"key" => "W-1", "values" => %{"title" => "W-1"}})
      clock = start_supervised!({ManualClock, ~U[2026-11-23 10:00:00Z]})
      table = health!()

      engine =
        start_supervised!(
          {Engine,
           every: @every, clock: {ManualClock, clock}, model: AtlasFlow.Workshop, health: table}
        )

      idle(engine)
      %{clock: clock, table: table, engine: engine}
    end

    test "a finished round says when it was due and finished, and when the next is due", c do
      flow = Health.report(c.table)["flow"]
      assert flow["due"] == nil
      assert flow["last_due"] == "2026-11-23T10:00:00Z"
      assert flow["last_finished"] == "2026-11-23T10:00:00Z"
      assert flow["next_due"] == "2026-11-23T10:01:00Z"
    end

    test "a round held while it steps keeps its due; the report does not wait for it", c do
      test = self()
      ref = make_ref()

      hold = fn
        false, {:in, :round_step}, _state ->
          send(test, {ref, :held})
          receive do: ({^ref, :go} -> :ok)
          true

        held, _event, _state ->
          held
      end

      :ok = :sys.install(c.engine, {hold, false})
      ManualClock.advance(c.clock, @every)
      assert_receive {^ref, :held}

      # Held at its first step, the round that was due at 10:01 stays due; nine minutes on
      # it is still the round stepping, as on 2026-11-23.
      ManualClock.advance(c.clock, 9 * 60_000)
      flow = Health.report(c.table)["flow"]
      assert flow["due"] == "2026-11-23T10:01:00Z"
      assert flow["last_due"] == "2026-11-23T10:00:00Z"

      send(c.engine, {ref, :go})
      :sys.remove(c.engine, hold)
      idle(c.engine)
      flow = Health.report(c.table)["flow"]
      assert flow["due"] == nil
      assert flow["last_due"] == "2026-11-23T10:01:00Z"
      assert flow["last_finished"] == at(c.clock)
    end
  end

  test "Dispatch notes each Runtime's last poll and what it said of the Runtime" do
    dir = Path.join(System.tmp_dir!(), "health-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    table = health!()
    ctx = L.start(dir, health: table)

    assert {:polled, %{timing: %{poll_max: poll_max}}} =
             WorkSource.poll({"mini", "ada"}, L.poll_input("mini", [], %{}))

    L.advance(ctx, 90)
    assert {:polled, _} = WorkSource.poll({"laptop", "bea"}, L.poll_input("laptop", [], %{}))

    mini = %{
      "runtime" => "mini",
      "polled_at" => "2026-11-17T12:00:00Z",
      "build" => "test",
      "incarnation" => "inc-1",
      "incarnation_since" => "2026-11-17T12:00:00Z",
      "poll_max" => poll_max
    }

    assert Health.report(table)["runtimes"] == [
             %{
               mini
               | "runtime" => "laptop",
                 "polled_at" => "2026-11-17T12:01:30Z",
                 "incarnation_since" => "2026-11-17T12:01:30Z"
             },
             mini
           ]

    # The same incarnation keeps its start; a new one (a restart, on a new build) starts again.
    L.advance(ctx, 60)
    assert {:polled, _} = WorkSource.poll({"mini", "ada"}, L.poll_input("mini", [], %{}))
    assert %{"incarnation_since" => "2026-11-17T12:00:00Z"} = runtime(table, "mini")

    L.advance(ctx, 60)

    assert {:polled, _} =
             WorkSource.poll(
               {"mini", "ada"},
               %{L.poll_input("mini", [], %{}) | incarnation: "inc-2", build: "b2"}
             )

    assert %{
             "build" => "b2",
             "incarnation" => "inc-2",
             "incarnation_since" => "2026-11-17T12:03:30Z"
           } = runtime(table, "mini")
  end

  defp runtime(table, id), do: Enum.find(Health.report(table)["runtimes"], &(&1["runtime"] == id))

  test "Dispatch notes the queue: what waits, oldest first, without what a lease holds" do
    dir = Path.join(System.tmp_dir!(), "health-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    table = health!()
    ctx = L.start(dir, health: table)

    L.supervised_task("B-1", "ada", at: L.epoch())
    L.supervised_task("B-2", "ada", at: DateTime.add(L.epoch(), 60))
    :ok = AtlasFlow.Dispatch.resync()

    assert [
             %{
               "task" => "TK-B-1-1",
               "profile" => "deep_coding",
               "subject_kind" => "bin",
               "subject_key" => "B-1",
               "since" => "2026-11-17T12:00:00Z"
             } = first,
             %{"task" => "TK-B-2-1"}
           ] = Health.report(table)["queue"]

    assert is_binary(first["title"])

    # A Runtime takes the oldest: it no longer waits.
    L.advance(ctx, 1)
    assert {:polled, %{leases: [_]}} = WorkSource.poll({"mini", "ada"}, L.poll_input("mini"))
    assert [%{"task" => "TK-B-2-1"}] = Health.report(table)["queue"]
  end

  test "a parked poll removes its grant from the queue before it is answered" do
    dir = Path.join(System.tmp_dir!(), "health-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    table = health!()
    L.start(dir, health: table, poll_wait: 25_000)

    held = Task.async(fn -> WorkSource.poll({"mini", "ada"}, L.poll_input("mini")) end)

    AtlasTestAwait.until(
      fn ->
        {:current_stacktrace, stack} = Process.info(held.pid, :current_stacktrace)
        Enum.any?(stack, &match?({:gen, :do_call, _, _}, &1))
      end,
      wake: {:trace, AtlasFlow.Dispatch}
    )

    :sys.get_state(AtlasFlow.Dispatch)
    L.supervised_task("B-1", "ada")
    L.supervised_task("B-2", "ada", at: DateTime.add(L.epoch(), 60))
    :ok = AtlasFlow.Dispatch.resync()

    assert {:polled, %{leases: [%{work: %{work_key: "TK-B-1-1"}}]}} = Task.await(held)
    assert [%{"task" => "TK-B-2-1"}] = Health.report(table)["queue"]
  end

  test "boot restores held leases before publishing the queue, and a lost lease waits again" do
    dir = Path.join(System.tmp_dir!(), "health-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    table = health!()
    ctx = L.start(dir, health: table)

    L.supervised_task("B-1", "ada")
    L.supervised_task("B-2", "ada", at: DateTime.add(L.epoch(), 60))
    :ok = AtlasFlow.Dispatch.resync()
    assert {:polled, %{leases: [_]}} = WorkSource.poll({"mini", "ada"}, L.poll_input("mini"))

    :ok = stop_supervised(AtlasFlow.Dispatch)
    L.start_dispatch(ctx.clock, health: table)
    :sys.get_state(AtlasFlow.Dispatch)
    assert [%{"task" => "TK-B-2-1"}] = Health.report(table)["queue"]

    :ok = AtlasFlow.Dispatch.sweep()

    assert [%{"task" => "TK-B-1-1"}, %{"task" => "TK-B-2-1"}] =
             Health.report(table)["queue"]
  end

  test "queue stays unknown until leases recover after a failed boot read" do
    dir = Path.join(System.tmp_dir!(), "health-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    table = health!()
    ctx = L.start(dir, health: table)

    L.supervised_task("B-1", "ada")
    :ok = AtlasFlow.Dispatch.resync()

    assert {:polled, %{leases: [%{lease_id: lease}]}} =
             WorkSource.poll({"mini", "ada"}, L.poll_input("mini"))

    assert {:recorded, _} =
             WorkSource.report({"mini", "ada"}, %{
               lease_id: lease,
               revision: 1,
               report: %{state: :accepted}
             })

    assert {:recorded, _} =
             WorkSource.report({"mini", "ada"}, %{
               lease_id: lease,
               revision: 2,
               report: %{state: :started}
             })

    :ok = stop_supervised(AtlasFlow.Dispatch)
    read = {:block_read, "task", %{"plain" => true}}
    :ok = GenServer.call(FakeFacts, read)
    L.start_dispatch(ctx.clock, health: table)
    :sys.get_state(AtlasFlow.Dispatch)
    assert Health.report(table)["queue"] == nil

    :ok = AtlasFlow.Dispatch.resync()
    assert Health.report(table)["queue"] == nil
    assert {:polled, _} = WorkSource.poll({"mini", "ada"}, L.poll_input("mini", [lease], %{}))
    assert Health.report(table)["queue"] == nil

    :ok = GenServer.call(FakeFacts, put_elem(read, 0, :allow_read))
    :ok = AtlasFlow.Dispatch.sweep()
    assert Health.report(table)["queue"] == []
  end

  test "queue stays unknown until the ready set loads, including after lease recovery" do
    dir = Path.join(System.tmp_dir!(), "health-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    table = health!()
    ctx = L.start(dir, health: table)

    L.supervised_task("B-1", "ada")
    L.supervised_task("B-2", "ada", at: DateTime.add(L.epoch(), 60))
    :ok = AtlasFlow.Dispatch.resync()
    assert {:polled, %{leases: [_]}} = WorkSource.poll({"mini", "ada"}, L.poll_input("mini"))

    :ok = stop_supervised(AtlasFlow.Dispatch)
    runs_read = {:block_read, L.config()["kind"], %{"plain" => true}}
    leases_read = {:block_read, "task", %{"plain" => true}}
    :ok = GenServer.call(FakeFacts, runs_read)
    :ok = GenServer.call(FakeFacts, leases_read)
    L.start_dispatch(ctx.clock, health: table)
    :sys.get_state(AtlasFlow.Dispatch)
    assert Health.report(table)["queue"] == nil

    :ok = GenServer.call(FakeFacts, put_elem(leases_read, 0, :allow_read))
    :ok = AtlasFlow.Dispatch.sweep()
    assert Health.report(table)["queue"] == nil
    :ok = AtlasFlow.Dispatch.resync()
    assert Health.report(table)["queue"] == nil

    :ok = GenServer.call(FakeFacts, put_elem(runs_read, 0, :allow_read))
    :ok = AtlasFlow.Dispatch.resync()

    assert [%{"task" => "TK-B-1-1"}, %{"task" => "TK-B-2-1"}] =
             Health.report(table)["queue"]

    :ok = GenServer.call(FakeFacts, runs_read)
    :ok = AtlasFlow.Dispatch.resync()
    assert Health.report(table)["queue"] == nil
    :ok = GenServer.call(FakeFacts, put_elem(runs_read, 0, :allow_read))
    :ok = AtlasFlow.Dispatch.resync()

    assert [%{"task" => "TK-B-1-1"}, %{"task" => "TK-B-2-1"}] =
             Health.report(table)["queue"]
  end

  test "a failed boot ready read stays unknown when leases loaded at boot" do
    dir = Path.join(System.tmp_dir!(), "health-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    table = health!()
    ctx = L.start(dir, health: table)
    L.supervised_task("B-1", "ada")

    :ok = stop_supervised(AtlasFlow.Dispatch)
    runs_read = {:block_read, L.config()["kind"], %{"plain" => true}}
    :ok = GenServer.call(FakeFacts, runs_read)
    L.start_dispatch(ctx.clock, health: table)
    :sys.get_state(AtlasFlow.Dispatch)
    assert Health.report(table)["queue"] == nil

    :ok = GenServer.call(FakeFacts, put_elem(runs_read, 0, :allow_read))
    :ok = AtlasFlow.Dispatch.resync()
    assert [%{"task" => "TK-B-1-1"}] = Health.report(table)["queue"]
  end

  test "`_health` is answered over the Bus" do
    endpoint = "flow/health-#{System.unique_integer([:positive])}"
    table = health!(endpoint)
    Health.polled("mini", ~U[2026-11-23 10:00:00Z], %{}, table)
    :ok = AtlasBus.attach("tester-#{System.unique_integer([:positive])}")
    request = %{Envelope.new("request", "_health") | address: endpoint}
    :ok = AtlasBus.send(request, %{})
    id = request.id

    assert_receive {:atlas_bus, %Envelope{class: "answer", id: ^id}, answer}
    assert answer["runtimes"] == [%{"runtime" => "mini", "polled_at" => "2026-11-23T10:00:00Z"}]
    assert answer["queue"] == []
    assert answer["flow"]["due"] == nil
    assert is_binary(answer["at"])
  end

  test "a write without a table is dropped" do
    assert Health.polled("mini", DateTime.utc_now(), %{}, :no_such_health_table) == :ok
    assert Health.queue([], :no_such_health_table) == :ok
    assert Health.report(:no_such_health_table)["runtimes"] == []
  end
end
