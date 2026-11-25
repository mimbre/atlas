defmodule AtlasFlow.Activities.TaskTest.Bench do
  @moduledoc """
  A neutral model for the task activity on the lease path (plan m3 A4): a bin is worked
  on by a robot (a machinery kind) through its `loading` state, which runs a task and lies
  in the supervised span `pack`. A clerk supervises the run; a robot can never supervise.
  The task's input names a Code repository and the reference its base comes from.
  """
  use RelaDSL.Composition,
    name: "bench",
    subflow_behaviour: AtlasFlow.Subflow

  @behaviour AtlasFlow.Model

  defmodule Desk do
    @moduledoc "The bins, their robots, who supervises their runs, and the slips."
    use RelaDSL

    type(:slip_operation, values: [:choice, :pickup, :hand_over, :retry])

    entity :clerk, label: "Clerk", plural: "clerks", id_type: :manual do
      field(:name, :string)
    end

    entity :robot, label: "Robot", plural: "robots", id_type: :manual do
      field(:name, :string)
    end

    entity :bin, label: "Bin", plural: "bins", id_type: :manual do
      field(:phase, :string)
      field(:step, :string)
      field(:choice, :string)
      field(:task_result, :string)
    end

    relation(:owned_by, label: "owned by", from: [:bin], to: [:robot, :clerk], max_outgoing: 1)
    relation(:chosen_by, label: "chosen by", from: [:bin], to: [:clerk], max_outgoing: 1)

    entity :cursor, label: "Cursor", plural: "cursors", id_type: :manual do
      for f <- ~w(flow subject_kind subject_key state entered_at status
                  deadlines pending last_input blocked_reason)a,
          do: field(f, :string)

      for f <- ~w(generation entry input_cursor)a, do: field(f, :integer)
    end

    entity :slip, label: "Slip", plural: "slips", id_type: :manual do
      field(:run, :string)
      field(:actor, :string)
      field(:operation, :slip_operation)
      field(:hand_to, :string)
    end

    relation(:watched_by,
      label: "watched by",
      from: [:cursor],
      to: [:clerk],
      max_outgoing: 1,
      set_by: [:flow]
    )

    flow_runtime(
      runs: :cursor,
      writer: [sender: :flow, by: :flow],
      inputs: :slip,
      supervision: [relation: :watched_by, operation: :operation, hand_to: :hand_to]
    )

    subflow :work, label: "Work", subject: :bin do
      run_as("system:bench")
      owner(relation: :owned_by, default: {:clerk, :desk})
      start(:create)
      initial(:loading)
      supervise(:pack, label: "Pack", states: [:loading])

      state :loading do
        task(:author,
          role: :developer,
          profile: :deep_coding,
          input: [repository: "example.org/acme/bench", base: "develop"],
          check: ["bin/check"],
          instructions: "Load the bin.",
          fields: [:step],
          records: [kind: "task", relation: "task_of"],
          machinery: "robot",
          on: [completed: :done, check_failed: :failed, stuck: :stuck, abandoned: :abandoned]
        )
      end

      state :stuck do
        wait_for([:clerk], on: :choice, again: :loading)
      end

      final(:done)
      final(:failed)
      final(:abandoned)
    end

    select(:work,
      choices: [:choice],
      roles: [clerk: :chosen_by],
      admission: [phase: [:first]],
      imports: []
    )
  end

  defmodule Bins do
    @moduledoc "The bench model's one module."
    use RelaDSL.Module, path: "modules/bins/schema.yaml", concepts: [Desk]
  end

  schema(version: "1.0", namespace: "https://example.invalid/bench#", description: "Bins.\n")
  modules([Bins])
  environments([:prod, :test])

  acl(comment: "The bench's roles.")
  role("bench", read: ["*"], create: [:cursor], update: [:bin, :cursor])
  role("clerk", read: ["*"], update: [:bin])
  assign("system:bench", "bench")

  defcomposition :bench do
    subflows([Desk])
  end
end

