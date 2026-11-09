defmodule AtlasRuntime.Work.RetryTest do
  # D2 acceptance 5: every row of the design §3.2 retry table; n+1 waits until n is
  # terminal and quiescent (I1).
  use ExUnit.Case, async: false

  import AtlasRuntime.WorkHarness
  alias AtlasRuntime.Boundary.Work, as: F

  @moduletag capture_log: true

  setup do
    %{bench: start!()}
  end

  test "n buffered: n is cancelled never started and n+1 takes its place", %{bench: bench} do
    busy = for n <- 1..2, do: submit!(bench, "hang #{n}")
    for work <- busy, do: await_launch(bench, work)
    waiting = submit!(bench, "complete waiting")

    # The place is reused: no capacity check even though the Runtime is full.
    assert %F.Outcome.AtCapacity{reason: :full} =
             F.submit(client(), request(bench, "complete other"))

    assert %F.Outcome.Accepted{work: %{attempts: [first, second], state: :buffered}} =
             F.retry(client(), %{work_id: waiting.work_id})

    assert first.state == :cancelled
    assert first.result.never_started
    assert first.cancel_reason == :superseded
    assert second.state == :buffered
    for work <- busy, do: F.cancel(client(), %{work_id: work.work_id, mode: "force"})
    assert [_, %{state: :completed}] = await_state(waiting.work_id, :completed).attempts
    assert Enum.count(launches(bench), &(&1["goal"] == "complete waiting")) == 1
  end

  test "n running: n is superseded, and n+1 starts only once n is terminal and quiescent",
       %{bench: bench} do
    work = submit!(bench, "stubborn retried")
    await_launch(bench, work)

    assert %F.Outcome.Accepted{work: %{attempts: [first, second]}} =
             F.retry(client(), %{work_id: work.work_id})

    # A slot is free, yet n+1 waits: n ignores the stop until the grace runs out.
    assert first.state == :cancelling
    assert first.cancel_reason == :superseded
    assert second.state == :buffered
    assert [%{state: :cancelling}, %{state: :buffered}] = work!(work.work_id).attempts

    done = await_launch(bench, work, 2)
    [first, second] = done.attempts
    assert first.state == :cancelled and first.quiescent
    assert first.result.reason == :superseded
    assert DateTime.compare(second.timestamps.started_at, first.timestamps.ended_at) != :lt
    F.cancel(client(), %{work_id: work.work_id, mode: "force"})
    await_state(work.work_id, :cancelled)
  end

  test "n running while full: at_capacity, and n is untouched", %{bench: bench} do
    busy = for n <- 1..2, do: submit!(bench, "hang full #{n}")
    for work <- busy, do: await_launch(bench, work)
    submit!(bench, "complete buffered")
    [target | _] = busy

    assert %F.Outcome.AtCapacity{reason: :full} = F.retry(client(), %{work_id: target.work_id})
    assert [%{state: :running}] = work!(target.work_id).attempts
    for work <- busy, do: F.cancel(client(), %{work_id: work.work_id, mode: "force"})
  end

  test "n terminal, whatever its kind: accepted, and n+1 runs", %{bench: bench} do
    work = submit!(bench, "complete twice")
    await_state(work.work_id, :completed)

    assert %F.Outcome.Accepted{work: %{attempts: [_, %{attempt: 2, state: :buffered}]}} =
             F.retry(client(), %{work_id: work.work_id})

    assert [%{state: :completed}, %{state: :completed}] =
             await_work(work.work_id, &match?([_, %{state: :completed}], &1.attempts)).attempts

    assert [%{"resumed" => false}, %{"resumed" => false}] = launches(bench)
    assert %F.Outcome.NotFound{} = F.retry(client(), %{work_id: "work-0000000000000000"})
  end

  test "resume continues the conversation on the same slot", %{bench: bench} do
    work = submit!(bench, "complete then resume")

    [%{slot: slot, provenance: %{conversation_id: session}}] =
      await_state(work.work_id, :completed).attempts

    assert is_binary(session)

    assert %F.Outcome.Accepted{} = F.retry(client(), %{work_id: work.work_id, resume: true})

    [first, second] =
      await_work(work.work_id, &match?([_, %{state: :completed}], &1.attempts)).attempts

    assert second.slot == slot
    assert second.provenance.continues == first.turn_id
    assert second.provenance.selection.reason == :continuation

    assert [%{"resumed" => false}, %{"resumed" => true, "session_id" => ^session}] =
             launches(bench)
  end
end
