defmodule AtlasFlow.Runtime.RecordsTest do
  # Plan 2026-11-17 §6 F1.6: from each work snapshot the task fact is updated and one
  # task_attempt is written per attempt, with provenance, never overwriting an earlier one.
  use ExUnit.Case, async: false

  alias AtlasFlow.FakeFacts
  alias AtlasFlow.Runtime.Records

  @task "TK-PK-7-1"
  @machinery "mac-mini"

  setup do
    start_supervised!(FakeFacts)
    :ok = AtlasBus.attach("flow")

    # The task's intent, as the task activity (F1.3) writes it before it submits.
    FakeFacts.put("task", %{
      "key" => @task,
      "version" => 1,
      "values" => %{"kind" => "author", "client_key" => @task, "state" => "submitted"}
    })

    :ok
  end

  defp provenance(n, overrides) do
    Map.merge(
      %{
        "executor_kind" => "agent",
        "provider" => "anthropic",
        "harness" => "claude",
        "harness_version" => "2.1.#{n}",
        "runtime_build" => "rt-1",
        "machine" => "mac-mini",
        "slot" => "slot-#{n}",
        "configured_model" => "claude-opus-5-5",
        "reported_model" => "claude-opus-5-5",
        "selection" => %{
          "profile" => "deep_coding",
          "policy_version" => 3,
          "reason" => if(n == 1, do: "preferred", else: "fallback"),
          "skipped" => []
        },
        "conversation_id" => "conv-#{n}",
        "turn_id" => "turn-#{n}",
        "continues" => nil,
        "started_at" => "2026-11-17T10:0#{n}:00Z",
        "ended_at" => "2026-11-17T10:0#{n}:30Z"
      },
      overrides
    )
  end

  defp attempt(n, state, opts \\ []) do
    p = provenance(n, Keyword.get(opts, :provenance, %{}))

    base = %{
      "attempt" => n,
      "state" => state,
      "slot" => "slot-#{n}",
      "turn_id" => "turn-#{n}",
      "provenance" => p,
      "timestamps" => %{"started_at" => p["started_at"]},
      "quiescent" => state != "running"
    }

    case Keyword.get(opts, :result) do
      nil -> base
      result -> Map.put(base, "result", result)
    end
  end

  defp work(revision, attempts),
    do: %{
      "work_id" => "w-42",
      "client_key" => @task,
      "revision" => revision,
      "state" => List.last(attempts)["state"],
      "attempts" => attempts
    }

  @crashed %{"kind" => "crashed", "retryable" => true}
  @completed %{
    "kind" => "completed",
    "answer" => "Done.",
    "work_product" => %{
      "frozen" => %{"fingerprints" => [%{"root" => "atlas", "fingerprint" => "csf_abc"}]},
      "check" => %{
        "command" => ["bin/check"],
        "exit_status" => 0,
        "timed_out" => false,
        "output" => %{"tail" => "ok", "complete" => true}
      }
    }
  }

  defp ta(n), do: FakeFacts.get("task_attempt", Records.attempt_key(@task, n))
  defp task, do: FakeFacts.get("task", @task)

  test "two attempts become two task_attempts, each with its own provenance" do
    first = attempt(1, "crashed", result: @crashed)

    assert {:ok, %{attempts: %{1 => :created}}} =
             Records.record(@task, @machinery, work(3, [first]))

    second = attempt(2, "completed", result: @completed)

    assert {:ok, %{attempts: %{1 => :kept, 2 => :created}, task: :changed}} =
             Records.record(@task, @machinery, work(7, [first, second]))

    assert %{"values" => one, "links" => links_one} = ta(1)
    assert %{"values" => two, "links" => links_two} = ta(2)
    assert Records.attempt_key(@task, 1) == "TA-TK-PK-7-1-1"

    for {values, links, n} <- [{one, links_one, 1}, {two, links_two, 2}] do
      assert links == %{"attempt_of" => [@task], "ran_on" => [@machinery]}

      assert values == %{
               "turn_id" => "turn-#{n}",
               "state" => if(n == 1, do: "crashed", else: "completed"),
               "result_kind" => if(n == 1, do: "crashed", else: "completed"),
               "provider" => "anthropic",
               "harness" => "claude",
               "harness_version" => "2.1.#{n}",
               "configured_model" => "claude-opus-5-5",
               "reported_model" => "claude-opus-5-5",
               "selection_reason" => if(n == 1, do: "preferred", else: "fallback"),
               "conversation_id" => "conv-#{n}",
               "machine" => "mac-mini",
               "slot" => "slot-#{n}",
               "started_at" => "2026-11-17T10:0#{n}:00Z",
               "ended_at" => "2026-11-17T10:0#{n}:30Z"
             }
    end

    # The task: the work, its current attempt and that attempt's result; its own state and
    # intent untouched.
    assert %{"values" => values} = task()

    assert values == %{
             "kind" => "author",
             "client_key" => @task,
             "state" => "submitted",
             "work_id" => "w-42",
             "attempt" => 2,
             "result_kind" => "completed",
             "answer" => "Done.",
             "check_exit_status" => 0,
             "check_output_tail" => "ok",
             "result_fingerprints" => ~s([{"fingerprint":"csf_abc","root":"atlas"}])
           }
  end

  test "a reported model that differs from the configured one is kept" do
    differs = %{"configured_model" => "claude-opus-5-5", "reported_model" => "claude-sonnet-5-5"}

    # Running, before the harness reported a model.
    running = attempt(1, "running", provenance: %{"reported_model" => nil})

    assert {:ok, %{attempts: %{1 => :created}}} =
             Records.record(@task, @machinery, work(1, [running]))

    refute Map.has_key?(ta(1)["values"], "reported_model")

    done = attempt(1, "completed", provenance: differs, result: @completed)

    assert {:ok, %{attempts: %{1 => :changed}}} =
             Records.record(@task, @machinery, work(2, [done]))

    assert %{"configured_model" => "claude-opus-5-5", "reported_model" => "claude-sonnet-5-5"} =
             ta(1)["values"]
  end

  test "an earlier attempt's record is never overwritten" do
    first = attempt(1, "crashed", result: @crashed)
    {:ok, _} = Records.record(@task, @machinery, work(3, [first]))
    recorded = ta(1)

    # A later snapshot that says something else about attempt 1 changes nothing of it.
    altered =
      attempt(1, "failed",
        provenance: %{"reported_model" => "other", "harness_version" => "9.9"},
        result: %{"kind" => "failed", "reason" => "launch"}
      )

    second = attempt(2, "running")

    assert {:ok, %{attempts: %{1 => :kept, 2 => :created}}} =
             Records.record(@task, @machinery, work(5, [altered, second]))

    assert ta(1) == recorded
    refute Enum.any?(FakeFacts.sent(), &(&1["key"] == recorded["key"] and &1["op"] != "create"))
  end

  test "a running attempt's record only gains: progress moves on, provenance is written once" do
    running = attempt(1, "running", provenance: %{"ended_at" => nil})
    {:ok, %{attempts: %{1 => :created}}} = Records.record(@task, @machinery, work(1, [running]))

    done =
      attempt(1, "completed", provenance: %{"harness_version" => "changed"}, result: @completed)

    assert {:ok, %{attempts: %{1 => :changed}}} =
             Records.record(@task, @machinery, work(2, [done]))

    assert %{
             "state" => "completed",
             "result_kind" => "completed",
             "harness_version" => "2.1.1",
             "ended_at" => "2026-11-17T10:01:30Z"
           } = ta(1)["values"]
  end

  test "the same snapshot twice writes nothing more; an older one does not regress the task" do
    done = attempt(1, "completed", result: @completed)
    {:ok, _} = Records.record(@task, @machinery, work(2, [done]))
    sent = length(FakeFacts.sent())

    assert {:ok, %{task: :unchanged, attempts: %{1 => :kept}}} =
             Records.record(@task, @machinery, work(2, [done]))

    assert {:ok, %{task: :unchanged}} =
             Records.record(@task, @machinery, work(1, [attempt(1, "running")]))

    assert length(FakeFacts.sent()) == sent
    assert task()["values"]["result_kind"] == "completed"
  end

  test "a newer attempt clears the earlier result on the task; an older snapshot does not move it back" do
    failed = %{
      "kind" => "failed",
      "reason" => "launch",
      "work_product" => %{"check" => %{"exit_status" => 1, "output" => %{"tail" => "red"}}}
    }

    first = attempt(1, "failed", result: failed)
    {:ok, _} = Records.record(@task, @machinery, work(3, [first]))

    assert %{"attempt" => 1, "result_kind" => "failed", "check_exit_status" => 1} =
             task()["values"]

    {:ok, _} = Records.record(@task, @machinery, work(5, [first, attempt(2, "running")]))
    assert %{"attempt" => 2} = held = task()["values"]

    for field <- ~w(result_kind reason check_exit_status check_output_tail),
        do: refute(Map.has_key?(held, field), field)

    # Attempt 1's result stays in its own record.
    assert %{"result_kind" => "failed", "state" => "failed"} = ta(1)["values"]

    # Read before the retry: only attempt 1, with its result.
    assert {:ok, %{task: :unchanged}} = Records.record(@task, @machinery, work(4, [first]))
    assert task()["values"] == held
  end

  test "a later snapshot of the same attempt updates the task and puts the result on it" do
    {:ok, _} = Records.record(@task, @machinery, work(1, [attempt(1, "running")]))

    assert %{"work_id" => "w-42", "attempt" => 1} = running = task()["values"]
    refute Map.has_key?(running, "result_kind")

    done = attempt(1, "completed", result: @completed)

    assert {:ok, %{task: :changed, attempts: %{1 => :changed}}} =
             Records.record(@task, @machinery, work(2, [done]))

    assert task()["values"] == %{
             "kind" => "author",
             "client_key" => @task,
             "state" => "submitted",
             "work_id" => "w-42",
             "attempt" => 1,
             "result_kind" => "completed",
             "answer" => "Done.",
             "check_exit_status" => 0,
             "check_output_tail" => "ok",
             "result_fingerprints" => ~s([{"fingerprint":"csf_abc","root":"atlas"}])
           }
  end

  test "a snapshot without attempts leaves the task's attempt and its result alone" do
    failed = %{"kind" => "failed", "reason" => "launch"}
    {:ok, _} = Records.record(@task, @machinery, work(3, [attempt(1, "failed", result: failed)]))
    held = task()["values"]
    assert %{"attempt" => 1, "result_kind" => "failed", "reason" => "launch"} = held

    empty = %{"work_id" => "w-42", "client_key" => @task, "revision" => 4, "attempts" => []}

    assert {:ok, %{task: :unchanged, attempts: attempts}} =
             Records.record(@task, @machinery, empty)

    assert attempts == %{}
    assert task()["values"] == held
  end

  test "the check's ending and a review's based_on fingerprint go on the task" do
    result = %{
      "kind" => "completed",
      "work_product" => %{
        "based_on" => %{
          "work_id" => "w-1",
          "attempt" => 1,
          "fingerprints" => [%{"root" => "atlas", "fingerprint" => "csf_base"}]
        },
        "check" => %{"exit_status" => nil, "timed_out" => true, "output" => %{"tail" => "…"}}
      }
    }

    {:ok, _} =
      Records.record(@task, @machinery, work(1, [attempt(1, "completed", result: result)]))

    assert %{"based_on" => "csf_base", "check_ending" => "timed_out", "check_output_tail" => "…"} =
             task()["values"]

    refute Map.has_key?(task()["values"], "check_exit_status")
  end

  test "without the task fact nothing is recorded" do
    assert {:error, {:task_missing, "TK-PK-9-1"}} =
             Records.record("TK-PK-9-1", @machinery, work(1, [attempt(1, "running")]))

    assert FakeFacts.sent() == []
  end
end
