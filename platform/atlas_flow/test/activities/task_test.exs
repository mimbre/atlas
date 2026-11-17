defmodule AtlasFlow.Activities.TaskTest do
  @moduledoc """
  The `task` activity (plan 2026-11-17 §6 F1.3, client obligations 1–5 of §3.5), with
  `FakeFacts` and a fake `AtlasFlow.Runtime.Client` (`AtlasFlow.FakeRuntime`): the state
  path; the same key after a transport error; unreachable → no change; 404 → resubmit;
  410 → stuck; at_capacity → submit after capacity; nothing without a machinery assignee
  (E1); an assignment moved away → abandoned; snapshots by revision; and, through the
  engine, the boot reconcile for intent with and without a `work_id`, and the Link's
  messages. The base (F1.5a) comes from a fake `AtlasFlow.Code.Client`
  (`AtlasFlow.FakeCode`): the task submits a `base` workspace of its snapshot ID, never a
  repository one.
  """
  use ExUnit.Case, async: false

  alias AtlasFlow.{Engine, FakeCode, FakeFacts, FakeRuntime, ManualClock, Sorts, TestModel}
  alias AtlasFlow.Activities.Task
  alias AtlasFlow.Runs.{Run, Store}

  @now ~U[2026-11-17 09:00:00Z]
  @input %{"code" => "example.invalid/depot", "base" => "develop", "root" => "depot"}

  defmodule Authored do
    @moduledoc false
    use AtlasFlow.TestModel,
      subflows: [AtlasFlow.Sorts.Authoring],
      selection: %{"sort" => Map.put(AtlasFlow.Depot.selection("sort"), "imports", [])}
  end

  setup do
    Application.put_env(:atlas_bus, :store, "state-#{System.unique_integer([:positive])}")
    machinery = Application.get_env(:atlas_flow, :machinery)
    client = Application.get_env(:atlas_flow, :runtime_client)
    code = Application.get_env(:atlas_flow, :code_client)

    Application.put_env(:atlas_flow, :machinery, %{
      "mac-mini" => %{url: "http://127.0.0.1:9", token_env: "ATLAS_FLOW_TASK_TEST_TOKEN"}
    })

    Application.put_env(:atlas_flow, :runtime_client, FakeRuntime)
    Application.put_env(:atlas_flow, :code_client, FakeCode)

    on_exit(fn ->
      restore(:machinery, machinery)
      restore(:runtime_client, client)
      restore(:code_client, code)
    end)

    start_supervised!(FakeFacts)
    start_supervised!(FakeRuntime)
    start_supervised!(FakeCode)
    clock = start_supervised!({ManualClock, @now})
    FakeFacts.put("machinery", %{"key" => "mac-mini", "values" => %{"name" => "mac-mini"}})
    FakeFacts.put("clerk", %{"key" => "ada"})
    c = put_in(TestModel.config(), ["selection", "sort", "imports"], [])
    assert :ok = Run.validate(Sorts.Authoring)
    %{c: c, flows: %{"sort" => Sorts.Authoring}, clock: clock}
  end

  defp restore(key, nil), do: Application.delete_env(:atlas_flow, key)
  defp restore(key, value), do: Application.put_env(:atlas_flow, key, value)

  # A box handed by hand (a link someone other than Flow set) to `owner`.
  defp box(key, owner) do
    FakeFacts.put("box", %{
      "key" => key,
      "values" => %{"phase" => "first", "step" => "Pack {#{key}} first."},
      "links" => %{"owned_by" => List.wrap(owner)},
      "origins" => %{"owned_by" => %{"by" => "melle", "position" => 1}}
    })
  end

  defp run(key \\ "B-1") do
    case FakeFacts.get("cursor", Run.key("sort", "box", key, 1)) do
      nil -> nil
      fact -> with {:ok, run} <- Store.decode(TestModel.config(), fact), do: run
    end
  end

  defp task_record(key), do: FakeFacts.get("task", key)

  describe "through the run store" do
    setup do
      :ok = AtlasBus.attach("flow")
      :ok
    end

    test "the state path: intent first, capacity, one submit by key; the result branches", c do
      box("B-1", "mac-mini")
      test = self()

      FakeRuntime.script(:submit, [
        fn key, _request ->
          send(test, {:at_submit, task_record(key), run()})
          :default
        end
      ])

      authoring = reconcile(c)
      key = "TK-B-1-1"
      assert authoring["state"] == "authoring" and authoring["status"] == "active"

      assert %{"key" => ^key, "machinery" => "mac-mini", "work_id" => "w-1"} =
               authoring["pending"]["task"]

      # Intent first: when the Runtime was asked, Facts held the task record and the run
      # held its key and request.
      assert_received {:at_submit, record, stored}
      assert record["values"]["client_key"] == key and record["values"]["state"] == "waiting"
      assert record["links"]["task_of"] == ["B-1"]
      assert record["values"]["kind"] == "author" and record["values"]["profile"] == "deep_coding"

      assert stored["pending"]["task"]["key"] == key and
               stored["pending"]["task"]["work_id"] == nil

      # Looked up by key, capacity asked, then exactly one submit under the task's key.
      assert Enum.map(FakeRuntime.calls(), &elem(&1, 0)) ==
               [:find_work, :capacity, :submit, :get_work]

      assert [[^key, request]] = FakeRuntime.calls(:submit)
      # A base workspace of the snapshot Code made of the input's branch when the intent
      # was: never a repository workspace, a folder or a path (D44, F1.5a).
      assert FakeCode.calls() == [@input]
      base_id = FakeCode.id(@input)

      assert request["workspace"] == %{
               "kind" => "base",
               "base_id" => base_id,
               "permissions" => "workspace-write"
             }

      assert JSON.decode!(record["values"]["input"]) == Map.put(@input, "base_id", base_id)
      assert stored["pending"]["task"]["request"] == request

      assert request["after_check"] == %{"command" => ["bin/check"]}
      assert request["profile"] == "deep_coding" and request["cost_class"] == "standard"
      assert request["instructions"] == "Pack the box.\n\n## step\n\nPack {B-1} first."
      assert task_record(key)["values"]["work_id"] == "w-1"

      FakeRuntime.move(key, "running")
      assert reconcile(c)["pending"]["task"]["state"] == "running"
      assert task_record(key)["values"]["state"] == "running"

      FakeRuntime.completed(key)
      done = reconcile(c)
      assert {done["state"], done["status"]} == {"authored", "completed"}
      assert done["pending"]["task"] == nil
      assert done["last_input"] == %{"version" => 1, "task" => key, "outcome" => "completed"}

      assert [
               %{
                 "key" => ^key,
                 "work_id" => "w-1",
                 "attempt" => 1,
                 "outcome" => "completed",
                 "kind" => "completed",
                 "check" => %{"exit_status" => 0}
               }
             ] = done["pending"]["tasks"]

      values = task_record(key)["values"]
      assert values["state"] == "completed" and values["result_kind"] == "completed"
      assert values["check_exit_status"] == 0 and values["answer"] == "Done."
      assert length(FakeRuntime.calls(:submit)) == 1
    end

    test "a failed, timed out or unfinished check is check_failed; any other end is stuck", c do
      ends = [
        {"B-1", &FakeRuntime.completed(&1, %{"exit_status" => 1}), "check_failed"},
        {"B-2", &FakeRuntime.completed(&1, %{"exit_status" => nil, "timed_out" => true}),
         "check_failed"},
        {"B-3", &FakeRuntime.completed(&1, %{"exit_status" => 0, "interrupted" => true}),
         "check_failed"},
        {"B-4", &FakeRuntime.finish(&1, "completed"), "check_failed"},
        {"B-5", &FakeRuntime.finish(&1, "failed", %{"reason" => "time_limit"}), "stuck"},
        {"B-6", &FakeRuntime.finish(&1, "crashed"), "stuck"}
      ]

      for {box, finish, outcome} <- ends do
        box(box, "mac-mini")
        reconcile(c, box)
        finish.("TK-#{box}-1")
        ended = reconcile(c, box)
        assert ended["state"] == outcome, "#{box}: #{ended["state"]}"
        assert [%{"outcome" => ^outcome}] = ended["pending"]["tasks"]
        assert task_record("TK-#{box}-1")["values"]["state"] == outcome
      end

      assert task_record("TK-B-2-1")["values"]["check_ending"] == "timed_out"
      assert task_record("TK-B-4-1")["values"]["check_ending"] == "not_run"
      assert task_record("TK-B-5-1")["values"]["reason"] == "time_limit"
    end

    test "after a transport error the same key is sent again; a taken one is found by key", c do
      # The Runtime took B-1's work but its answer was lost; B-2's never reached it.
      FakeRuntime.script(:submit, [{:lose, :timeout}, {:unreachable, :econnrefused}])
      box("B-1", "mac-mini")
      box("B-2", "mac-mini")
      lost = reconcile(c, "B-1")
      assert lost["pending"]["task"]["work_id"] == nil
      never = reconcile(c, "B-2")
      assert never["pending"]["task"]["work_id"] == nil

      assert reconcile(c, "B-1")["pending"]["task"]["work_id"] == "w-1"
      assert reconcile(c, "B-2")["pending"]["task"]["work_id"] == "w-2"

      # One key per task, throughout: B-1 was found, not sent twice; B-2 was sent again.
      assert Enum.map(FakeRuntime.calls(:submit), &hd/1) == ["TK-B-1-1", "TK-B-2-1", "TK-B-2-1"]

      assert FakeRuntime.calls(:find_work) |> Enum.map(&hd/1) |> Enum.uniq() ==
               ["TK-B-1-1", "TK-B-2-1"]
    end

    test "an unreachable Runtime changes nothing: no move, no resubmit, no reroute", c do
      box("B-1", "mac-mini")
      FakeRuntime.script(:find_work, [{:unreachable, :closed}])
      intent = reconcile(c)
      assert intent["pending"]["task"]["work_id"] == nil
      # Nothing was submitted, nor capacity asked, while the key could not be looked up.
      assert Enum.map(FakeRuntime.calls(), &elem(&1, 0)) == [:find_work]

      submitted = reconcile(c)
      assert submitted["pending"]["task"]["work_id"] == "w-1"
      FakeRuntime.completed("TK-B-1-1")
      puts = FakeFacts.puts()
      calls = length(FakeRuntime.calls())

      FakeRuntime.script(:get_work, List.duplicate({:unreachable, {:status, 502}}, 3))

      for advance <- [0, 3_600_000, 86_400_000] do
        ManualClock.advance(c.clock, advance)
        assert reconcile(c) == submitted
      end

      assert FakeFacts.puts() == puts

      assert Enum.map(Enum.drop(FakeRuntime.calls(), calls), &elem(&1, 0)) ==
               [:get_work, :get_work, :get_work]

      # Reachable again: the result it held all along.
      assert reconcile(c)["state"] == "authored"
    end

    test "404 by key is the only resubmit: a work the Runtime does not know is sent again", c do
      box("B-1", "mac-mini")
      assert reconcile(c)["pending"]["task"]["work_id"] == "w-1"
      # The Runtime lost it (its home was reset): by id, then by key, it was never seen.
      Agent.update(FakeRuntime, &%{&1 | works: %{}})
      again = reconcile(c)
      assert again["pending"]["task"]["key"] == "TK-B-1-1"
      assert again["pending"]["task"]["work_id"] == "w-2"

      assert Enum.map(FakeRuntime.calls(:submit), &hd/1) == ["TK-B-1-1", "TK-B-1-1"]
      assert ["TK-B-1-1"] = List.last(FakeRuntime.calls(:find_work))
    end

    test "410 is stuck, never a resubmit", c do
      box("B-1", "mac-mini")
      box("B-2", "mac-mini")
      reconcile(c, "B-1")
      FakeRuntime.prune("TK-B-1-1", "completed")
      stuck = reconcile(c, "B-1")
      assert stuck["state"] == "stuck" and stuck["status"] == "active"

      assert [%{"outcome" => "stuck", "reason" => "pruned: completed"}] =
               stuck["pending"]["tasks"]

      assert task_record("TK-B-1-1")["values"]["state"] == "stuck"

      # Pruned before Flow learnt its id: found pruned by key, never submitted.
      FakeRuntime.script(:submit, [{:lose, :timeout}])
      reconcile(c, "B-2")
      FakeRuntime.prune("TK-B-2-1", "failed")
      assert reconcile(c, "B-2")["state"] == "stuck"
      assert Enum.map(FakeRuntime.calls(:submit), &hd/1) == ["TK-B-1-1", "TK-B-2-1"]
      assert reconcile(c, "B-1") == stuck
    end

    test "at_capacity waits for capacity, then submits once", c do
      FakeRuntime.capacity!(FakeRuntime.full())
      box("B-1", "mac-mini")
      waiting = reconcile(c)
      assert waiting["pending"]["task"]["work_id"] == nil
      assert at(waiting["pending"]["task"]["retry_at"]) == ~U[2026-11-17 09:00:30Z]
      assert FakeRuntime.calls(:submit) == []

      # Until capacity is reported or Retry-After passed, the Runtime is not asked again.
      calls = FakeRuntime.calls()
      ManualClock.advance(c.clock, 29_000)
      assert reconcile(c) == waiting
      assert FakeRuntime.calls() == calls

      # The Link reports capacity: it asks again before its retry_at, and submits.
      FakeRuntime.capacity!(FakeRuntime.room())
      assert reconcile(c, "B-1", wake: true)["pending"]["task"]["work_id"] == "w-1"
      assert [["TK-B-1-1", _]] = FakeRuntime.calls(:submit)

      # The Runtime itself answers at_capacity: it waits its Retry-After, then submits.
      box("B-2", "mac-mini")
      FakeRuntime.script(:submit, [{:at_capacity, 5}])
      assert at(reconcile(c, "B-2")["pending"]["task"]["retry_at"]) == ~U[2026-11-17 09:00:34Z]
      assert reconcile(c, "B-2")["pending"]["task"]["work_id"] == nil
      ManualClock.advance(c.clock, 5_000)
      assert reconcile(c, "B-2")["pending"]["task"]["work_id"] == "w-2"
      assert Enum.map(FakeRuntime.calls(:submit), &hd/1) == ["TK-B-1-1", "TK-B-2-1", "TK-B-2-1"]
    end

    test "nothing happens without a machinery assignee (E1)", c do
      # Flow's configuration names `ada` and `mac-maxi`, but neither is a machinery: ada is
      # a clerk, and no fact is named mac-maxi. mac-mini is a machinery it does not name.
      Application.put_env(:atlas_flow, :machinery, %{
        "ada" => %{url: "http://127.0.0.1:9", token_env: "ATLAS_FLOW_TASK_TEST_TOKEN"},
        "mac-maxi" => %{url: "http://127.0.0.1:9", token_env: "ATLAS_FLOW_TASK_TEST_TOKEN"}
      })

      box("B-1", "ada")
      FakeFacts.put("box", %{"key" => "B-2", "values" => %{"phase" => "first"}})
      box("B-3", "mac-maxi")
      box("B-4", "mac-mini")

      for key <- ["B-1", "B-2", "B-3", "B-4"] do
        waiting = reconcile(c, key)
        assert waiting["state"] == "authoring" and waiting["pending"]["task"] == nil
      end

      assert FakeRuntime.calls() == []
      assert for(f <- FakeFacts.sent(), String.starts_with?(f["key"] || "", "TK-"), do: f) == []

      # Handed to the machinery: now it has its task.
      Application.put_env(:atlas_flow, :machinery, %{
        "mac-mini" => %{url: "http://127.0.0.1:9", token_env: "ATLAS_FLOW_TASK_TEST_TOKEN"}
      })

      box("B-1", "mac-mini")
      assert reconcile(c, "B-1")["pending"]["task"]["key"] == "TK-B-1-1"
    end

    test "an assignment moved away abandons the task; its late result is ignored", c do
      box("B-1", "mac-mini")
      assert reconcile(c)["pending"]["task"]["work_id"] == "w-1"
      box("B-1", "ada")
      abandoned = reconcile(c)
      assert {abandoned["state"], abandoned["status"]} == {"abandoned", "completed"}
      assert [%{"outcome" => "abandoned", "work_id" => "w-1"}] = abandoned["pending"]["tasks"]
      assert task_record("TK-B-1-1")["values"]["state"] == "abandoned"

      FakeRuntime.completed("TK-B-1-1")
      box("B-1", "mac-mini")
      assert reconcile(c, "B-1", works: %{"w-1" => FakeRuntime.work("TK-B-1-1")}) == abandoned
      assert task_record("TK-B-1-1")["values"]["state"] == "abandoned"
    end

    test "snapshots apply by revision: one not newer is passed over", c do
      box("B-1", "mac-mini")
      reconcile(c)
      old = FakeRuntime.work("TK-B-1-1")
      FakeRuntime.move("TK-B-1-1", "running")
      running = reconcile(c)
      assert running["pending"]["task"]["revision"] == 2
      # The Link's older report changes nothing; a newer one is applied without a read.
      assert reconcile(c, "B-1", works: %{"w-1" => old}) == running
      gets = length(FakeRuntime.calls(:get_work))
      done = FakeRuntime.completed("TK-B-1-1")
      assert reconcile(c, "B-1", works: %{"w-1" => done})["state"] == "authored"
      assert length(FakeRuntime.calls(:get_work)) == gets
    end

    # Review f13-review-dev2, required change 1 (R2): obligation 1, unreachable → no change.
    test "an unreachable capacity changes nothing: no submit, the run as it was", c do
      box("B-1", "mac-mini")
      FakeRuntime.script(:capacity, List.duplicate({:unreachable, :econnrefused}, 3))
      intent = reconcile(c)
      assert intent["pending"]["task"]["work_id"] == nil
      assert intent["pending"]["task"]["retry_at"] == nil
      assert Enum.map(FakeRuntime.calls(), &elem(&1, 0)) == [:find_work, :capacity]
      puts = FakeFacts.puts()

      for advance <- [0, 3_600_000] do
        ManualClock.advance(c.clock, advance)
        assert reconcile(c) == intent
      end

      assert FakeRuntime.calls(:submit) == []
      assert FakeFacts.puts() == puts
      assert task_record("TK-B-1-1")["values"]["state"] == "waiting"

      # Reachable again: submitted once, under the same key.
      assert reconcile(c)["pending"]["task"]["work_id"] == "w-1"
      assert [["TK-B-1-1", _]] = FakeRuntime.calls(:submit)
    end

    # Review f13-review-dev2, required change 2 (R6): a Facts blip never abandons.
    test "Facts unavailable on the assignee read changes nothing; the task is not abandoned",
         c do
      box("B-1", "mac-mini")
      # Before any intent: no task is started.
      GenServer.call(FakeFacts, {:busy, "machinery", "mac-mini"})
      before = reconcile(c)
      assert before["state"] == "authoring" and before["pending"]["task"] == nil
      assert FakeRuntime.calls() == []
      GenServer.call(FakeFacts, {:free, "machinery", "mac-mini"})

      running = reconcile(c)
      assert running["pending"]["task"]["work_id"] == "w-1"
      FakeRuntime.completed("TK-B-1-1")
      puts = FakeFacts.puts()
      calls = FakeRuntime.calls()

      # With a task in flight: kept as it was, the Runtime not even asked.
      GenServer.call(FakeFacts, {:busy, "machinery", "mac-mini"})

      for advance <- [0, 3_600_000] do
        ManualClock.advance(c.clock, advance)
        assert reconcile(c) == running
      end

      assert FakeFacts.puts() == puts
      assert FakeRuntime.calls() == calls
      assert task_record("TK-B-1-1")["values"]["state"] == "buffered"

      # Facts answers again: the result it held all along, not abandoned.
      GenServer.call(FakeFacts, {:free, "machinery", "mac-mini"})
      done = reconcile(c)
      assert done["state"] == "authored"
      assert [%{"outcome" => "completed"}] = done["pending"]["tasks"]
    end

    # Review f13-review-dev2, required change 3 (R5b): a re-entered state takes a new key.
    test "re-entering the task's state after stuck takes a new key, never the old one", c do
      box("B-1", "mac-mini")
      reconcile(c)
      FakeRuntime.prune("TK-B-1-1", "failed")
      stuck = reconcile(c)
      assert stuck["state"] == "stuck"
      assert [%{"key" => "TK-B-1-1", "outcome" => "stuck"}] = stuck["pending"]["tasks"]

      choose(stuck, "again")
      again = reconcile(c)
      assert again["state"] == "authoring" and again["status"] == "active"
      assert %{"key" => "TK-B-1-2", "work_id" => "w-2"} = again["pending"]["task"]
      assert Enum.map(FakeRuntime.calls(:submit), &hd/1) == ["TK-B-1-1", "TK-B-1-2"]
      assert List.last(FakeRuntime.calls(:find_work)) == ["TK-B-1-2"]

      assert task_record("TK-B-1-2")["values"]["client_key"] == "TK-B-1-2"
      assert task_record("TK-B-1-2")["links"]["task_of"] == ["B-1"]
      assert task_record("TK-B-1-1")["values"]["state"] == "stuck"

      FakeRuntime.completed("TK-B-1-2")
      assert reconcile(c)["state"] == "authored"
    end

    # Review f13-review-dev2, required change 4 (R1, R9).
    test "a refused submit is stuck with its reason; unauthenticated changes nothing", c do
      # `invalid` is today's answer to `after_check` from a Runtime without S5a.
      for {box, reason} <- [{"B-1", :invalid}, {"B-2", :unsupported_workspace}] do
        box(box, "mac-mini")
        FakeRuntime.script(:submit, [{:refused, reason}])
        stuck = reconcile(c, box)
        key = "TK-#{box}-1"
        text = "refused: #{reason}"
        assert {stuck["state"], stuck["status"]} == {"stuck", "active"}

        assert [%{"key" => ^key, "outcome" => "stuck", "reason" => ^text}] =
                 stuck["pending"]["tasks"]

        assert task_record(key)["values"]["state"] == "stuck"
        assert task_record(key)["values"]["reason"] == text
        # Terminal: never sent again.
        assert reconcile(c, box) == stuck
      end

      assert Enum.map(FakeRuntime.calls(:submit), &hd/1) == ["TK-B-1-1", "TK-B-2-1"]

      # A token mistake is not the task's fault: nothing moves, the same key goes again.
      box("B-3", "mac-mini")
      FakeRuntime.script(:submit, List.duplicate({:refused, :unauthenticated}, 2))
      intent = reconcile(c, "B-3")
      assert intent["state"] == "authoring" and intent["pending"]["task"]["work_id"] == nil
      assert intent["pending"]["task"]["retry_at"] == nil
      puts = FakeFacts.puts()
      assert reconcile(c, "B-3") == intent
      assert FakeFacts.puts() == puts
      assert task_record("TK-B-3-1")["values"]["state"] == "waiting"

      assert reconcile(c, "B-3")["pending"]["task"]["work_id"] == "w-1"

      assert Enum.map(FakeRuntime.calls(:submit), &hd/1) ==
               ["TK-B-1-1", "TK-B-2-1", "TK-B-3-1", "TK-B-3-1", "TK-B-3-1"]
    end

    # Review f13-review-dev2, optional (R4): only the task's own work is applied.
    test "a snapshot of another work is not applied", c do
      box("B-1", "mac-mini")

      other = %{
        "work_id" => "w-9",
        "client_key" => "TK-B-9-1",
        "revision" => 1,
        "state" => "completed",
        "attempts" => [
          %{"attempt" => 1, "state" => "completed", "result" => %{"kind" => "failed"}}
        ]
      }

      FakeRuntime.script(:find_work, [{:found, other}])
      intent = reconcile(c)
      assert intent["state"] == "authoring" and intent["pending"]["task"]["work_id"] == nil
      assert FakeRuntime.calls(:submit) == []

      # Its own work, by id: another id's snapshot is passed over too.
      assert reconcile(c)["pending"]["task"]["work_id"] == "w-1"
      FakeRuntime.script(:get_work, [{:found, %{other | "revision" => 5}}])
      assert reconcile(c)["pending"]["task"]["work_id"] == "w-1"
      assert reconcile(c)["state"] == "authoring"
    end

    # Review f13-review-dev2, optional (R11): the answer the record keeps is capped at 8 KB.
    test "a long answer is kept to its first 8 KB, on a character boundary", c do
      box("B-1", "mac-mini")
      box("B-2", "mac-mini")
      reconcile(c, "B-1")
      reconcile(c, "B-2")
      long = String.duplicate("a", 9000)
      # "a" then two-byte characters: byte 8192 falls inside one.
      split = "a" <> String.duplicate("é", 5000)
      FakeRuntime.finish("TK-B-1-1", "failed", %{"answer" => long})
      FakeRuntime.finish("TK-B-2-1", "failed", %{"answer" => split})
      assert reconcile(c, "B-1")["state"] == "stuck"
      assert reconcile(c, "B-2")["state"] == "stuck"

      assert task_record("TK-B-1-1")["values"]["answer"] == binary_part(long, 0, 8192)
      kept = task_record("TK-B-2-1")["values"]["answer"]
      assert String.valid?(kept) and byte_size(kept) == 8191
      assert String.starts_with?(split, kept)
    end

    # Review f13-review-dev2, required change 2 (R6), the component read: `holder/3`.
    test "Facts unavailable on the component holding the owner is unavailable, not other" do
      {:task, spec} = Sorts.Authoring.mechanism("authoring")
      owner = %{"relation" => "owned_by", "via" => "tray"}
      projection = %{"on" => "in_tray"}
      subject = %{"key" => "B-1", "links" => %{"in_tray" => ["T-1"]}}
      FakeFacts.put("tray", %{"key" => "T-1", "links" => %{"owned_by" => ["mac-mini"]}})
      assert Task.assignee(spec, owner, projection, subject) == {:machinery, "mac-mini"}

      GenServer.call(FakeFacts, {:busy, "tray", "T-1"})
      assert Task.assignee(spec, owner, projection, subject) == :unavailable
      GenServer.call(FakeFacts, {:free, "tray", "T-1"})

      GenServer.call(FakeFacts, {:busy, "machinery", "mac-mini"})
      assert Task.assignee(spec, owner, projection, subject) == :unavailable
      GenServer.call(FakeFacts, {:free, "machinery", "mac-mini"})

      FakeFacts.put("tray", %{"key" => "T-1", "links" => %{"owned_by" => ["ada"]}})
      assert Task.assignee(spec, owner, projection, subject) == :other
    end
  end

  describe "through the engine" do
    defp engine(c), do: start_supervised!({Engine, engine_opts(c)}, id: Engine)

    defp engine_opts(c),
      do: [every: 3_600_000, clock: {ManualClock, c.clock}, model: Authored]

    test "boot reconcile: intent is found by key or sent after 404; a work_id is read back", c do
      for key <- ["B-1", "B-2", "B-3"], do: box(key, "mac-mini")

      lose = fn
        "TK-B-1-1", _ -> {:lose, :timeout}
        "TK-B-2-1", _ -> {:unreachable, :econnrefused}
        _, _ -> :default
      end

      FakeRuntime.script(:submit, [lose, lose, lose])
      # Only the boot round: the one the engine plans when it starts.
      Engine.idle(engine(c))
      assert run("B-1")["pending"]["task"]["work_id"] == nil
      assert run("B-2")["pending"]["task"]["work_id"] == nil
      assert run("B-3")["pending"]["task"]["work_id"] == "w-2"
      stop_supervised!(Engine)

      # While Flow was down, B-3's work ended.
      FakeRuntime.completed("TK-B-3-1")
      calls = length(FakeRuntime.calls())
      Engine.idle(engine(c))

      assert run("B-1")["pending"]["task"]["work_id"] == "w-1"
      assert run("B-2")["pending"]["task"]["work_id"] == "w-3"
      assert run("B-3")["state"] == "authored"

      boot = Enum.drop(FakeRuntime.calls(), calls)
      # By key for intent without a work_id (B-1 found; B-2 never seen, so sent again under
      # its key); by id for the one with a work_id.
      assert {:find_work, ["TK-B-1-1"]} in boot and {:find_work, ["TK-B-2-1"]} in boot
      assert {:get_work, ["w-2"]} in boot
      refute Enum.any?(boot, &match?({:submit, ["TK-B-1-1", _]}, &1))

      assert Enum.map(FakeRuntime.calls(:submit), &hd/1) ==
               ["TK-B-1-1", "TK-B-2-1", "TK-B-3-1", "TK-B-2-1"]
    end

    test "the Link: capacity submits the waiting tasks oldest first; a change applies", c do
      FakeRuntime.capacity!(FakeRuntime.full())
      box("B-2", "mac-mini")
      engine = engine(c)
      Engine.round(engine)
      ManualClock.advance(c.clock, 1_000)
      box("B-1", "mac-mini")
      Engine.round(engine)

      assert run("B-2")["pending"]["task"]["created_at"] <
               run("B-1")["pending"]["task"]["created_at"]

      assert FakeRuntime.calls(:submit) == []

      # Room for one: the older task (B-2's) is submitted, the other one waits.
      FakeRuntime.script(:capacity, [
        {:capacity, FakeRuntime.room()},
        {:capacity, FakeRuntime.full()}
      ])

      FakeRuntime.capacity!(FakeRuntime.room())
      send(engine, {:capacity, FakeRuntime.room()})
      :sys.get_state(engine)
      assert Enum.map(FakeRuntime.calls(:submit), &hd/1) == ["TK-B-2-1"]
      assert run("B-1")["pending"]["task"]["work_id"] == nil

      # No room reported: nothing is asked.
      calls = FakeRuntime.calls()
      send(engine, {:capacity, FakeRuntime.full()})
      :sys.get_state(engine)
      assert FakeRuntime.calls() == calls

      # The Link reports B-2's work completed: its run applies that snapshot, read once.
      gets = length(FakeRuntime.calls(:get_work))
      send(engine, {:work_changed, FakeRuntime.completed("TK-B-2-1")})
      :sys.get_state(engine)
      assert run("B-2")["state"] == "authored"
      assert length(FakeRuntime.calls(:get_work)) == gets

      # A change of a work Flow holds no task for does nothing.
      send(
        engine,
        {:work_changed, %{"work_id" => "w-9", "client_key" => "TK-X-1", "revision" => 1}}
      )

      :sys.get_state(engine)
      assert run("B-1")["pending"]["task"]["work_id"] == nil

      # Without a capacity event, the round comes at the task's Retry-After, not the hour.
      retry_at = at(run("B-1")["pending"]["task"]["retry_at"])

      ManualClock.advance(
        c.clock,
        DateTime.diff(retry_at, ManualClock.now(c.clock), :millisecond)
      )

      Engine.idle(engine)
      assert run("B-1")["pending"]["task"]["work_id"] == "w-2"
    end

    # Review f13-review-dev2, optional (R7): after a lost submit answer, only the client key
    # can match the Link's report.
    test "the Link's change of a task without a work_id is matched by its client key", c do
      box("B-1", "mac-mini")
      FakeRuntime.script(:submit, [{:lose, :timeout}])
      engine = engine(c)
      Engine.idle(engine)
      assert run("B-1")["pending"]["task"]["work_id"] == nil
      finds = length(FakeRuntime.calls(:find_work))

      send(engine, {:work_changed, FakeRuntime.work("TK-B-1-1")})
      :sys.get_state(engine)
      assert run("B-1")["pending"]["task"]["work_id"] == "w-1"
      assert length(FakeRuntime.calls(:find_work)) == finds + 1
      assert [["TK-B-1-1", _]] = FakeRuntime.calls(:submit)
    end
  end

  describe "the base (F1.5a)" do
    setup do
      :ok = AtlasBus.attach("flow")
      :ok
    end

    test "the base is asked of Code once, when the intent is made; a resubmit keeps it", c do
      box("B-1", "mac-mini")
      FakeRuntime.script(:submit, [{:unreachable, :timeout}])
      first = reconcile(c)
      base_id = FakeCode.id(@input)
      assert first["pending"]["task"]["request"]["workspace"]["base_id"] == base_id
      assert first["pending"]["task"]["work_id"] == nil

      # Sent again under the same key with the same request, the base not asked again.
      again = reconcile(c)
      assert again["pending"]["task"]["work_id"] == "w-1"
      assert [[k, r1], [k, r2]] = FakeRuntime.calls(:submit)
      assert r1 == r2 and r1["workspace"]["base_id"] == base_id
      assert FakeCode.calls() == [@input]
    end

    test "without a base from Code no intent is made and nothing is sent", c do
      box("B-1", "mac-mini")

      FakeCode.script([
        {:unavailable, "No Code instance is registered"},
        {:refused, :forbidden},
        {:ok, ""}
      ])

      for _ <- 1..3 do
        run = reconcile(c)
        assert run["state"] == "authoring" and run["pending"]["task"] == nil
        assert FakeRuntime.calls() == []
        assert task_record("TK-B-1-1") == nil
      end

      assert reconcile(c)["pending"]["task"]["work_id"] == "w-1"
      assert length(FakeCode.calls()) == 4
    end

    test "plan and review tasks read their base; author and fix tasks write it" do
      {:task, spec} = Sorts.Authoring.mechanism("authoring")
      subject = %{"key" => "B-1", "values" => %{}}

      for {kind, permissions} <- [
            {"plan", "read-only"},
            {"review", "read-only"},
            {"author", "workspace-write"},
            {"fix", "workspace-write"}
          ] do
        assert Task.request(Map.put(spec, "kind", kind), subject, "sha256:abc")["workspace"] ==
                 %{"kind" => "base", "base_id" => "sha256:abc", "permissions" => permissions}
      end
    end
  end

  describe "the spec" do
    test "a task names Code's repository, its branch and root, never a path" do
      {:task, spec} = Sorts.Authoring.mechanism("authoring")
      assert Task.valid?(spec)
      assert spec["input"] == @input
      refute Task.valid?(put_in(spec, ["input", "path"], "/Users/someone/work"))
      refute Task.valid?(Map.put(spec, "input", %{"folder" => "/tmp/x", "base" => "develop"}))
      refute Task.valid?(put_in(spec, ["input", "root"], "/Users/someone/work"))
      refute Task.valid?(put_in(spec, ["input", "root"], "../elsewhere"))
      refute Task.valid?(Map.put(spec, "profile", "light_work"))
      refute Task.valid?(Map.put(spec, "check", []))
      refute Task.valid?(Map.delete(spec, "records"))
    end

    test "no repository input remains: a repository workspace's input is not a task's" do
      {:task, spec} = Sorts.Authoring.mechanism("authoring")
      refute Map.has_key?(spec["input"], "repository")

      refute Task.valid?(
               Map.put(spec, "input", %{
                 "repository" => "https://example.invalid/depot.git",
                 "base" => "develop"
               })
             )

      refute Task.valid?(put_in(spec, ["input", "repository"], "https://example.invalid/d.git"))
    end

    test "room: accepting, the profile available, and a free slot or buffer place" do
      assert Task.room?(FakeRuntime.room(), "deep_coding")
      refute Task.room?(FakeRuntime.full(), "deep_coding")
      refute Task.room?(Map.put(FakeRuntime.room(), "accepting", false), "deep_coding")

      refute Task.room?(
               put_in(FakeRuntime.room(), ["profiles", "deep_coding", "available"], false),
               "deep_coding"
             )

      refute Task.room?(nil, "deep_coding")
    end
  end

  defp at(text), do: text |> Run.parse!() |> DateTime.truncate(:second)

  # The clerk's choice on the run's current entry, as Facts takes it.
  defp choose(run, choice) do
    {:stored, _} =
      AtlasFlow.Talk.put("choice", %{
        "op" => "submit",
        "key" => "I-#{run["subject_key"]}-#{choice}-#{run["entry"]}",
        "values" => %{
          "run" => run["key"],
          "entry" => run["entry"],
          "roles" => ["clerk"],
          "changed_fields" => %{"choice" => choice}
        }
      })
  end

  defp reconcile(c, key \\ "B-1", opts \\ []) do
    {:ok, %{runs: known}} = Store.plan(c.c, c.flows)
    now = ManualClock.now(c.clock)
    {:ok, runs} = Store.reconcile_subjects(c.c, c.flows, now, known, [{"box", key}], opts)
    assert [run] = Enum.filter(runs, &(&1["subject_key"] == key))
    run
  end
end
