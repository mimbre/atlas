defmodule AtlasRuntime.Work.DrainTest do
  # S2 O2 acceptance 1, 2, 5 and 9: a drain returns buffered work, and only buffered work
  # (design §5, §13.1 Q5), persisted before the answer (I2). Since the cut-over (M2 A7)
  # work reaches the executor only as a lease, so what a drain returns is the leases it
  # accepted and has not started (decision §6.3 S2). The executor is driven here as the
  # local source's puller drives it (`accept_lease/3`, `release_lease/1`); a work still
  # queued at the local source is the source's, never returned (`modes_test`).
  use ExUnit.Case, async: false

  import AtlasRuntime.WorkHarness
  alias AtlasRuntime.Boundary.Work, as: F
  alias AtlasRuntime.Work
  alias AtlasRuntime.Work.Store

  @moduletag capture_log: true

  setup do
    %{bench: start!(%{"slots" => ["s1"], "buffer_size" => 2}, local: false)}
  end

  # A lease of the local source, as its puller hands it over: the work's local id and its
  # request (Deviation 1), attempt `n`.
  defp lease!(bench, goal, n \\ 1, work_id \\ nil) do
    work_id = work_id || "work-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    lease_id = "local-#{work_id}-#{n}"
    _offer = Work.offer("local")

    work = %{work_key: work_id, request: F.WorkRequest.new!(request(bench, goal))}
    work = if n > 1, do: Map.put(work, :attempt, n), else: work

    assert {:accepted, ^work_id} =
             Work.accept_lease("local", %{lease_id: lease_id, work: work})

    :ok = Work.offer_done("local", 1)
    work_id
  end

  defp started!(bench, goal) do
    id = lease!(bench, goal)
    :released = Work.release_lease(id)
    await_launch(bench, work!(id))
  end

  # One running work holds the only slot; two more leases are accepted and wait unstarted.
  defp full(bench) do
    File.write!(Path.join(bench.dir, "gate"), "")
    running = started!(bench, "wait gate")
    held = for goal <- ["complete one", "complete two"], do: lease!(bench, goal)
    for id <- held, do: assert(work!(id).state == :buffered)
    {running, held}
  end

  test "two accepted, unstarted leases are returned, never started, on disk before the answer",
       %{bench: bench} do
    {_running, held} = full(bench)

    # Every record the core writes is reported from inside it, as it is written: a write
    # before the answer arrives before the answer.
    test = self()
    stop_work()
    start_work!(bench, after_write: &send(test, {:written, &1}))

    assert Work.set_mode(:draining, "local:op") == :draining

    for id <- held do
      assert_received {:written, %{work_id: ^id} = record}
      assert %{state: :returned} = List.last(record.attempts)

      assert %{state: :returned, quiescent: true, result: result} =
               List.last(Store.read_work(bench.dir, id).attempts)

      assert %{kind: :returned, never_started: true, retryable: true} = result

      assert [%{state: :returned, result: %{never_started: true, retryable: true}}] =
               work!(id).attempts
    end
  end

  test "one work_changed per returned work", %{bench: bench} do
    {_running, held} = full(bench)
    assert F.subscribe(client(), %{}) == %F.Outcome.Subscribed{}

    assert Work.set_mode(:draining, "local:op") == :draining

    changes =
      for %F.WorkChanged{state: :returned} = n <- notifications(heartbeats: 3), do: n.work_id

    assert Enum.sort(changes) == Enum.sort(held)
  end

  test "a returned attempt never starts, also after resume and its source's accept",
       %{bench: bench} do
    {running, held} = full(bench)
    assert Work.set_mode(:draining, "local:op") == :draining
    assert Work.set_mode(:open, "local:op") == :open
    for id <- held, do: Work.release_lease(id)

    File.rm!(Path.join(bench.dir, "gate"))
    await_state(running.work_id, :completed)

    # The slot is free and the Runtime open: a new lease starts, the returned ones do not.
    later = started!(bench, "complete later")
    await_state(later.work_id, :completed)
    heartbeats(8)

    goals = Enum.map(launches(bench), & &1["goal"])
    assert goals == ["wait gate", "complete later"]
    for id <- held, do: assert([%{state: :returned}] = work!(id).attempts)
  end

  test "drain with a running turn: it finishes, and the unstarted leases are returned",
       %{bench: bench} do
    {running, held} = full(bench)
    assert Work.set_mode(:draining, "local:op") == :draining

    for id <- held, do: assert(work!(id).state == :returned)
    assert work!(running.work_id).state == :running

    File.rm!(Path.join(bench.dir, "gate"))
    assert [%{state: :completed}] = await_state(running.work_id, :completed).attempts
    assert Work.mode() == :draining
  end

  test "a returned work's next attempt (its source's retry lease) is accepted, and runs",
       %{bench: bench} do
    {running, [returned | _]} = full(bench)
    assert Work.set_mode(:draining, "local:op") == :draining
    File.rm!(Path.join(bench.dir, "gate"))
    await_state(running.work_id, :completed)
    assert Work.set_mode(:open, "local:op") == :open

    ^returned = lease!(bench, "complete one", 2, returned)

    assert [%{state: :returned, result: %{retryable: true}}, %{state: :buffered}] =
             work!(returned).attempts

    :released = Work.release_lease(returned)
    assert [_, %{state: :completed}] = await_state(returned, :completed).attempts
    assert Enum.count(launches(bench), &(&1["goal"] == "complete one")) == 1
  end
end
