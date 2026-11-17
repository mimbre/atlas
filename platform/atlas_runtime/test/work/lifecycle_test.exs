defmodule AtlasRuntime.Work.LifecycleTest do
  # Design §13 S1d acceptance 1–2 (D2): submit → accepted → work_changed → completed,
  # write-ahead, and idempotent submission, through the facade.
  use ExUnit.Case, async: false

  import AtlasRuntime.WorkHarness
  alias AtlasRuntime.Boundary.Work, as: F
  alias AtlasRuntime.Work.Turns
  alias AtlasRuntime.WorkHarness.SlowStart

  @moduletag capture_log: true

  defmodule LateAnswer do
    @moduledoc false
    # In front of the Service: the first start runs at once, but its answer comes only after
    # its turn has ended and the core has given up waiting (its start_timeout_ms), so the
    # core reads the turn's end events before it learns the turn ID.
    use GenServer

    @impl true
    def init({service, dir, hold?}), do: {:ok, {service, dir, hold?}}

    @impl true
    def handle_call(%{"command" => "start"} = request, {core, _} = from, {service, dir, true}) do
      # Answered from a process of its own: the core's other calls (its reads) still pass
      # through while the answer waits on the core.
      spawn_link(fn ->
        {%{"turn_id" => turn}, _} = reply = GenServer.call(service, request, :infinity)

        # The turn ends: the Service records it. The core waits on this call, so the wait
        # wakes on what the Service handles, not on the core's notifications.
        AtlasTestAwait.until(fn -> (t = Turns.read_turn(dir, turn)) && not Turns.live?(t) end,
          wake: {:trace, service}
        )

        # The core gives up waiting: it answers a `:sys` request only once it has.
        :sys.get_state(core, AtlasTestAwait.cap())
        GenServer.reply(from, reply)
      end)

      {:noreply, {service, dir, false}}
    end

    def handle_call(request, _from, {service, _, _} = state),
      do: {:reply, GenServer.call(service, request, :infinity), state}
  end

  setup do
    %{bench: start!()}
  end

  test "a start the Service did not answer in time stays on its slot and gets its turn there",
       %{bench: bench} do
    stop_work()
    {:ok, slow} = GenServer.start(SlowStart, {bench.service, self()})
    on_exit(fn -> Process.exit(slow, :kill) end)
    start_work!(%{bench | service: slow}, heartbeat_ms: 60_000, start_timeout_ms: 1_000)

    first = submit!(bench, "complete though slow to start")
    assert_receive :start_held, 5_000
    # The core gives up waiting (start_timeout_ms); then another dispatch while the first
    # start is still held.
    core_idle()
    second = submit!(bench, "complete beside it")
    send(slow, :go)

    assert [attempt] = await_state(first.work_id, :completed).attempts
    assert attempt.slot == "s1"
    assert [%{slot: "s2"}] = await_state(second.work_id, :completed).attempts
    assert Enum.count(launches(bench), &(&1["goal"] == first.request.instructions)) == 1
  end

  test "a start answered only after its turn ended still ends the attempt with that turn",
       %{bench: bench} do
    stop_work()
    {:ok, late} = GenServer.start(LateAnswer, {bench.service, bench.dir, true})
    on_exit(fn -> Process.exit(late, :kill) end)
    start_work!(%{bench | service: late}, heartbeat_ms: 60_000, start_timeout_ms: 1_000)

    work = submit!(bench, "complete answered late")

    assert [%{slot: "s1", turn_id: turn} = attempt] =
             await_state(work.work_id, :completed).attempts

    assert attempt.result.answer == "done: complete answered late"
    assert turn(bench, turn)["state"] == "finished"
    assert Enum.count(launches(bench), &(&1["goal"] == "complete answered late")) == 1
  end

  test "a submitted work runs to completed, announcing each change with a rising revision",
       %{bench: bench} do
    assert %F.Outcome.Subscribed{} = F.subscribe(client(), %{})
    work = submit!(bench, "complete the first", %{client_key: "first"})
    assert work.revision == 1
    assert [%F.Attempt{attempt: 1, state: :buffered}] = work.attempts

    done = await_state(work.work_id, :completed)
    [attempt] = done.attempts
    assert attempt.quiescent
    assert attempt.slot == "s1"
    assert attempt.result.kind == :completed
    assert attempt.result.native_outcome == :finished
    assert attempt.result.answer == "done: complete the first"
    assert attempt.result.log.ref == attempt.turn_id

    assert %{started_at: %DateTime{}, running_at: %DateTime{}, ended_at: %DateTime{}} =
             attempt.timestamps

    assert attempt.provenance.harness == "codex"
    assert attempt.provenance.configured_model == "gpt-test"
    assert attempt.provenance.slot == "s1"
    assert attempt.provenance.selection.profile == "light_work"
    assert attempt.provenance.selection.reason == :preferred
    assert attempt.provenance.turn_id == attempt.turn_id
    assert done.idempotency_key == "first"

    changes =
      for %F.WorkChanged{work_id: id} = change <- notifications(heartbeats: 2),
          id == work.work_id,
          do: change

    assert Enum.map(changes, & &1.revision) == Enum.to_list(1..done.revision)

    assert changes
           |> Enum.map(& &1.sequence)
           |> Enum.chunk_every(2, 1, :discard)
           |> Enum.all?(fn [a, b] -> b > a end)

    assert List.last(changes).state == :completed
    assert [%{"goal" => "complete the first", "resumed" => false}] = launches(bench)
  end

  test "a work is persisted before the answer mentions it: a crash between the two loses nothing",
       %{bench: bench} do
    stop_all()
    service = start_service!(bench)
    bench = %{bench | service: service}

    # The core dies right after writing the new record, before it answers or notifies.
    crash = fn record -> if record.revision == 1, do: exit(:crash_after_write) end
    start_work!(bench, after_write: crash)

    assert {:crash_after_write, _} =
             catch_exit(
               F.submit(
                 client(),
                 request(bench, "complete after a crash", %{client_key: "crash"})
               )
             )

    # Restarted, the core has the work it never answered for, and runs it once.
    start_work!(bench)
    assert %F.Outcome.Found{work: work} = F.find_work(client(), %{client_key: "crash"})
    assert await_state(work.work_id, :completed).attempts |> length() == 1
    assert [%{"goal" => "complete after a crash"}] = launches(bench)

    # Submitting again with the key is safe: the same work, not a second one.
    assert %F.Outcome.Existing{work: %{work_id: id}} =
             F.submit(client(), request(bench, "complete after a crash", %{client_key: "crash"}))

    assert id == work.work_id
  end

  test "the same client and key give the existing work; another request under it is a conflict",
       %{bench: bench} do
    first = submit!(bench, "complete keyed", %{client_key: "k1"})

    assert %F.Outcome.Existing{work: again} =
             F.submit(client(), request(bench, "complete keyed", %{client_key: "k1"}))

    assert again.work_id == first.work_id

    assert %F.Outcome.Refused{reason: :conflict} =
             F.submit(client(), request(bench, "complete something else", %{client_key: "k1"}))

    # Keys are per client: another client's same key is its own work.
    other = submit!(bench, "complete keyed", %{client_key: "k1"}, client("c2"))
    refute other.work_id == first.work_id
    await_state(first.work_id, :completed)
    await_state(other.work_id, :completed, client("c2"))
    assert length(launches(bench)) == 2
  end

  test "a request the contract refuses never becomes work", %{bench: bench} do
    assert %F.Outcome.Refused{reason: :not_permitted} =
             F.submit(client(), request(bench, "complete", %{slot: "s1"}))

    assert %F.Outcome.Refused{reason: :invalid} =
             F.submit(client("c1", [:choose_slot]), request(bench, "complete", %{slot: "s9"}))

    assert %F.Outcome.Refused{reason: :unsupported_workspace} =
             F.submit(
               client(),
               request(bench, "complete", %{
                 workspace: %{
                   kind: "repository",
                   url: "https://example.invalid/r.git",
                   branch: "task/x",
                   base: "main"
                 }
               })
             )

    assert %F.Outcome.Refused{reason: :policy_forbids} =
             F.submit(client(), request(bench, "complete", %{profile: "deep_coding"}))

    assert %F.Outcome.Refused{reason: :policy_forbids} =
             F.submit(client(), request(bench, "complete", %{cost_class: "high"}))

    assert %F.Outcome.Refused{reason: :invalid} =
             F.submit(client(), Map.put(request(bench, "complete"), :colour, "blue"))

    assert %F.Outcome.Works{works: []} = F.list_work(client(), %{})
    assert launches(bench) == []
  end

  test "a named slot runs there", %{bench: bench} do
    work = submit!(bench, "complete on s2", %{slot: "s2"}, client("c1", [:choose_slot]))
    assert [%{slot: "s2"}] = await_state(work.work_id, :completed).attempts
  end
end
