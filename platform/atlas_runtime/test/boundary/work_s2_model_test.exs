defmodule AtlasRuntime.Boundary.WorkS2ModelTest do
  @moduledoc """
  S2a's additions to the private work model as callers see them: a released attempt's
  `released_by`/`released_at` stay private (§13.1 Q8), and a turn ended by a Runtime
  stop keeps its `runtime_stop` reason at the boundary (Q9).
  """
  use ExUnit.Case, async: true

  alias AtlasRuntime.Boundary.Work, as: B
  alias AtlasRuntime.Model.Work, as: M
  alias AtlasRuntime.Work.Translation

  @t ~U[2026-11-16 09:00:00.000000Z]

  defp attempt(fields) do
    M.Attempt.new!(
      Keyword.merge(
        [
          attempt: 1,
          state: :interrupted,
          timestamps: M.Timestamps.new!(received_at: @t, accepted_at: @t, ended_at: @t),
          quiescent: true
        ],
        fields
      )
    )
  end

  test "an attempt's release fields do not reach the boundary attempt" do
    released = attempt(released_by: "local:op", released_at: @t)

    assert {:ok, %B.Attempt{attempt: 1, state: :interrupted} = public} =
             B.from_model(released)

    refute Map.has_key?(Map.from_struct(public), :released_by)
    refute Map.has_key?(Map.from_struct(public), :released_at)
  end

  test "a turn ended by a Runtime stop is interrupted with reason runtime_stop" do
    result =
      M.Result.new!(
        kind: :interrupted,
        reason: "runtime_stop",
        retryable: true,
        never_started: false
      )

    record =
      M.WorkRecord.new!(
        work_id: "work-1",
        client: "local:test",
        idempotency_key: "work-1",
        revision: 1,
        sequence: 1,
        request:
          M.Request.new!(
            title: "t",
            instructions: "i",
            profile: "p",
            cost_class: :standard,
            workspace: M.Folder.new!(path: "/f", permissions: :read_only)
          ),
        attempts: [attempt(result: result, released_by: "local:op", released_at: @t)]
      )

    assert %B.Work{state: :interrupted, attempts: [%B.Attempt{result: public}]} =
             Translation.from_model(record)

    assert %B.Result{kind: :interrupted, reason: :runtime_stop, retryable: true} = public
  end
end
