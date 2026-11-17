defmodule AtlasFlow.Boundary.TasksTest do
  # Plan 2026-11-17 §3.3, §5 F5 ("facade tests of the tasks contract"): Flow's `tasks`
  # contract through its generated facade, on Flow's records in Facts (FakeFacts) and a
  # fake machinery (FakeRuntime). Reading only: nothing is written, submitted or cancelled.
  use ExUnit.Case, async: false

  alias AtlasFlow.Boundary.Tasks, as: B
  alias AtlasFlow.{FakeFacts, FakeRuntime}
  alias AtlasFlowBoundary.Generator.{ContractError, InvalidInput, NotPermitted}

  @reader {"control", [:read]}
  @subject "PK-7"

  setup do
    Application.put_env(:atlas_bus, :store, "state-#{System.unique_integer([:positive])}")
    machinery = Application.get_env(:atlas_flow, :machinery)
    client = Application.get_env(:atlas_flow, :runtime_client)

    Application.put_env(:atlas_flow, :machinery, %{
      "mac-mini" => %{url: "http://127.0.0.1:9", token_env: "ATLAS_FLOW_TASKS_TEST_TOKEN"}
    })

    Application.put_env(:atlas_flow, :runtime_client, FakeRuntime)

    on_exit(fn ->
      restore(:machinery, machinery)
      restore(:runtime_client, client)
    end)

    start_supervised!(FakeFacts)
    start_supervised!(FakeRuntime)
    :ok = AtlasBus.attach("flow")
    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:atlas_flow, key)
  defp restore(key, value), do: Application.put_env(:atlas_flow, key, value)

  defp task(key, subject, values),
    do:
      FakeFacts.put("task", %{
        "key" => key,
        "version" => 1,
        "values" => values,
        "links" => %{"task_of" => [subject]}
      })

  defp attempt(task_key, n, values),
    do:
      FakeFacts.put("task_attempt", %{
        "key" => "TA-#{task_key}-#{n}",
        "version" => 1,
        "values" => values,
        "links" => %{"attempt_of" => [task_key], "ran_on" => ["mac-mini"]}
      })

  # An author task as Flow records it after its second attempt passed its check, a first
  # attempt that crashed, and a review task on its result; one task of another subject.
  defp records do
    task("TK-PK-7-1", @subject, %{
      "kind" => "author",
      "role" => "developer",
      "profile" => "deep_coding",
      "input" => ~s({"base":"input-marker"}),
      "client_key" => "TK-PK-7-1",
      "state" => "completed",
      "work_id" => "w-1",
      "attempt" => 2,
      "result_kind" => "completed",
      "check_exit_status" => 0,
      "check_output_tail" => "bin/check: all 12 job(s) passed",
      "result_fingerprints" => ~s([{"root":"atlas","fingerprint":"csf_aaa"}]),
      "base_id" => "sha256:base",
      "base_snapshot" => "sha256:base",
      "base_revision" => "rev_1"
    })

    attempt("TK-PK-7-1", 2, %{
      "state" => "completed",
      "result_kind" => "completed",
      "provider" => "anthropic",
      "harness" => "claude",
      "configured_model" => "claude-opus-5-5",
      "reported_model" => "claude-opus-5-5-20261101",
      "conversation_id" => "conv-2",
      "machine" => "mac-mini",
      "slot" => "slot-2",
      "started_at" => "2026-11-17T10:02:00Z",
      "ended_at" => "2026-11-17T10:02:30Z"
    })

    attempt("TK-PK-7-1", 1, %{
      "state" => "crashed",
      "result_kind" => "crashed",
      "harness" => "claude",
      "started_at" => "2026-11-17T10:01:00Z"
    })

    task("TK-PK-7-2", @subject, %{
      "kind" => "review",
      "role" => "developer",
      "profile" => "independent_review",
      "state" => "waiting",
      "verdict" => "changes_required",
      "based_on" => "csf_aaa",
      "check_ending" => "timed_out"
    })

    task("TK-PK-8-1", "PK-8", %{"kind" => "author", "state" => "waiting"})
  end

  describe "list_tasks" do
    test "a subject's tasks in the order Flow defined them, each with its attempts" do
      records()
      # Defined tenth: after the second, not between the first and the second.
      task("TK-PK-7-10", @subject, %{"kind" => "fix", "state" => "waiting"})

      assert %B.Outcome.Tasks{subject: @subject, tasks: tasks} =
               B.list_tasks(@reader, %{subject: @subject})

      assert Enum.map(tasks, & &1.task_id) == ~w(TK-PK-7-1 TK-PK-7-2 TK-PK-7-10)
      [author, review, fix] = tasks

      assert %B.Task{
               subject: @subject,
               kind: :author,
               role: :developer,
               profile: "deep_coding",
               state: "completed",
               work_id: "w-1",
               attempt: 2,
               result_kind: "completed",
               check: %B.Check{
                 exit_status: 0,
                 ending: nil,
                 output_tail: "bin/check: all 12 job(s) passed"
               },
               result_fingerprints: ["csf_aaa"],
               based_on: [],
               base_id: "sha256:base",
               base_revision: "rev_1"
             } = author

      # Oldest first; the reported model is kept as reported.
      assert [%B.TaskAttempt{attempt: 1, state: "crashed"}, second] = author.attempts

      assert %B.TaskAttempt{
               attempt: 2,
               machinery: "mac-mini",
               reported_model: "claude-opus-5-5-20261101",
               slot: "slot-2",
               started_at: ~U[2026-11-17 10:02:00Z],
               ended_at: ~U[2026-11-17 10:02:30Z]
             } = second

      assert %B.Task{
               kind: :review,
               verdict: :changes_required,
               based_on: ["csf_aaa"],
               check: %B.Check{ending: :timed_out},
               attempts: []
             } = review

      assert %B.Task{kind: :fix, check: nil, result_fingerprints: [], attempts: []} = fix
    end

    test "the task's input and Flow's private fields are not shown" do
      records()
      %B.Outcome.Tasks{tasks: [author | _]} = B.list_tasks(@reader, %{subject: @subject})
      shown = B.Task.dump(author)
      refute Map.has_key?(shown, "input")
      refute Map.has_key?(shown, "client_key")
      refute inspect(shown) =~ "input-marker"
    end

    test "a subject without tasks has none" do
      records()

      assert %B.Outcome.Tasks{subject: "PK-9", tasks: []} =
               B.list_tasks(@reader, %{subject: "PK-9"})
    end

    test "Facts not answering is unavailable, never an empty list" do
      records()

      GenServer.call(
        FakeFacts,
        {:block_read, "task", %{"linked" => %{"task_of" => @subject}, "plain" => true}}
      )

      assert %B.Outcome.Unavailable{message: "Facts did not answer"} =
               B.list_tasks(@reader, %{subject: @subject})
    end

    test "a record that is no task is unavailable, naming it" do
      records()
      task("TK-PK-7-3", @subject, %{"kind" => "sweep"})

      assert %B.Outcome.Unavailable{message: message} =
               B.list_tasks(@reader, %{subject: @subject})

      assert message =~ "TK-PK-7-3"
    end
  end

  describe "get_task" do
    test "found: the task with its attempts" do
      records()

      assert %B.Outcome.Found{task_id: "TK-PK-7-1", subject: @subject, kind: :author} =
               found = B.get_task(@reader, %{task_id: "TK-PK-7-1"})

      assert Enum.map(found.attempts, & &1.attempt) == [1, 2]
    end

    test "not_found for a task Flow has no record of" do
      records()
      assert %B.Outcome.NotFound{} = B.get_task(@reader, %{task_id: "TK-PK-7-99"})
    end

    test "unavailable when Facts does not answer for the task" do
      records()
      GenServer.call(FakeFacts, {:busy, "task", "TK-PK-7-1"})

      assert %B.Outcome.Unavailable{message: "Facts did not answer"} =
               B.get_task(@reader, %{task_id: "TK-PK-7-1"})
    end

    test "unavailable for a record that names no subject" do
      FakeFacts.put("task", %{"key" => "TK-X-1", "values" => %{"kind" => "author"}})

      assert %B.Outcome.Unavailable{message: "Flow's record of TK-X-1 names no subject"} =
               B.get_task(@reader, %{task_id: "TK-X-1"})
    end

    test "a caller that is not attached to the Bus gets unavailable, not a crash" do
      records()

      assert %B.Outcome.Unavailable{message: "Facts did not answer"} =
               Task.async(fn -> B.get_task(@reader, %{task_id: "TK-PK-7-1"}) end)
               |> Task.await()
    end
  end

  describe "machinery_status" do
    test "reachable: what the machinery last said of its capacity, and when" do
      FakeRuntime.capacity!(%{
        "accepting" => true,
        "slots" => %{"total" => 2, "busy" => 1, "free" => 1},
        "profiles" => [
          %{"profile" => "independent_review", "available" => false, "reason" => "quota"},
          %{"profile" => "deep_coding", "available" => true}
        ]
      })

      before = DateTime.utc_now() |> DateTime.truncate(:second)

      assert %B.Outcome.Status{
               machinery: "mac-mini",
               reachable: true,
               last_capacity: %B.Capacity{
                 accepting: true,
                 free_slots: 1,
                 profiles: [
                   %B.ProfileCapacity{profile: "deep_coding", available: true},
                   %B.ProfileCapacity{
                     profile: "independent_review",
                     available: false,
                     reason: "quota"
                   }
                 ]
               },
               last_seen: seen
             } = B.machinery_status(@reader, %{machinery: "mac-mini"})

      assert DateTime.compare(seen, before) != :lt
    end

    test "profiles by name, as Flow's submit reads them, are the same capacity" do
      assert %B.Outcome.Status{
               reachable: true,
               last_capacity: %B.Capacity{
                 free_slots: 1,
                 profiles: [
                   %B.ProfileCapacity{profile: "deep_coding", available: true},
                   %B.ProfileCapacity{profile: "independent_review", available: true}
                 ]
               }
             } = B.machinery_status(@reader, %{machinery: "mac-mini"})
    end

    test "unreachable: not reachable, and nothing it did not say" do
      FakeRuntime.script(:capacity, [{:unreachable, :econnrefused}])

      assert %B.Outcome.Status{
               machinery: "mac-mini",
               reachable: false,
               last_capacity: nil,
               last_seen: nil
             } = B.machinery_status(@reader, %{machinery: "mac-mini"})
    end

    test "a machinery Flow has no configuration of is not reachable and is not asked" do
      assert %B.Outcome.Status{machinery: "mac-maxi", reachable: false} =
               B.machinery_status(@reader, %{machinery: "mac-maxi"})

      assert FakeRuntime.calls() == []
    end
  end

  describe "the facade" do
    test "a caller without read is not permitted, and nothing is read" do
      records()
      reads = FakeFacts.reads()

      for call <- [
            fn c -> B.list_tasks(c, %{subject: @subject}) end,
            fn c -> B.get_task(c, %{task_id: "TK-PK-7-1"}) end,
            fn c -> B.machinery_status(c, %{machinery: "mac-mini"}) end
          ],
          do: assert(%NotPermitted{} = call.({"someone", [:steer]}))

      assert FakeFacts.reads() == reads
      assert FakeRuntime.calls() == []
    end

    test "malformed input is answered by the facade, without calling Flow" do
      {reads, _} = FakeFacts.reads()

      assert %InvalidInput{capability: :list_tasks} = B.list_tasks(@reader, %{})

      assert %InvalidInput{capability: :get_task} =
               B.get_task(@reader, %{task_id: 7})

      assert elem(FakeFacts.reads(), 0) == reads
    end

    test "a caller that is no {id, rights} is a contract error" do
      assert_raise ContractError, fn -> B.list_tasks(:control, %{subject: @subject}) end
    end

    test "reading writes nothing, submits nothing and cancels nothing" do
      records()
      B.list_tasks(@reader, %{subject: @subject})
      B.get_task(@reader, %{task_id: "TK-PK-7-1"})
      B.machinery_status(@reader, %{machinery: "mac-mini"})

      assert FakeFacts.sent() == []
      assert Enum.map(FakeRuntime.calls(), &elem(&1, 0)) == [:capacity]
    end
  end
end