defmodule AtlasFlow.Activities.TaskTest do
  @moduledoc """
  The `task` activity on Flow's work source (plan m3 §3.5, §4 A4): a bin assigned to a
  robot, whose run is supervised by a clerk, becomes a version-2 intent and a task fact,
  is offered to that clerk's Runtime with its base, and ends as the task fact Delivery
  wrote says. The real Dispatch, Delivery and Bases (on `FakeCode`), with
  `FakeFacts` and a manual clock; asserted on run fields, fact values, lease fields, calls
  and outcome tags, never on wording.
  """
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias AtlasFlow.{Bases, Delivery, Dispatch, Engine, FakeCode, FakeFacts, ManualClock}
  alias AtlasFlow.WorkSource
  alias AtlasFlow.Activities.Task
  alias AtlasFlow.Activities.TaskTest.Bench
  alias AtlasFlow.FakeFacts.Leasing, as: L
  alias AtlasFlow.Runs.{Run, Store}
  alias AtlasFlow.WorkSource.Translate

  @epoch ~U[2026-11-17 12:00:00Z]
  @repository "example.org/acme/bench"
  @readme "# Bench\n"
  @actors %{"desk" => "ada"}
  @mini {"mini", "ada"}
  @laptop {"laptop", "bea"}
  @task "TK-B-1-1"

  setup do
    Application.put_env(:atlas_bus, :store, "task-#{System.unique_integer([:positive])}")
    dir = Path.join(System.tmp_dir!(), "task-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)

    start_supervised!(FakeFacts)
    {:ok, clock} = ManualClock.start_link(@epoch)
    clock = {ManualClock, clock}

    code = start_supervised!({FakeCode, %{}}, id: :code)
    FakeCode.put(code, @repository, "develop", "rev_1", %{"README.md" => @readme})

    runner = AtlasFlow.Model.load(Bench, :prod, @actors)
    assert runner.refusal == nil

    for clerk <- ~w(ada bea), do: FakeFacts.put("clerk", %{"key" => clerk})
    for robot <- ~w(mini laptop), do: FakeFacts.put("robot", %{"key" => robot})

    %{runner: runner, clock: clock, code: code, dir: dir}
  end

  # Bases on FakeCode, Dispatch and Delivery (which casts to `engine`), on the test's clock.
  defp source(c, opts \\ []) do
    start_bases(c)
    start_dispatch(c)
    start_delivery(c, Keyword.get(opts, :engine, self()))
    c
  end

  defp start_bases(c),
    do:
      start_supervised!(
        Supervisor.child_spec({Bases, client: FakeCode.client(c.code), clock: c.clock}, id: Bases)
      )

  defp start_dispatch(c),
    do:
      start_supervised!(
        Supervisor.child_spec(
          {Dispatch,
           model: Bench,
           actors: @actors,
           clock: c.clock,
           poll_wait: 0,
           sweep_ms: nil,
           resync_ms: nil},
          id: Dispatch
        )
      )

  defp start_delivery(c, engine),
    do:
      start_supervised!(
        Supervisor.child_spec(
          {Delivery, model: Bench, actors: @actors, clock: c.clock, engine: engine},
          id: Delivery
        )
      )

  # A bin in its first phase, owned (by hand) by `owner`: a robot, a clerk or nobody.
  defp bin(key, owner) do
    FakeFacts.put("bin", %{
      "key" => key,
      "values" => %{"phase" => "first", "step" => "Load {#{key}}."},
      "links" => %{"owned_by" => List.wrap(owner)},
      "origins" => %{"owned_by" => %{"by" => "someone", "position" => 1}}
    })
  end

  defp run(c, key \\ "B-1") do
    case FakeFacts.get(c.runner.config["kind"], Run.key("work", "bin", key, 1)) do
      nil -> nil
      fact -> with {:ok, run} <- Store.decode(c.runner.config, fact), do: run
    end
  end

  # Sets (nil: clears) the run's supervisor, as a checked pickup or hand-over writes it.
  defp supervise(c, supervisor, key \\ "B-1", generation \\ 1) do
    run_key = Run.key("work", "bin", key, generation)
    fact = FakeFacts.get(c.runner.config["kind"], run_key)
    links = Map.put(fact["links"] || %{}, "watched_by", List.wrap(supervisor))
    version = (fact["version"] || 0) + 1

    FakeFacts.put(
      c.runner.config["kind"],
      Map.merge(fact, %{"links" => links, "version" => version})
    )
  end

  defp reconcile(c, key \\ "B-1") do
    {:ok, %{runs: known}} = Store.plan(c.runner.config, c.runner.flows)

    {:ok, runs} =
      Store.reconcile_subjects(c.runner.config, c.runner.flows, now(c), known, [{"bin", key}])

    assert [run] = Enum.filter(runs, &(&1["subject_key"] == key))
    run
  end

  defp now(%{clock: clock}), do: AtlasFlow.Runs.Clock.now(clock)

  # The base is resolved in Bases' own task; its notify reaches the test process.
  defp base_ready(key \\ "B-1"), do: assert_receive({:reconcile, "bin", ^key}, 2_000)

  # A bin (supervised by `supervisor`) whose run holds its version-2 intent and whose task
  # fact exists. Its base is asked for first, unless Bases holds it already.
  defp intended(c, key \\ "B-1", supervisor \\ "ada") do
    bin(key, "mini")

    if reconcile(c, key)["pending"]["task"] == nil do
      base_ready(key)
      assert %{"version" => 2} = reconcile(c, key)["pending"]["task"]
    end

    if supervisor, do: supervise(c, supervisor, key)
    run = reconcile(c, key)
    assert %{"version" => 2} = run["pending"]["task"]
    run
  end

  # A process attached as `flow` that runs what it is given and passes on any other
  # message (Bases' notify) to the test: `{:ok, answer}`, or `:timeout`.
  defp flow_process do
    test = self()

    spawn_link(fn ->
      :ok = AtlasBus.attach("flow")
      serve(test)
    end)
  end

  defp serve(test) do
    receive do
      {:run, ref, fun} ->
        send(test, {ref, fun.()})
        serve(test)

      other ->
        send(test, other)
        serve(test)
    end
  end

  defp as_flow(process, fun, timeout \\ 2_000) do
    ref = make_ref()
    send(process, {:run, ref, fun})

    receive do
      {^ref, answer} -> {:ok, answer}
    after
      timeout -> :timeout
    end
  end

  defp poll(client, holdings \\ [], offer \\ %{"deep_coding" => 1}) do
    {id, _} = client
    WorkSource.poll(client, L.poll_input(id, holdings, offer))
  end

  defp lease!(client) do
    assert {:polled, %{leases: [lease]}} = poll(client)
    lease
  end

  defp report(client, lease, revision, report),
    do: WorkSource.report(client, %{lease_id: lease, revision: revision, report: report})

  # accepted, started, then `ended`.
  defp work(client, lease, ended) do
    assert {:recorded, _} = report(client, lease, 1, %{state: :accepted})
    assert {:recorded, _} = report(client, lease, 2, %{state: :started})
    report(client, lease, 3, ended)
  end

  defp delivered(key \\ "B-1"), do: assert_receive({:"$gen_cast", {:reconcile, "bin", ^key}})

  # The leased bin's README and manifest blob requests, and their bytes as served now.
  defp leased_base do
    %{lease_id: lease, work: offered} = lease!(@mini)
    readme = %{lease_id: lease, sha256: L.sha256(@readme)}
    manifest = %{lease_id: lease, sha256: offered.input.base.manifest}
    {readme, manifest, {served(readme), served(manifest)}}
  end

  defp served(blob) do
    assert {:blob, %{content: content}} = WorkSource.get_blob(@mini, blob)
    IO.iodata_to_binary(Enum.to_list(content))
  end

  # Runs `fun`, then awaits Bases' restore of `manifest` from `snapshot`: its task's answer
  # as Bases receives it (traced, an event; no sleep), then Bases has handled it.
  defp restored(manifest, snapshot, fun) do
    bases = Process.whereis(Bases)
    1 = :erlang.trace(bases, true, [:receive])

    try do
      fun.()

      assert_receive {:trace, ^bases, :receive,
                      {ref,
                       {:ok, :pinned, %{base: %{manifest: ^manifest, snapshot_id: ^snapshot}}}}}
                     when is_reference(ref),
                     2_000

      :sys.get_state(bases)
    after
      :erlang.trace(bases, false, [:receive])
    end
  end

  defp task_values(key \\ @task), do: FakeFacts.get("task", key)["values"]

  defp check(exit_status, more \\ %{}),
    do: Map.merge(%{exit_status: exit_status, output_tail: "tail"}, more)

  describe "through the run store" do
    setup do
      :ok = AtlasBus.attach("flow")
      :ok
    end

    test "intent first, offered to the supervisor's Runtime with its base; a passed check is done",
         c do
      source(c)
      bin("B-1", "mini")

      # No base cached yet: Bases is asked, no intent is made, the run is unchanged.
      waiting = reconcile(c)
      assert {waiting["state"], waiting["pending"]["task"]} == {"loading", nil}
      assert FakeFacts.get("task", @task) == nil
      base_ready()
      {:ok, base} = Bases.cached(@repository, "develop")

      supervise(c, "ada")
      run = reconcile(c)

      # The run holds the version-2 intent with the base, the supervisor's (no machinery);
      # the task fact was created after it.
      assert %{"version" => 2, "key" => @task, "machinery" => nil} =
               intent = run["pending"]["task"]

      assert Translate.intent?(intent)

      assert intent["work"]["input"]["base"] == %{
               "base_id" => base.base_id,
               "manifest" => base.manifest
             }

      record = FakeFacts.get("task", @task)
      assert record["links"]["task_of"] == ["B-1"]
      assert record["values"]["state"] == "waiting" and record["values"]["client_key"] == @task

      assert Map.take(record["values"], ~w(kind role profile)) ==
               %{"kind" => "author", "role" => "developer", "profile" => "deep_coding"}

      # Offered at once (Dispatch was told; no resync runs), only to the supervisor's Runtime.
      assert {:polled, %{leases: []}} = poll(@laptop)
      assert %{lease_id: lease, work: offered} = lease!(@mini)
      assert offered == Translate.offered_work(intent)
      assert offered.work_key == @task
      assert offered.input.base == %{base_id: base.base_id, manifest: base.manifest}
      # The pulled folder holds the repository at its root (`bench`): the check is there.
      assert offered.after_check == %{command: ["bench/bin/check"]}
      refute Enum.any?(Map.keys(offered), &(&1 in [:repository, :folder, :slot, :resume_from]))

      # Nothing moves the run until the result is recorded.
      assert reconcile(c)["state"] == "loading"
      assert {:recorded, _} = work(@mini, lease, L.ended(nil, check: check(0)))
      delivered()

      done = reconcile(c)
      assert {done["state"], done["status"]} == {"done", "completed"}
      assert done["pending"]["task"] == nil

      assert [%{"key" => @task, "attempt" => 1, "outcome" => "completed"} = r] =
               done["pending"]["tasks"]

      assert r["kind"] == "completed" and r["check"]["exit_status"] == 0
      assert task_values()["state"] == "completed"
      assert done["last_input"] == %{"version" => 1, "task" => @task, "outcome" => "completed"}
    end

    test "a failed check is check_failed; refused, too large or another end is stuck", c do
      source(c)

      ends = [
        {"B-1", &work(@mini, &1, L.ended(nil, check: check(1))), "failed", "check_failed"},
        {"B-2", &work(@mini, &1, L.ended(nil, check: check(nil, %{timed_out: true}))), "failed",
         "check_failed"},
        {"B-3", &work(@mini, &1, L.ended(nil)), "failed", "check_failed"},
        {"B-4", &work(@mini, &1, L.ended(nil, kind: :failed, reason: "time_limit")), "stuck",
         "stuck"},
        {"B-5", &report(@mini, &1, 1, %{state: :refused, reason: :unsupported_profile}), "stuck",
         "stuck"}
      ]

      for {key, finish, state, outcome} <- ends do
        intended(c, key)
        %{lease_id: lease} = lease!(@mini)
        assert {:recorded, _} = finish.(lease)
        delivered(key)
        ended = reconcile(c, key)
        status = if state == "stuck", do: "active", else: "completed"
        assert {ended["state"], ended["status"]} == {state, status}, key
        assert [%{"outcome" => ^outcome}] = ended["pending"]["tasks"]
        assert task_values("TK-#{key}-1")["state"] == outcome
      end

      assert [%{"kind" => "refused"}] = reconcile(c, "B-5")["pending"]["tasks"]
      assert task_values("TK-B-2-1")["check_ending"] == "timed_out"
    end

    test "a change set an older Runtime still reports is not read: no blob is asked (IS-Atlas-100)",
         c do
      source(c)
      intended(c)
      %{lease_id: lease} = lease!(@mini)
      change_set = L.change_set([{"main.rs", "fn main() {}\n"}], task_values()["base_id"])

      assert {:recorded, %{missing: []}} =
               work(@mini, lease, L.ended(change_set, check: check(0)))

      delivered()
      refute Map.has_key?(task_values(), "result_state")
      refute Map.has_key?(task_values(), "result_manifest")
      assert reconcile(c)["state"] == "done"
    end

    test "not assigned to a robot: no base asked for, no intent, no task (E1)", c do
      source(c)
      bin("B-1", "ada")
      FakeFacts.put("bin", %{"key" => "B-2", "values" => %{"phase" => "first"}})
      bin("B-3", "mac-maxi")

      for key <- ~w(B-1 B-2 B-3) do
        run = reconcile(c, key)
        assert {run["state"], run["pending"]["task"]} == {"loading", nil}
      end

      refute_receive {:reconcile, _, _}, 100
      assert FakeCode.calls(c.code) == []
      assert for(f <- FakeFacts.sent(), String.starts_with?(f["key"] || "", "TK-"), do: f) == []
    end

    test "no supervisor: the intent waits and nothing is offered", c do
      source(c)
      intended(c, "B-1", nil)
      assert FakeFacts.get("task", @task) != nil
      assert {:polled, %{leases: []}} = poll(@mini)
      assert {:polled, %{leases: []}} = poll(@laptop)
      assert task_values()["lease_id"] == nil

      # Picked up: the next reconcile tells Dispatch again, and the holder's Runtime gets it.
      supervise(c, "ada")
      reconcile(c)
      assert %{work: %{work_key: @task}} = lease!(@mini)
    end

    test "picked up, with no robot: the task is the supervisor's and offered to their Runtime",
         c do
      source(c)
      bin("B-1", "ada")
      assert reconcile(c)["pending"]["task"] == nil

      supervise(c, "ada")
      reconcile(c)
      base_ready()
      assert %{"machinery" => nil} = reconcile(c)["pending"]["task"]
      assert {:polled, %{leases: []}} = poll(@laptop)
      assert %{work: %{work_key: @task}} = lease!(@mini)
    end

    test "a lease ended without a result is offered again; the run waits", c do
      source(c)
      intended(c)
      %{lease_id: first} = lease!(@mini)
      assert {:recorded, _} = report(@mini, first, 1, %{state: :accepted})
      assert {:recorded, _} = report(@mini, first, 2, L.ended(nil, kind: :returned))

      run = reconcile(c)
      assert {run["state"], run["pending"]["task"]["key"]} == {"loading", @task}
      assert %{lease_id: second, work: %{work_key: @task}} = lease!(@mini)
      assert second != first and task_values()["attempt"] == 2
    end

    test "its supervisor's retry: the held task is cancelled and a fresh one is offered", c do
      source(c)
      run = intended(c)
      lease!(@mini)

      FakeFacts.put_input(%{
        "key" => "S-1",
        "run" => run["key"],
        "entry" => run["entry"],
        "generation" => 1,
        "status" => "applied",
        "actor" => "ada",
        "operation" => "retry",
        "roles" => ["retry"],
        "changed_fields" => %{},
        "links" => %{},
        "position" => 10,
        "prepared_at" => "2026-11-17T11:59:00Z"
      })

      retried = reconcile(c)
      assert {retried["state"], retried["entry"]} == {"loading", run["entry"] + 1}
      assert retried["supervised_by"] == "ada"
      assert %{"key" => "TK-B-1-2"} = retried["pending"]["task"]
      assert task_values()["state"] == "cancelled"
      assert %{work: %{work_key: "TK-B-1-2"}} = lease!(@mini)
    end

    test "an assignment moved away abandons the task; a late end is ignored", c do
      source(c)
      intended(c)
      %{lease_id: lease} = lease!(@mini)
      assert {:recorded, _} = report(@mini, lease, 1, %{state: :accepted})

      # Its flow no longer supervised, the task it made for the robot is abandoned once the
      # bin leaves that robot.
      supervise(c, nil)
      bin("B-1", "bea")
      abandoned = reconcile(c)
      assert {abandoned["state"], abandoned["status"]} == {"abandoned", "completed"}
      assert [%{"outcome" => "abandoned", "key" => @task}] = abandoned["pending"]["tasks"]
      assert task_values()["state"] == "abandoned"

      # The late end is recorded on the task, and the run, which no longer holds it, stays.
      assert {:recorded, %{missing: []}} =
               report(@mini, lease, 2, L.ended(nil, check: check(0)))

      assert task_values()["lease_state"] == "done"
      bin("B-1", "mini")
      assert reconcile(c) == abandoned
    end

    test "the Engine writes a task fact's input once, at its create; Dispatch's grant writes it fenced",
         c do
      source(c)
      intended(c)
      %{lease_id: lease} = lease!(@mini)
      assert {:recorded, _} = work(@mini, lease, L.ended(nil, check: check(0)))
      delivered()
      assert reconcile(c)["state"] == "done"

      writes = for w <- FakeFacts.sent(), w["key"] == @task, do: w
      with_input = for w <- writes, Map.has_key?(w["values"] || %{}, "input"), do: w
      assert [%{"op" => "create"}, grant] = with_input
      assert grant["values"]["lease_id"] == lease and Map.has_key?(grant["was"], "input")

      # The Engine's last write on it: the outcome alone.
      assert %{"op" => "change", "values" => %{"state" => "completed"}} = List.last(writes)
    end

    test "Code unavailable: no intent; after Bases' retry it is made", c do
      source(c)
      FakeCode.mode(c.code, :failing)
      bin("B-1", "mini")
      supervise_later = reconcile(c)
      assert supervise_later["pending"]["task"] == nil
      # Bases failed: it is unavailable, and a reconcile asks nothing more of it.
      wait_until(fn -> Bases.cached(@repository, "develop") == :unavailable end)
      calls = length(FakeCode.calls(c.code))
      supervise(c, "ada")
      assert reconcile(c)["pending"]["task"] == nil
      assert length(FakeCode.calls(c.code)) == calls

      FakeCode.mode(c.code, :ok)
      L.advance(c, 30)
      base_ready()
      assert %{"version" => 2} = reconcile(c)["pending"]["task"]
    end

    test "the work source off (Bases not running): no intent, nothing raised", c do
      bin("B-1", "mini")
      run = reconcile(c)
      assert {run["state"], run["pending"]["task"]} == {"loading", nil}
      assert Bases.cached(@repository, "develop") == :unavailable
      assert FakeCode.calls(c.code) == []
    end

    test "after a restart, a held lease's base is restored from its snapshot, also once the branch moved",
         c do
      source(c)
      intended(c)
      %{lease_id: lease, work: offered} = lease!(@mini)
      readme = L.sha256(@readme)
      blob = %{lease_id: lease, sha256: readme}
      assert {:blob, %{content: before}} = WorkSource.get_blob(@mini, blob)
      before = IO.iodata_to_binary(Enum.to_list(before))
      assert before == @readme
      resolved = Enum.count(FakeCode.calls(c.code), &(elem(&1, 0) == :resolve_reference))

      # develop moves on, and Flow restarts: Bases' table is empty.
      FakeCode.put(c.code, @repository, "develop", "rev_2", %{"README.md" => "# Moved\n"})
      stop_supervised!(Bases)
      start_bases(c)
      assert WorkSource.get_blob(@mini, blob) == :not_found
      assert Bases.names(offered.input.base.manifest) == :not_found

      assert reconcile(c)["state"] == "loading"
      wait_until(fn -> match?({:ok, _}, Bases.names(offered.input.base.manifest)) end)

      # The lease's own base, from its pinned snapshot: the original bytes, no new resolve.
      assert {:blob, %{content: served}} = WorkSource.get_blob(@mini, blob)
      assert IO.iodata_to_binary(Enum.to_list(served)) == before
      assert Enum.count(FakeCode.calls(c.code), &(elem(&1, 0) == :resolve_reference)) == resolved
      assert task_values()["base_snapshot"] == run(c)["pending"]["task"]["base_snapshot"]
    end

    test "the pin holds while the moved branch is cached first: restored from its snapshot (B1)",
         c do
      source(c)
      pinned = intended(c)["pending"]["task"]["base_snapshot"]
      {readme, manifest_blob, before} = leased_base()
      manifest = manifest_blob.sha256

      FakeCode.put(c.code, @repository, "develop", "rev_2", %{"README.md" => "# Moved\n"})
      stop_supervised!(Bases)
      start_bases(c)

      # A new bin needs a fresh base: the moved develop is cached before B-1 is reconciled.
      bin("B-2", "mini")
      assert reconcile(c, "B-2")["pending"]["task"] == nil
      base_ready("B-2")
      assert {:ok, moved} = Bases.cached(@repository, "develop")
      assert moved.manifest != manifest and moved.snapshot_id != pinned
      assert WorkSource.get_blob(@mini, manifest_blob) == :not_found

      restored(manifest, pinned, fn -> assert reconcile(c)["state"] == "loading" end)

      # The lease's own base, byte for byte; the reference keeps its moved base.
      assert {served(readme), served(manifest_blob)} == before
      assert Bases.cached(@repository, "develop") == {:ok, moved}
    end

    test "same tree, new revision: the held lease's manifest blob is served after a restart (B2)",
         c do
      source(c)
      pinned = intended(c)["pending"]["task"]["base_snapshot"]
      {readme, manifest_blob, before} = leased_base()
      manifest = manifest_blob.sha256

      # develop moves to a revision with the same files: another snapshot, the same manifest.
      FakeCode.put(c.code, @repository, "develop", "rev_2", %{"README.md" => @readme})
      stop_supervised!(Bases)
      start_bases(c)
      bin("B-2", "mini")
      assert reconcile(c, "B-2")["pending"]["task"] == nil
      base_ready("B-2")
      assert {:ok, same} = Bases.cached(@repository, "develop")
      assert same.manifest == manifest and same.snapshot_id != pinned
      refute Bases.held?(manifest, pinned)

      restored(manifest, pinned, fn -> assert reconcile(c)["state"] == "loading" end)

      assert {served(readme), served(manifest_blob)} == before
      assert Bases.held?(manifest, pinned) and Bases.held?(manifest, same.snapshot_id)
    end

    test "a held intent of the push path is never offered: it ends stuck", c do
      source(c)
      bin("B-1", "mini")
      reconcile(c)
      base_ready()
      supervise(c, "ada")
      run = run(c)
      old = %{"version" => 1, "key" => @task, "machinery" => "mini", "created_at" => "x"}
      config = c.runner.config
      fact = FakeFacts.get(config["kind"], run["key"])
      values = Store.encode(config, put_in(run, ["pending", "task"], old))

      FakeFacts.put(
        config["kind"],
        Map.merge(fact, %{"values" => values, "version" => fact["version"] + 1})
      )

      stuck = reconcile(c)
      assert stuck["state"] == "stuck"
      assert [%{"key" => @task, "outcome" => "stuck"}] = stuck["pending"]["tasks"]
    end
  end

  # Remove (IS-Atlas-09): the work Flow made for the bin first, held back after its delete
  # as rela holds a deleted id back, then the bin itself.
  defp remove(task) do
    FakeFacts.reserve("task", task)
    GenServer.call(FakeFacts, {:drop, "bin", "B-1"})
  end

  describe "a bin removed and made again under its key (IS-Atlas-77)" do
    setup do
      :ok = AtlasBus.attach("flow")
      :ok
    end

    test "with the delete hint: its run ends; the new bin gets a new run, a new task and a lease",
         c do
      source(c)
      first = intended(c)
      assert %{lease_id: _, work: %{work_key: @task}} = lease!(@mini)

      remove(@task)
      ended = reconcile(c)
      assert {ended["generation"], ended["status"]} == {1, "ended"}
      assert ended["blocked_reason"] == "subject_removed"

      # Made again under the same key: the next generation, a run of its own.
      bin("B-1", "mini")
      second = reconcile(c)
      assert {second["generation"], second["status"], second["state"]} == {2, "active", "loading"}
      assert second["key"] != first["key"]

      # Its task is numbered past the removed one's, whose key Facts still holds back, and
      # its record's write is a write of its own, never taken for the removed one's.
      assert %{"key" => "TK-B-1-2"} = second["pending"]["task"]
      assert second["pending"]["former_tasks"] == [@task]
      assert %{"values" => %{"state" => "waiting"}} = FakeFacts.get("task", "TK-B-1-2")
      assert FakeFacts.get("task", @task) == nil

      # Picked up: its task is offered and leased.
      supervise(c, "ada", "B-1", 2)
      assert reconcile(c)["supervised_by"] == "ada"
      assert %{work: %{work_key: "TK-B-1-2"}} = lease!(@mini)
      assert task_values("TK-B-1-2")["lease_id"] != nil
    end

    test "a task's writes are ids of its run: the same task key in another generation is another write",
         _c do
      spec = %{"records" => %{"kind" => "task", "relation" => "task_of"}}
      intent = %{"key" => @task}

      ids =
        for g <- [1, 2],
            do: Task.cancelled(%{"key" => Run.key("work", "bin", "B-1", g)}, intent, spec)["id"]

      assert Enum.uniq(ids) == ids

      assert Enum.all?(
               ids,
               &(&1 !=
                   AtlasBus.Digest.of_term([@task, "result"])
                   |> String.replace_prefix("sha256:", ""))
             )
    end
  end

  describe "Code on the Engine's path" do
    test "Code blocked: the reconcile returns without calling Code; the notify makes the intent",
         c do
      source(c)
      FakeCode.mode(c.code, :blocked)
      bin("B-1", "mini")
      flow = flow_process()

      assert {:ok, run} = as_flow(flow, fn -> reconcile(c) end)
      assert run["pending"]["task"] == nil
      # Code is called only from Bases' own task, never from the reconciling process.
      wait_until(fn -> FakeCode.blocked(c.code) == 1 end)
      refute Enum.any?(FakeCode.calls(c.code), fn {_, pid} -> pid in [flow, self()] end)

      supervise(c, "ada")
      assert {:ok, again} = as_flow(flow, fn -> reconcile(c) end)
      assert again["pending"]["task"] == nil
      refute_receive {:reconcile, _, _}, 50

      FakeCode.mode(c.code, :ok)
      FakeCode.release(c.code)
      base_ready()

      assert {:ok, %{"pending" => %{"task" => %{"version" => 2}}}} =
               as_flow(flow, fn -> reconcile(c) end)

      refute Enum.any?(FakeCode.calls(c.code), fn {_, pid} -> pid in [flow, self()] end)
    end
  end

  describe "through the engine" do
    defp engine(c) do
      start_supervised!(
        {Engine,
         every: 3_600_000, clock: c.clock, model: Bench, actors: @actors, name: AtlasFlow.Engine},
        id: Engine
      )
    end

    test "a reconcile arrives as a cast (Delivery's) and as a plain message (Bases'); both reconcile",
         c do
      source(c, engine: AtlasFlow.Engine)
      bin("B-1", "mini")
      engine = engine(c)
      Engine.idle(engine)
      # The boot round asked Bases; its notify reconciled the bin, which still has no supervisor.
      wait_until(fn -> Bases.cached(@repository, "develop") != :missing end)
      :sys.get_state(engine)
      supervise(c, "ada")

      # A plain message, as Bases' notify: the intent is made and offered.
      send(engine, {:reconcile, "bin", "B-1"})
      :sys.get_state(engine)
      assert %{"version" => 2} = run(c)["pending"]["task"]
      %{lease_id: lease} = lease!(@mini)

      # A cast, as Delivery's once the result is recorded: the run ends.
      assert {:recorded, _} = work(@mini, lease, L.ended(nil, check: check(0)))
      wait_until(fn -> run(c)["state"] == "done" end)

      GenServer.cast(engine, {:reconcile, "bin", "nothing-here"})
      send(engine, {:reconcile, "bin", "nothing-here"})
      :sys.get_state(engine)
      assert Process.alive?(engine)
    end

    test "with the work source off, a task that needs a base makes no intent; the Engine lives",
         c do
      bin("B-1", "mini")
      engine = engine(c)
      Engine.idle(engine)
      supervise(c, "ada")
      Engine.round(engine)
      assert Process.alive?(engine)
      assert run(c)["state"] == "loading" and run(c)["pending"]["task"] == nil
    end

    test "Flow restarted mid-task is rebuilt from Facts alone and ends the task", c do
      source(c, engine: AtlasFlow.Engine)
      bin("B-1", "mini")
      engine = engine(c)
      Engine.idle(engine)
      wait_until(fn -> match?({:ok, _}, Bases.cached(@repository, "develop")) end)
      supervise(c, "ada")
      Engine.round(engine)
      %{lease_id: lease} = lease!(@mini)
      assert {:recorded, _} = report(@mini, lease, 1, %{state: :accepted})

      # Every process of Flow stops; what they knew is in Facts only.
      for id <- [Engine, Delivery, Dispatch, Bases], do: stop_supervised!(id)
      source(c, engine: AtlasFlow.Engine)
      engine = engine(c)
      Engine.idle(engine)

      assert {:polled, %{lease_lost: []}} = poll(@mini, [lease], %{})
      assert {:recorded, _} = report(@mini, lease, 2, L.ended(nil, check: check(0)))
      # The run is stored before its write of the task's outcome is sent (intent first).
      wait_until(fn -> run(c)["state"] == "done" and task_values()["state"] == "completed" end)
    end
  end

  describe "through the application" do
    defmodule Probed do
      @moduledoc """
      The bench model, which tells the test whether Bases' table exists when the Engine
      loads it (in its `init`, before its first round).
      """
      @behaviour AtlasFlow.Model
      alias AtlasFlow.Activities.TaskTest.Bench

      @impl true
      def subflows(env) do
        with {:registered_name, AtlasFlow.Engine} <- Process.info(self(), :registered_name),
             test when is_pid(test) <- :persistent_term.get({__MODULE__, :test}, nil),
             do: send(test, {:engine_init, :ets.whereis(AtlasFlow.Bases) != :undefined})

        Bench.subflows(env)
      end

      @impl true
      def runs, do: Bench.runs()
      @impl true
      def selection(name), do: Bench.selection(name)
      @impl true
      def composition, do: Bench.composition()
      @impl true
      def actors, do: Bench.actors()
      @impl true
      def relations, do: Bench.relations()
      def turn, do: Bench.turn()
      def supervision, do: Bench.supervision()
    end

    test "configured, the work source starts before the Engine: its first round finds Bases",
         _c do
      keys =
        [atlas: :model, atlas: :actors, atlas_flow: :start, atlas_flow: :tick_seconds] ++
          [atlas_flow: :work_source]

      previous = for {app, key} <- keys, do: {app, key, Application.get_env(app, key)}
      :persistent_term.put({Probed, :test}, self())
      bin("B-1", "mini")

      try do
        :ok = Application.stop(:atlas_flow)
        Application.put_env(:atlas, :model, Probed)
        Application.put_env(:atlas, :actors, @actors)
        Application.put_env(:atlas_flow, :start, true)
        Application.put_env(:atlas_flow, :tick_seconds, 3_600)
        Application.put_env(:atlas_flow, :work_source, sweep_ms: nil, resync_ms: nil)
        {:ok, _} = Application.ensure_all_started(:atlas_flow)

        assert_receive {:engine_init, true}, 2_000
        Engine.idle(AtlasFlow.Engine)

        # Its first round asked Bases for the bin's base (no Code runs here, so it is
        # unavailable now, not missing: Bases tried).
        wait_until(fn -> Bases.cached(@repository, "develop") != :missing end)
      after
        Application.stop(:atlas_flow)
        :persistent_term.erase({Probed, :test})

        for {app, key, value} <- previous do
          if value == nil,
            do: Application.delete_env(app, key),
            else: Application.put_env(app, key, value)
        end

        {:ok, _} = Application.ensure_all_started(:atlas_flow)
      end
    end
  end

  describe "the spec and the lease path's code" do
    test "a task names a repository and its base reference, never a path" do
      {:task, spec} = Bench.subflows(:prod) |> hd() |> then(& &1.mechanism("loading"))
      assert Task.valid?(spec)
      assert spec["input"] == %{"repository" => @repository, "base" => "develop"}
      refute Task.valid?(put_in(spec, ["input", "path"], "/Users/someone/work"))
      refute Task.valid?(Map.put(spec, "input", %{"folder" => "/tmp/x", "base" => "develop"}))
      refute Task.valid?(Map.put(spec, "profile", "light_work"))
      refute Task.valid?(Map.delete(spec, "records"))

      # Why it failed goes to a field of the subject; no task is a ladder step (IS-Atlas-100).
      assert Task.valid?(Map.put(spec, "failure", "task_failure"))
      refute Task.valid?(Map.put(spec, "failure", ""))
      refute Task.valid?(Map.merge(spec, %{"failure" => "task_failure", "ladder" => true}))

      # Never a URL: a scheme, or the `user@host:path` form, in either value.
      for {key, url} <- [
            {"repository", "https://example.org/acme/bench.git"},
            {"repository", "git@example.org:acme/bench.git"},
            {"base", "file:///srv/bench"}
          ],
          do: refute(Task.valid?(put_in(spec, ["input", key], url)), url)
    end

    test "the DSL refuses a task input with a folder or path key, or a URL" do
      for input <- [
            ~s([repository: "example.org/acme/x", base: "develop", path: "/w"]),
            ~s([folder: "/tmp/x", base: "develop"]),
            ~s([repository: "https://example.org/acme/x.git", base: "develop"]),
            ~s([repository: "git@example.org:acme/x.git", base: "develop"])
          ] do
        source = """
        defmodule AtlasFlow.Activities.TaskTest.Refused#{System.unique_integer([:positive])} do
          use RelaDSL.Schema

          subflow :sort, subject: :box do
            run_as("system:depot")
            owner(default: {:clerk, :ada})
            start(:create)
            initial(:a)

            state :a do
              task(:author, role: :developer, profile: :deep_coding, input: #{input},
                instructions: "x", records: [kind: "task", relation: "task_of"],
                machinery: "machinery",
                on: [completed: :b, check_failed: :b, stuck: :b, abandoned: :b])
            end

            final(:b)
          end
        end
        """

        # Refused at the task's own line (source line 11), whatever the problem's text.
        error = assert_raise CompileError, fn -> Code.compile_string(source) end
        assert error.line == 11
      end
    end

    test "no lib module names the push client, its Link or its machinery config" do
      push = ~r/AtlasFlow\.Runtime\.(Client|Link|Config)\b/
      own = ~w(client.ex link.ex config.ex client)

      for path <- Path.wildcard(Path.expand("../../lib/**/*.ex", __DIR__)),
          not (String.contains?(path, "/lib/atlas_flow/runtime/") and
                 Path.basename(path) in own) do
        refute File.read!(path) =~ push, path
      end
    end
  end

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("the condition did not hold")
      true -> Process.sleep(20) && wait_until(fun, tries - 1)
    end
  end
end
