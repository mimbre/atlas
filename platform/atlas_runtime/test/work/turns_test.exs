defmodule AtlasRuntime.Work.TurnsTest do
  # The Service-event → attempt table (AtlasRuntime.Work.Turns.outcome/2) and the request
  # ID derivation, row by row.
  use ExUnit.Case, async: true

  alias AtlasRuntime.Work.Turns

  defp attempt(stage \\ nil, reason \\ nil), do: %{cancel_stage: stage, cancel_reason: reason}

  defp outcome(turn, attempt \\ attempt()) do
    result = Turns.outcome(Map.put_new(turn, "id", "turn-0123456789abcdef"), attempt)
    {result.kind, result.reason, result.native_outcome, result.quiescent}
  end

  test "natural ends" do
    assert outcome(%{"state" => "finished", "result" => "ok"}) ==
             {:completed, nil, :finished, true}

    assert Turns.outcome(%{"state" => "finished", "result" => "ok"}, attempt()).answer == "ok"

    assert outcome(%{"state" => "failed", "error" => "{:codex_failed, 1, 1}"}) ==
             {:failed, nil, :failed, true}

    assert outcome(%{"state" => "failed", "error" => "{:claude_failed, 1, nil}", "quota" => %{}}) ==
             {:failed, "quota", :failed, true}

    # The helper died: crashed, and nothing proves its group gone yet.
    assert outcome(%{"state" => "failed", "error" => ":native_transport_closed"}) ==
             {:crashed, nil, :failed, false}
  end

  test "stops the core did not ask for are interruptions" do
    assert outcome(%{"state" => "stopped"}) == {:interrupted, nil, :stopped, true}
    assert outcome(%{"state" => "killed"}) == {:interrupted, nil, :killed, true}

    assert outcome(%{
             "state" => "failed",
             "recorded_state" => "running",
             "error" => "interrupted: ..."
           }) ==
             {:interrupted, nil, :failed, true}
  end

  test "a cancel the core asked for" do
    assert outcome(%{"state" => "stopped"}, attempt(:signalled, :cancel)) ==
             {:cancelled, "cancel", :stopped, true}

    assert outcome(%{"state" => "killed"}, attempt(:forced, :superseded)) ==
             {:cancelled, "superseded", :killed, true}

    assert outcome(%{"state" => "stopped"}, attempt(:signalled, :time_limit)) ==
             {:failed, "time_limit", :stopped, true}

    # A result before the signal wins; after it, the cancel does.
    assert outcome(%{"state" => "finished"}, attempt(:requested, :cancel)) ==
             {:completed, nil, :finished, true}

    assert outcome(%{"state" => "finished"}, attempt(:signalled, :cancel)) ==
             {:cancelled, "cancel", :finished, true}
  end

  test "a top-level model change fails the turn, whatever ended it" do
    changed = %{"first" => "a", "reported" => "b", "at" => "2026-11-16T00:00:00Z"}

    assert outcome(%{"state" => "stopped", "model_changed" => changed}) ==
             {:failed, "model_changed", :stopped, true}

    assert outcome(
             %{"state" => "stopped", "model_changed" => changed},
             attempt(:signalled, :cancel)
           ) ==
             {:failed, "model_changed", :stopped, true}
  end

  test "the answer is at most 8 KB, cut on a character" do
    long = String.duplicate("é", 5000)
    answer = Turns.outcome(%{"state" => "finished", "result" => long}, attempt()).answer
    assert byte_size(answer) <= 8192
    assert String.valid?(answer)
  end

  test "retryable is advice for crashed, interrupted, returned and quota failures" do
    assert Turns.retryable?(:crashed, nil)
    assert Turns.retryable?(:interrupted, nil)
    assert Turns.retryable?(:returned, nil)
    assert Turns.retryable?(:failed, "quota")
    refute Turns.retryable?(:failed, "time_limit")
    refute Turns.retryable?(:completed, nil)
    refute Turns.retryable?(:cancelled, "cancel")
  end

  test "the request ID: w and the first 63 hex digits of sha256(work_id:attempt)" do
    id = Turns.request_id("work-0123456789abcdef", 2)
    digest = :crypto.hash(:sha256, "work-0123456789abcdef:2") |> Base.encode16(case: :lower)
    assert id == "w" <> binary_part(digest, 0, 63)
    assert byte_size(id) == 64
    refute id == Turns.request_id("work-0123456789abcdef", 3)
  end
end
