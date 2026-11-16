defmodule AtlasRuntime.Work.ModesTest do
  # S2 O2 acceptance 3, 4, 6, 7 and 8: pause, drain and resume (design §3.4, §13.1 Q5)
  # through I-K (`AtlasRuntime.Work.mode/0`, `set_mode/2`); work through its facade.
  use ExUnit.Case, async: false

  import AtlasRuntime.WorkHarness
  alias AtlasRuntime.Boundary.Work, as: F
  alias AtlasRuntime.Work

  @moduletag capture_log: true

  # Long enough for several heartbeats (100 ms), each of which tries to start buffered work.
  @bound 800

  setup do
    %{bench: start!(%{"slots" => ["s1"]})}
  end

  defp launched?(bench, goal), do: Enum.any?(launches(bench), &(&1["goal"] == goal))

  defp cancel_and_wait(work) do
    F.cancel(client(), %{work_id: work.work_id, mode: "force"})
    await_state(work.work_id, :cancelled)
  end

  test "pause with a buffered work and a free slot: nothing starts", %{bench: bench} do
    first = submit!(bench, "hang first")
    await_launch(bench, first)
    second = submit!(bench, "complete second")
    assert work!(second.work_id).state == :buffered

    assert Work.set_mode(:paused, "local:op") == :paused
    assert Work.mode() == :paused
    cancel_and_wait(first)

    # The slot is free and the attempt waits in the buffer; no heartbeat starts it.
    Process.sleep(@bound)
    refute launched?(bench, "complete second")
    assert work!(second.work_id).state == :buffered

    assert %F.Outcome.Capacity{accepting: false, retry_after: 60, slots: %{free: 1}} =
             F.capacity(client())

    # Resumed, it starts.
    assert Work.set_mode(:open, "local:op") == :open
    await_launch(bench, second)
  end

  test "pause with a running turn: it completes", %{bench: bench} do
    File.write!(Path.join(bench.dir, "gate"), "")
    work = submit!(bench, "wait gate")
    await_launch(bench, work)

    assert Work.set_mode(:paused, "local:op") == :paused
    File.rm!(Path.join(bench.dir, "gate"))

    assert [%{state: :completed}] = await_state(work.work_id, :completed).attempts
  end

  test "submit and retry while paused or draining: at_capacity not_accepting", %{bench: bench} do
    done = submit!(bench, "complete before")
    await_state(done.work_id, :completed)

    for mode <- [:paused, :draining] do
      assert Work.set_mode(mode, "local:op") == mode

      for answer <- [
            F.submit(client(), request(bench, "complete refused #{mode}")),
            F.retry(client(), %{work_id: done.work_id})
          ] do
        assert %F.Outcome.AtCapacity{
                 reason: :not_accepting,
                 retry_after: 60,
                 capacity: %F.Capacity{accepting: false, retry_after: 60}
               } = answer
      end
    end

    assert [_] = work!(done.work_id).attempts
    refute launched?(bench, "complete refused paused")
    refute launched?(bench, "complete refused draining")
  end

  describe "transitions" do
    test "pause then drain returns the buffer", %{bench: bench} do
      first = submit!(bench, "hang first")
      await_launch(bench, first)
      second = submit!(bench, "complete second")

      assert Work.set_mode(:paused, "local:op") == :paused
      assert work!(second.work_id).state == :buffered

      assert Work.set_mode(:draining, "local:op") == :draining
      assert [%{state: :returned}] = work!(second.work_id).attempts
      assert work!(first.work_id).state == :running
      cancel_and_wait(first)
    end

    test "draining then pause gives paused", %{bench: _bench} do
      assert Work.set_mode(:draining, "local:op") == :draining
      assert Work.set_mode(:paused, "local:op") == :paused
      assert Work.mode() == :paused
    end

    test "draining stays draining with an empty buffer, also once running work ends",
         %{bench: bench} do
      File.write!(Path.join(bench.dir, "gate"), "")
      work = submit!(bench, "wait gate")
      await_launch(bench, work)

      assert Work.set_mode(:draining, "local:op") == :draining
      File.rm!(Path.join(bench.dir, "gate"))
      await_state(work.work_id, :completed)

      Process.sleep(@bound)
      assert Work.mode() == :draining
      assert %F.Outcome.Capacity{accepting: false} = F.capacity(client())
    end

    test "drain twice: the same mode, and no work changes on the repeat", %{bench: bench} do
      first = submit!(bench, "hang first")
      await_launch(bench, first)
      second = submit!(bench, "complete second")

      assert Work.set_mode(:draining, "local:op") == :draining
      returned = work!(second.work_id)
      assert returned.state == :returned

      mode_bytes = File.read!(Path.join(bench.dir, "mode.json"))

      assert F.subscribe(client(), %{}) == %F.Outcome.Subscribed{}
      # Past the millisecond of `changed_at`, so a rewrite on the repeat would differ.
      Process.sleep(5)
      assert Work.set_mode(:draining, "local:op") == :draining

      assert [] = for(%F.WorkChanged{} = n <- notifications(300), do: n)
      assert work!(second.work_id).revision == returned.revision
      assert File.read!(Path.join(bench.dir, "mode.json")) == mode_bytes
      cancel_and_wait(first)
    end
  end

  test "resume from paused emits capacity_available once; resume while open none",
       %{bench: _bench} do
    assert F.subscribe(client(), %{}) == %F.Outcome.Subscribed{}

    assert Work.set_mode(:paused, "local:op") == :paused
    assert Work.set_mode(:open, "local:op") == :open

    assert [%F.CapacityAvailable{capacity: %F.Capacity{accepting: true}}] =
             for(%F.CapacityAvailable{} = n <- notifications(300), do: n)

    assert Work.set_mode(:open, "local:op") == :open
    assert [] = for(%F.CapacityAvailable{} = n <- notifications(300), do: n)
  end
end
