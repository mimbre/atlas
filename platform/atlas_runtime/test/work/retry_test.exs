defmodule AtlasRuntime.Work.RetryTest do
  # D2 acceptance 5, for the local retry (Main's round 2; M2 A7: the executor has no retry
  # of its own): a retry is the next attempt's lease of the same work, so only an ended
  # attempt n has one, and n+1 waits until n is terminal and quiescent (I1).
  use ExUnit.Case, async: false

  import AtlasRuntime.WorkHarness
  alias AtlasRuntime.Boundary.Work, as: F

  @moduletag capture_log: true

  setup do
    %{bench: start!()}
  end

  test "n queued at the local source: nothing to retry yet, and it runs once", %{bench: bench} do
    busy = for n <- 1..2, do: submit!(bench, "hang #{n}")
    for work <- busy, do: await_launch(bench, work)
    waiting = submit!(bench, "complete waiting")

    assert %F.Outcome.Refused{reason: :invalid} = F.retry(client(), %{work_id: waiting.work_id})
    assert [%{attempt: 1, state: :buffered}] = work!(waiting.work_id).attempts

    for work <- busy, do: F.cancel(client(), %{work_id: work.work_id, mode: "force"})
    assert [%{state: :completed}] = await_state(waiting.work_id, :completed).attempts
    assert Enum.count(launches(bench), &(&1["goal"] == "complete waiting")) == 1
  end

  test "n live: refused and untouched; n+1 starts only once n is terminal and quiescent",
       %{bench: bench} do
    work = submit!(bench, "stubborn retried")
    await_launch(bench, work)

    # Running, then cancelling (n ignores the stop until the grace runs out): no n+1.
    assert %F.Outcome.Refused{reason: :conflict} = F.retry(client(), %{work_id: work.work_id})

    assert %F.Outcome.Cancelling{} =
             F.cancel(client(), %{work_id: work.work_id, mode: "graceful"})

    assert %F.Outcome.Refused{reason: :conflict} = F.retry(client(), %{work_id: work.work_id})
    assert [%{state: :cancelling}] = work!(work.work_id).attempts

    await_work(work.work_id, &match?([%{state: :cancelled, quiescent: true}], &1.attempts))

    # Terminal and quiescent: the retry is the next attempt, leased and started after n.
    assert %F.Outcome.Accepted{work: %{attempts: [_, %{attempt: 2, state: :buffered}]}} =
             F.retry(client(), %{work_id: work.work_id})

    done = await_launch(bench, work, 2)
    [first, second] = done.attempts
    assert first.state == :cancelled and first.quiescent
    assert DateTime.compare(second.timestamps.started_at, first.timestamps.ended_at) != :lt
    F.cancel(client(), %{work_id: work.work_id, mode: "force"})
    await_state(work.work_id, :cancelled)
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
