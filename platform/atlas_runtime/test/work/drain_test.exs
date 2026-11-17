defmodule AtlasRuntime.Work.DrainTest do
  # S2 O2 acceptance 1, 2, 5 and 9: a drain returns buffered work, and only buffered work
  # (design §5, §13.1 Q5), persisted before the answer (I2).
  use ExUnit.Case, async: false

  import AtlasRuntime.WorkHarness
  alias AtlasRuntime.Boundary.Work, as: F
  alias AtlasRuntime.Work
  alias AtlasRuntime.Work.Store

  @moduletag capture_log: true

  @bound 800

  setup do
    %{bench: start!(%{"slots" => ["s1"], "buffer_size" => 2})}
  end

  # One running work holds the only slot; two more wait in the buffer.
  defp full(bench) do
    File.write!(Path.join(bench.dir, "gate"), "")
    running = submit!(bench, "wait gate")
    await_launch(bench, running)
    buffered = for goal <- ["complete one", "complete two"], do: submit!(bench, goal)
    for work <- buffered, do: assert(work!(work.work_id).state == :buffered)
    {running, buffered}
  end

  test "two buffered works are returned, never started, on disk before the answer",
       %{bench: bench} do
    {_running, buffered} = full(bench)

    # Every record the core writes is reported from inside it, as it is written: a write
    # before the answer arrives before the answer.
    test = self()
    stop_work()
    start_work!(bench, after_write: &send(test, {:written, &1}))

    assert Work.set_mode(:draining, "local:op") == :draining

    for work <- buffered do
      id = work.work_id
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
    {_running, buffered} = full(bench)
    assert F.subscribe(client(), %{}) == %F.Outcome.Subscribed{}

    assert Work.set_mode(:draining, "local:op") == :draining

    changes = for %F.WorkChanged{state: :returned} = n <- notifications(300), do: n.work_id
    assert Enum.sort(changes) == Enum.sort(Enum.map(buffered, & &1.work_id))
  end

  test "a returned attempt never starts, also after resume", %{bench: bench} do
    {running, buffered} = full(bench)
    assert Work.set_mode(:draining, "local:op") == :draining
    assert Work.set_mode(:open, "local:op") == :open

    File.rm!(Path.join(bench.dir, "gate"))
    await_state(running.work_id, :completed)

    # The slot is free and the Runtime open: a new work starts, the returned ones do not.
    later = submit!(bench, "complete later")
    await_state(later.work_id, :completed)
    Process.sleep(@bound)

    goals = Enum.map(launches(bench), & &1["goal"])
    assert goals == ["wait gate", "complete later"]
    for work <- buffered, do: assert([%{state: :returned}] = work!(work.work_id).attempts)
  end

  test "drain with a running turn: it finishes, and the buffer is returned", %{bench: bench} do
    {running, buffered} = full(bench)
    assert Work.set_mode(:draining, "local:op") == :draining

    for work <- buffered, do: assert(work!(work.work_id).state == :returned)
    assert work!(running.work_id).state == :running

    File.rm!(Path.join(bench.dir, "gate"))
    assert [%{state: :completed}] = await_state(running.work_id, :completed).attempts
    assert Work.mode() == :draining
  end

  test "retry of a returned work is accepted, and the work runs", %{bench: bench} do
    {running, [returned | _]} = full(bench)
    assert Work.set_mode(:draining, "local:op") == :draining
    File.rm!(Path.join(bench.dir, "gate"))
    await_state(running.work_id, :completed)
    assert Work.set_mode(:open, "local:op") == :open

    assert %F.Outcome.Accepted{work: work} = F.retry(client(), %{work_id: returned.work_id})
    assert [%{state: :returned, result: %{retryable: true}}, %{state: :buffered}] = work.attempts

    assert [_, %{state: :completed}] = await_state(returned.work_id, :completed).attempts
    assert Enum.count(launches(bench), &(&1["goal"] == "complete one")) == 1
  end
end
