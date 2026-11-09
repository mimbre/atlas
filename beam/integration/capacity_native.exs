# MIX_ENV=test mix run integration/capacity_native.exs
# Real Facts, Bus, Flow, Runtime and Control, with the existing private disk
# store and a synthetic execution port. No network or provider authentication.
ExUnit.start(seed: 0)

defmodule CapacityProof.Concepts do
  use RelaDSL

  entity :operator, label: "Operator", plural: "operators", id_type: :manual do
    field(:paused, :string)
  end

  entity :reader, label: "Reader", plural: "readers", id_type: :manual do
    field(:name, :string)
  end

  entity :ticket, label: "Ticket", plural: "tickets", id_type: :manual do
    for f <- ~w(result todo step later)a, do: field(f, :string)

    for f <- ~w(entry picked_entry picked vendor model picked_machine at)a,
        do: field(f, :string, set_by: [:flow])
  end

  entity :run, label: "Run", plural: "runs", id_type: :manual do
    field(:quiescent, :boolean, set_by: [:runtime])

    for f <- ~w(state host lease activity why ended_at outcome attempt pick backend model step)a,
        do: field(f, :string)
  end

  entity :job, label: "Job", plural: "jobs", id_type: :manual do
    for f <- ~w(flow subject_kind subject_key definition_sha256 state entered_at status
                deadlines pending last_input blocked_reason)a,
        do: field(f, :string)

    for f <- ~w(generation entry input_cursor)a, do: field(f, :integer)
  end

  relation(:owner, label: "owner", from: [:ticket], to: [:operator], max_outgoing: 1)
  relation(:performer, label: "performer", from: [:run], to: [:operator])
  relation(:task, label: "task", from: [:run], to: [:ticket])

  entity :choice, label: "Choice", plural: "choices", id_type: :manual do
    for f <- ~w(request_id run flow subject_kind subject_key source_version subject_version actor
                roles changed_fields links payload_digest status prepared_at applied_at)a,
        do: field(f, :string)

    for f <- ~w(generation entry position)a, do: field(f, :integer)
  end

  flow_runtime(runs: :job, writer: [sender: :flow, by: :flow], inputs: :choice)

  runtime(
    turn: [
      kind: :run,
      key: "R-{on}-{n}",
      on: :task,
      by: :performer,
      state: :state,
      running: :running,
      ended: :ended,
      machine: :host,
      lease: :lease,
      activity: :activity,
      why: :why,
      ended_at: :ended_at,
      outcome: :outcome,
      attempt: :attempt,
      pick: :pick,
      backend: :backend,
      model: :model,
      step: :step,
      quiescent: :quiescent,
      lease_margin: 120
    ],
    agent: [cannot_run: :paused],
    capacity: [
      entry: :entry,
      picked_entry: :picked_entry,
      pick: :picked,
      backend: :vendor,
      model: :model,
      machine: :picked_machine,
      at: :at
    ]
  )

  subflow :work, label: "Work", subject: :ticket do
    owner(relation: :owner, capacity: [backend: [:codex], model: :any])
    start(:create)
    initial(:working)

    state :working, label: "Working" do
      present(expected: "work")
      branch(to: :done, when: "entity.result == 'done'")
      branch(to: :review, when: "entity.result == 'review'")
    end

    state :review, label: "Review" do
      owner(relation: :owner, capacity: [backend: [:codex], model: :any, differs_from: :working])
      present(expected: "review")
      branch(to: :done, when: "entity.result == 'done'")
    end

    final(:done)
  end

  select(:work,
    choices: [],
    projection: [field: :todo, state_field: :step, handover_field: :later, owner_relation: :owner],
    admission: [],
    imports: []
  )
end

defmodule CapacityProof.Module do
  use RelaDSL.Module, path: "modules/capacity/schema.yaml", concepts: [CapacityProof.Concepts]
end

defmodule CapacityProof.Model do
  use RelaDSL.Composition, name: "capacity-proof", subflow_behaviour: AtlasFlow.Subflow
  schema(version: "1.0", namespace: "https://example.invalid/capacity#", description: "Capacity")
  modules([CapacityProof.Module])
  environments([:prod, :test])

  defcomposition :capacity do
    subflows([CapacityProof.Concepts])
  end
end

defmodule CapacityProof.UncertainPort do
  def start_monitor(turn, opts) do
    owner = self()
    observer = Keyword.fetch!(opts, :observer)

    {pid, ref} =
      spawn_monitor(fn ->
        send(observer, {:adapter_ready, self(), turn})
        loop(owner, observer)
      end)

    {:ok, {pid, ref}}
  end

  def stop(pid), do: send(pid, :stop_requested)

  def stop_confirmed(pid) do
    send(pid, :stop_requested)
    {:error, :uncertain}
  end

  defp loop(owner, observer) do
    receive do
      :stop_requested ->
        send(observer, {:stop_requested, self()})
        loop(owner, observer)

      :confirmed_end ->
        send(owner, {:agent, self(), {:ended, "confirmed finished"}})
    end
  end
end

defmodule CapacityProof.Test do
  use ExUnit.Case, async: false
  alias AtlasFlow.{Capacity, Engine, ManualClock, Talk}
  alias AtlasFacts.{GuidanceStore, Rela}

  setup context do
    dir = Path.join(System.tmp_dir!(), "capacity-proof-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    previous = Application.get_env(:atlas_bus, :store)

    Application.put_env(
      :atlas_bus,
      :store,
      "capacity-proof-#{System.unique_integer([:positive])}"
    )

    on_exit(fn -> Application.put_env(:atlas_bus, :store, previous) end)

    {:ok, backend} =
      GuidanceStore.start(Path.join(dir, "facts.json"), CapacityProof.Model.rela_schema())

    on_exit(fn -> if Process.alive?(backend), do: Agent.stop(backend) end)
    rela = {GuidanceStore, backend}

    for key <- ["W-1", "W-2"],
        do: assert({:ok, []} = Rela.create(rela, "operators", key, %{}, %{}))

    assert {:ok, []} = Rela.create(rela, "readers", "viewer", %{"name" => "Viewer"}, %{})

    facts =
      start_supervised!(
        {AtlasFacts.Server,
         rela: rela, data_dir: Path.join(dir, "ledger"), model: CapacityProof.Model}
      )

    :ok = AtlasBus.attach("control/session-capacity-proof")
    assert %{"description" => %{}} = Talk.read("_description", %{})
    {:ok, clock} = ManualClock.start_link(~U[2026-11-14 00:00:00Z])
    on_exit(fn -> if Process.alive?(clock), do: Agent.stop(clock) end)

    engine =
      start_supervised!(
        {Engine, model: CapacityProof.Model, clock: {ManualClock, clock}, every: 3_600_000}
      )

    Engine.round(engine)

    settings = %{
      "pool" => %{
        "W-1" => %{
          "machine" => "proof",
          "backends" => ["codex"],
          "models" => %{"codex" => ["synthetic"]}
        }
      }
    }

    # Real Engine binding interface; hold reconciliation until the test starts execution.
    probe_agents =
      if context[:incompatible],
        do: %{"W-1" => %{"port" => "claude"}},
        else: %{"W-1" => %{"port" => "codex", "backend" => "codex", "model" => "synthetic"}}

    probe =
      start_supervised!(
        Supervisor.child_spec(
          {AtlasRuntime.Engine,
           model: CapacityProof.Model,
           machine: "proof",
           agents: %{"W-1" => context[:binding] || probe_agents["W-1"]},
           ports: %{"codex" => CapacityProof.UncertainPort},
           every: 3_600_000,
           lease: 60_000,
           silence: 600_000,
           max: 7_200_000},
          id: :binding_probe
        )
      )

    :sys.replace_state(probe, &%{&1 | turn: nil})

    opts = [
      model: CapacityProof.Model,
      clock: {ManualClock, clock},
      every: 3_600_000,
      settings: settings,
      registry: fn -> ["runtime@proof"] end,
      monotonic: fn -> DateTime.to_unix(ManualClock.now(clock), :millisecond) end
    ]

    on_exit(fn ->
      for {_, pid, {_agent, item}} <-
            Registry.select(AtlasRuntime.Turns, [
              {{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}
            ]),
          item in ["T-1", "T-2"] do
        adapter = AtlasRuntime.Turn.agent(pid)
        if is_pid(adapter) and Process.alive?(adapter), do: Process.exit(adapter, :kill)
        DynamicSupervisor.terminate_child(AtlasRuntime.Supervisor, pid)
      end
    end)

    %{capacity_opts: opts, engine: engine, clock: clock, dir: dir, rela: rela, facts: facts}
  end

  defp runtime(child) do
    stop_supervised!(:binding_probe)
    await_runtime_detached(100)
    start_supervised!(child)
  end

  defp await_runtime_detached(0), do: flunk("binding probe did not detach")

  defp await_runtime_detached(left) do
    if "runtime@proof" in AtlasBus.endpoints() do
      Process.sleep(1)
      await_runtime_detached(left - 1)
    end
  end

  defp capacity(opts), do: start_supervised!({Capacity, opts})

  defp read(kind, key) do
    %{"fact" => fact} = Talk.read(kind, %{"key" => key, "plain" => true})
    fact
  end

  defp create(key, engine) do
    assert {:stored, _} = Talk.put("ticket", %{"op" => "create", "key" => key, "values" => %{}})
    Engine.round(engine)
  end

  defp owner(key), do: get_in(read("ticket", key), ["links", "owner"]) || []

  defp change(key, values) do
    assert {:stored, _} =
             Talk.put("ticket", %{"op" => "change", "key" => key, "values" => values})
  end

  defp restart(opts) do
    stop_supervised!(Capacity)
    await_detached(100)
    capacity(opts)
  end

  defp await_detached(0), do: flunk("capacity endpoint was not released")

  defp await_detached(left) do
    if "flow/capacity" in AtlasBus.endpoints() do
      receive do
      after
        1 -> await_detached(left - 1)
      end
    end
  end

  test "two items and one slot: one runs, one waits, then the second runs", c do
    create("T-1", c.engine)
    ManualClock.advance(c.clock, 1)
    create("T-2", c.engine)
    scheduler = capacity(c.capacity_opts)
    assert :ok = Capacity.round(scheduler)
    assert owner("T-1") == ["W-1"]
    assert owner("T-2") == []
    # Real Runtime records the selected model, backend and pick; the injected port
    # performs no provider calls and remains alive until the test ends its turn.
    runtime =
      runtime(
        {AtlasRuntime.Engine,
         model: CapacityProof.Model,
         machine: "proof",
         agents: %{"W-1" => %{"port" => "codex", "backend" => "codex", "model" => "synthetic"}},
         ports: %{"codex" => AtlasRuntime.Agent.Stub},
         every: 3_600_000,
         lease: 60_000,
         silence: 600_000,
         max: 7200_000,
         turns_dir: c.dir}
      )

    AtlasRuntime.Engine.round(runtime)
    turn = await_turn("T-1")
    assert turn["values"]["pick"] == read("ticket", "T-1")["values"]["picked"]
    assert turn["values"]["backend"] == "codex"
    assert turn["values"]["model"] == "synthetic"
    assert owner("T-2") == []
    assert %{"waiting" => [%{"key" => "T-2", "position" => 1}]} = queue()
    change("T-1", %{"result" => "done"})
    Engine.round(c.engine)
    [{pid, _}] = Registry.lookup(AtlasRuntime.Turns, turn["key"])
    AtlasRuntime.Turn.finish(pid, "finished")
    monitor = Process.monitor(pid)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 2000
    Engine.round(c.engine)
    assert :ok = Capacity.round(scheduler)
    assert owner("T-2") == ["W-1"]
    AtlasRuntime.Engine.round(runtime)
    second = await_turn("T-2")
    assert second["values"]["backend"] == "codex"
    [{second_pid, _}] = Registry.lookup(AtlasRuntime.Turns, second["key"])
    assert is_pid(AtlasRuntime.Turn.agent(second_pid))
  end

  test "restart after a pick does not pick the slot twice; timeout recovers", c do
    create("T-1", c.engine)
    create("T-2", c.engine)
    scheduler = capacity(c.capacity_opts)
    assert :ok = Capacity.round(scheduler)
    first = read("ticket", "T-1")["values"]["picked"]
    first_at = read("ticket", "T-1")["values"]["at"]
    scheduler = restart(c.capacity_opts)
    assert :ok = Capacity.round(scheduler)
    assert read("ticket", "T-1")["values"]["picked"] == first
    assert owner("T-2") == []
    ManualClock.advance(c.clock, 120_000)
    assert :ok = Capacity.round(scheduler)
    assert read("ticket", "T-1")["values"]["at"] == first_at
    assert owner("T-1") == ["W-1"]
    assert owner("T-2") == []
  end

  for checkpoint <- [:turn_ended, :released] do
    test "restart after #{checkpoint} converges without double assignment", c do
      create("T-1", c.engine)
      create("T-2", c.engine)
      scheduler = capacity(c.capacity_opts)
      assert :ok = Capacity.round(scheduler)
      picked = read("ticket", "T-1")["values"]["picked"]

      assert {:ok, []} =
               Rela.create(
                 c.rela,
                 "runs",
                 "R-T-1-1",
                 %{
                   "state" => "ended",
                   "quiescent" => true,
                   "host" => "proof",
                   "pick" => picked,
                   "ended_at" => "2026-11-14T00:00:01Z"
                 },
                 %{"performer" => {"operator", ["W-1"]}, "task" => {"ticket", ["T-1"]}}
               )

      if unquote(checkpoint) == :released do
        # Commit just the conditional release, exactly the durable crash boundary.
        assert {:ok, []} =
                 Rela.change(
                   c.rela,
                   "tickets",
                   "T-1",
                   %{
                     "picked" => "",
                     "picked_entry" => "",
                     "vendor" => "",
                     "model" => "",
                     "at" => ""
                   },
                   nil,
                   %{"owner" => {"operator", []}}
                 )
      end

      AtlasFacts.Server.flush_collections(c.facts)
      scheduler = restart(c.capacity_opts)
      assert :ok = Capacity.round(scheduler)
      assert owner("T-1") == ["W-1"]
      assert owner("T-2") == []
      assert read("ticket", "T-1")["values"]["picked"] != picked
    end
  end

  test "manual clock enforces loss grace and its restart boot grace", c do
    create("T-1", c.engine)
    scheduler = capacity(c.capacity_opts)
    Capacity.round(scheduler)
    picked = read("ticket", "T-1")["values"]["picked"]

    assert {:ok, []} =
             Rela.create(
               c.rela,
               "runs",
               "R-T-1-1",
               %{
                 "state" => "running",
                 "host" => "proof",
                 "pick" => picked,
                 "lease" => "2026-11-15T00:00:00Z"
               },
               %{"performer" => {"operator", ["W-1"]}, "task" => {"ticket", ["T-1"]}}
             )

    AtlasFacts.Server.flush_collections(c.facts)
    disconnected = Keyword.put(c.capacity_opts, :registry, fn -> [] end)
    scheduler = restart(disconnected)
    ManualClock.advance(c.clock, 299_999)
    assert :ok = Capacity.round(scheduler)
    assert owner("T-1") == ["W-1"]
    scheduler = restart(disconnected)
    ManualClock.advance(c.clock, 1)
    assert :ok = Capacity.round(scheduler)
    assert owner("T-1") == ["W-1"]
    ManualClock.advance(c.clock, 299_999)
    assert :ok = Capacity.round(scheduler)
    assert owner("T-1") == ["W-1"]
    # A still-running turn keeps the released work out of the queue.
    assert %{"waiting" => [%{"key" => "T-1"}]} = queue()
  end

  test "hand-set assignees are never released, including stale pick metadata", c do
    create("T-1", c.engine)
    scheduler = capacity(c.capacity_opts)
    Capacity.round(scheduler)

    assert {:stored, _} =
             Talk.put("ticket", %{
               "op" => "change",
               "key" => "T-1",
               "links" => %{"owner" => ["W-2"]},
               "by" => "viewer"
             })

    ManualClock.advance(c.clock, 600_000)
    assert :ok = Capacity.round(scheduler)
    assert owner("T-1") == ["W-2"]
  end

  test "Workers read capability protects waiting data", c do
    create("T-1", c.engine)
    create("T-2", c.engine)
    scheduler = capacity(c.capacity_opts)
    Capacity.round(scheduler)

    model =
      AtlasControl.Model.catalog(
        CapacityProof.Model,
        %{"workers" => %{"read" => %{"actors" => ["viewer"]}}}
      )

    reader = fn
      "_capacity", _ -> queue()
      kind, query -> Talk.read(kind, query)
    end

    assert {:ok,
            %{
              "waiting" => [
                %{
                  "key" => "T-2",
                  "position" => 1,
                  "need" => %{"backend" => ["codex"], "model" => "any"},
                  "since" => since
                }
              ]
            }} =
             AtlasControl.Workers.board(model, %{key: "viewer", kind: "reader"}, reader)

    assert {:ok, _, _} = DateTime.from_iso8601(since)

    assert {:error, "forbidden"} =
             AtlasControl.Workers.board(model, %{key: "other", kind: "reader"}, fn _, _ ->
               flunk("unauthorized read")
             end)
  end

  test "fresh allocation survives history pruning and ignores a late result", c do
    create("T-1", c.engine)
    create("T-2", c.engine)
    scheduler = capacity(c.capacity_opts)
    Capacity.round(scheduler)
    old = read("ticket", "T-1")["values"]["picked"]
    entry = read("ticket", "T-1")["values"]["entry"]

    assert {:ok, []} =
             Rela.create(
               c.rela,
               "runs",
               "R-pruned",
               %{"state" => "ended", "quiescent" => true, "host" => "proof", "pick" => old},
               %{"performer" => {"operator", ["W-1"]}, "task" => {"ticket", ["T-1"]}}
             )

    # A confirmed end and its release committed before a crash; completed turn
    # history has subsequently been pruned. All selector inputs are unchanged.
    assert {:ok, []} =
             Rela.change(
               c.rela,
               "tickets",
               "T-1",
               %{"picked" => "", "picked_entry" => "", "vendor" => "", "model" => "", "at" => ""},
               nil,
               %{"owner" => {"operator", []}}
             )

    assert :ok = Rela.delete(c.rela, "runs", "R-pruned", nil)
    AtlasFacts.Server.flush_collections(c.facts)
    scheduler = restart(c.capacity_opts)
    assert :ok = Capacity.round(scheduler)
    new = read("ticket", "T-1")["values"]["picked"]
    assert new != old
    assert read("ticket", "T-1")["values"]["entry"] == entry

    # A delayed lifecycle write against a reused turn key is fenced by both
    # allocation and attempt, through the real Facts write path.
    assert {:ok, []} =
             Rela.create(
               c.rela,
               "runs",
               "R-reused",
               %{"state" => "running", "host" => "proof", "pick" => new, "attempt" => "a2"},
               %{"performer" => {"operator", ["W-1"]}, "task" => {"ticket", ["T-1"]}}
             )

    AtlasFacts.Server.flush_collections(c.facts)

    delayed =
      Task.async(fn ->
        :ok = AtlasBus.attach("runtime@proof/R-reused")

        Talk.put("run", %{
          "op" => "change",
          "key" => "R-reused",
          "by" => "runtime",
          "values" => %{"state" => "ended", "quiescent" => true},
          "was" => %{"pick" => old, "attempt" => "a1"}
        })
      end)

    assert {:refused, [_ | _]} = Task.await(delayed)
    assert read("run", "R-reused")["values"]["state"] == "running"

    assert {:ok, []} =
             Rela.create(
               c.rela,
               "runs",
               "R-late",
               %{
                 "state" => "ended",
                 "quiescent" => true,
                 "host" => "proof",
                 "pick" => old,
                 "ended_at" => "2026-11-14T00:00:01Z"
               },
               %{"performer" => {"operator", ["W-1"]}, "task" => {"ticket", ["T-1"]}}
             )

    AtlasFacts.Server.flush_collections(c.facts)
    assert :ok = Capacity.round(scheduler)
    assert read("ticket", "T-1")["values"]["picked"] == new
    assert owner("T-2") == []
  end

  test "loss, expired lease, silence and stop requests retain unknown executions", c do
    create("T-1", c.engine)
    create("T-2", c.engine)
    scheduler = capacity(c.capacity_opts)
    Capacity.round(scheduler)

    runtime =
      runtime(
        {AtlasRuntime.Engine,
         model: CapacityProof.Model,
         machine: "proof",
         agents: %{"W-1" => %{"port" => "codex", "backend" => "codex", "model" => "synthetic"}},
         ports: %{"codex" => CapacityProof.UncertainPort},
         port_opts: [observer: self()],
         every: 3_600_000,
         lease: 10,
         silence: 100,
         max: 7200_000,
         turns_dir: c.dir}
      )

    AtlasRuntime.Engine.round(runtime)
    assert_receive {:adapter_ready, adapter, _}, 2000
    on_exit(fn -> if Process.alive?(adapter), do: Process.exit(adapter, :kill) end)
    assert_receive {:stop_requested, ^adapter}, 2000
    turn = await_turn("T-1")
    [{pid, _}] = Registry.lookup(AtlasRuntime.Turns, turn["key"])
    AtlasRuntime.Turn.finish(pid, "stop requested")
    assert_receive {:stop_requested, ^adapter}, 2000
    ManualClock.advance(c.clock, 172_800_000)
    scheduler = restart(Keyword.put(c.capacity_opts, :registry, fn -> [] end))
    assert :ok = Capacity.round(scheduler)
    assert owner("T-1") == ["W-1"]
    assert owner("T-2") == []
    assert read("run", turn["key"])["values"]["state"] == "running"
    assert Process.alive?(adapter)
    # Reconnection and an orphaned execution owner also grant no duplicate start.
    DynamicSupervisor.terminate_child(AtlasRuntime.Supervisor, pid)
    AtlasRuntime.Engine.round(runtime)
    assert owner("T-2") == []
    assert read("run", turn["key"])["values"]["state"] == "running"
    %{"facts" => turns} = Talk.read("run", %{"plain" => true})
    assert length(turns) == 1
  end

  test "empty pools and a required different vendor remain waiting", c do
    create("T-1", c.engine)
    scheduler = capacity(Keyword.put(c.capacity_opts, :settings, %{"pool" => %{}}))
    assert :ok = Capacity.round(scheduler)
    assert owner("T-1") == []
    assert %{"waiting" => [%{"key" => "T-1"}]} = queue()
    scheduler = restart(Keyword.put(c.capacity_opts, :registry, fn -> :unavailable end))
    assert {:error, :registry_unavailable} = Capacity.round(scheduler)
    assert %{"error" => "capacity_unavailable"} = queue()
    scheduler = restart(c.capacity_opts)
    Capacity.round(scheduler)
    pick = read("ticket", "T-1")["values"]["picked"]

    assert {:ok, []} =
             Rela.create(
               c.rela,
               "runs",
               "R-author",
               %{
                 "state" => "ended",
                 "quiescent" => true,
                 "host" => "proof",
                 "pick" => pick,
                 "step" => "working",
                 "backend" => "codex",
                 "ended_at" => "2026-11-14T00:00:01Z"
               },
               %{"performer" => {"operator", ["W-1"]}, "task" => {"ticket", ["T-1"]}}
             )

    AtlasFacts.Server.flush_collections(c.facts)
    change("T-1", %{"result" => "review"})
    Engine.round(c.engine)
    assert :ok = Capacity.round(scheduler)
    assert owner("T-1") == []
    assert %{"waiting" => [%{"need" => %{"differs_from" => "working"}}]} = queue()
  end

  test "legacy ended records without quiescence cannot establish slot availability", c do
    create("T-1", c.engine)
    create("T-2", c.engine)

    assert {:ok, []} =
             Rela.create(
               c.rela,
               "runs",
               "R-legacy",
               %{"state" => "ended", "host" => "proof", "why" => "lease expired"},
               %{"performer" => {"operator", ["W-1"]}, "task" => {"ticket", ["T-1"]}}
             )

    AtlasFacts.Server.flush_collections(c.facts)
    scheduler = capacity(c.capacity_opts)
    assert :ok = Capacity.round(scheduler)
    assert owner("T-1") == [] and owner("T-2") == []
    assert %{"waiting" => [%{"key" => "T-1"}, %{"key" => "T-2"}]} = queue()
    # An explicit host reconciliation establishes quiescence; elapsed time did not.
    assert {:ok, []} = Rela.change(c.rela, "runs", "R-legacy", %{"quiescent" => true}, nil, %{})
    AtlasFacts.Server.flush_collections(c.facts)
    assert :ok = Capacity.round(scheduler)
    assert owner("T-1") == ["W-1"] and owner("T-2") == []
  end

  test "REVIEW stale durable run entry must prevent adapter admission", c do
    create("T-1", c.engine)
    scheduler = capacity(c.capacity_opts)
    assert :ok = Capacity.round(scheduler)
    :ok = :sys.suspend(c.engine)
    on_exit(fn -> if Process.alive?(c.engine), do: :sys.resume(c.engine) end)
    %{"facts" => [job]} = Talk.read("job", %{"plain" => true})
    old_entry = job["values"]["entry"]

    assert {:ok, []} =
             Rela.change(c.rela, "jobs", job["key"], %{"entry" => old_entry + 1}, nil, %{})

    AtlasFacts.Server.flush_collections(c.facts)

    runtime =
      runtime(
        {AtlasRuntime.Engine,
         model: CapacityProof.Model,
         machine: "proof",
         agents: %{"W-1" => %{"port" => "codex", "backend" => "codex", "model" => "synthetic"}},
         ports: %{"codex" => CapacityProof.UncertainPort},
         port_opts: [observer: self()],
         every: 3_600_000,
         lease: 60_000,
         silence: 600_000,
         max: 7_200_000,
         turns_dir: c.dir}
      )

    AtlasRuntime.Engine.round(runtime)
    refute_receive {:adapter_ready, _, _}, 300
  end

  @tag incompatible: true
  test "REVIEW unconfigured backend must stay waiting instead of inventing an Engine binding",
       c do
    create("T-1", c.engine)
    scheduler = capacity(c.capacity_opts)
    assert :ok = Capacity.round(scheduler)

    runtime =
      runtime(
        {AtlasRuntime.Engine,
         model: CapacityProof.Model,
         machine: "proof",
         agents: %{"W-1" => %{"port" => "claude"}},
         ports: %{"codex" => CapacityProof.UncertainPort},
         port_opts: [observer: self()],
         every: 3_600_000,
         lease: 60_000,
         silence: 600_000,
         max: 7_200_000,
         turns_dir: c.dir}
      )

    AtlasRuntime.Engine.round(runtime)
    refute_receive {:adapter_ready, _, _}, 300
  end

  test "REVIEW hand reassignment must not overlap an unconfirmed capacity execution", c do
    create("T-1", c.engine)
    scheduler = capacity(c.capacity_opts)
    assert :ok = Capacity.round(scheduler)

    runtime =
      runtime(
        {AtlasRuntime.Engine,
         model: CapacityProof.Model,
         machine: "proof",
         agents: %{
           "W-1" => %{"port" => "codex", "backend" => "codex", "model" => "synthetic"},
           "W-2" => %{"port" => "codex", "backend" => "codex", "model" => "synthetic"}
         },
         ports: %{"codex" => CapacityProof.UncertainPort},
         port_opts: [observer: self()],
         every: 3_600_000,
         lease: 60_000,
         silence: 600_000,
         max: 7_200_000,
         turns_dir: c.dir}
      )

    AtlasRuntime.Engine.round(runtime)
    assert_receive {:adapter_ready, first, _}, 2000

    assert {:stored, _} =
             Talk.put("ticket", %{
               "op" => "change",
               "key" => "T-1",
               "links" => %{"owner" => ["W-2"]},
               "by" => "viewer"
             })

    Engine.round(c.engine)
    AtlasRuntime.Engine.round(runtime)
    assert Process.alive?(first)
    refute_receive {:adapter_ready, _, _}, 300
  end

  test "separate Engine retains manual owner until confirmed original quiescence", c do
    create("T-1", c.engine)
    scheduler = capacity(c.capacity_opts)
    assert :ok = Capacity.round(scheduler)

    first_engine =
      runtime(
        {AtlasRuntime.Engine,
         model: CapacityProof.Model,
         machine: "proof",
         agents: %{"W-1" => %{"port" => "codex", "backend" => "codex", "model" => "synthetic"}},
         ports: %{"codex" => CapacityProof.UncertainPort},
         port_opts: [observer: self()],
         every: 3_600_000,
         lease: 60_000,
         silence: 600_000,
         max: 7_200_000,
         leave_grace: 0,
         turns_dir: c.dir}
      )

    AtlasRuntime.Engine.round(first_engine)
    assert_receive {:adapter_ready, first, original}, 2000
    assert original.capacity.pick == read("ticket", "T-1")["values"]["picked"]
    assert original.capacity.entry == read("ticket", "T-1")["values"]["entry"]

    assert {:stored, _} =
             Talk.put("ticket", %{
               "op" => "change",
               "key" => "T-1",
               "links" => %{"owner" => ["W-2"]},
               "by" => "viewer"
             })

    Engine.round(c.engine)

    second_engine =
      start_supervised!(
        Supervisor.child_spec(
          {AtlasRuntime.Engine,
           model: CapacityProof.Model,
           machine: "other",
           agents: %{"W-2" => %{"port" => "codex"}},
           ports: %{"codex" => CapacityProof.UncertainPort},
           port_opts: [observer: self()],
           every: 3_600_000,
           lease: 60_000,
           silence: 600_000,
           max: 7_200_000,
           turns_dir: c.dir},
          id: :other_engine
        )
      )

    AtlasRuntime.Engine.round(first_engine)
    AtlasRuntime.Engine.round(second_engine)
    assert Process.alive?(first)
    assert owner("T-1") == ["W-2"]

    assert {:refused, [_ | _]} =
             AtlasRuntime.Talk.put("run", %{
               "op" => "create",
               "key" => "R-bypass",
               "values" => %{"state" => "running", "host" => "other", "attempt" => "manual"},
               "links" => %{"performer" => ["W-2"], "task" => ["T-1"]},
               "by" => "runtime"
             })

    refute_receive {:adapter_ready, _, _}, 300
    [{pid, _}] = Registry.lookup(AtlasRuntime.Turns, original.key)
    monitor = Process.monitor(pid)
    send(first, :confirmed_end)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 2000
    assert read("run", original.key)["values"]["quiescent"] == true
    AtlasRuntime.Engine.round(second_engine)
    assert_receive {:adapter_ready, successor, %{agent: "W-2", capacity: nil}}, 2000
    assert owner("T-1") == ["W-2"]
    [{successor_pid, _}] = Registry.lookup(AtlasRuntime.Turns, "R-T-1-2")
    successor_monitor = Process.monitor(successor_pid)
    send(successor, :confirmed_end)
    assert_receive {:DOWN, ^successor_monitor, :process, ^successor_pid, _}, 2000
  end

  test "exact attempt rechecks same-state entry, generation and status through Facts", c do
    create("T-1", c.engine)
    scheduler = capacity(c.capacity_opts)
    assert :ok = Capacity.round(scheduler)

    runtime =
      runtime(
        {AtlasRuntime.Engine,
         model: CapacityProof.Model,
         machine: "proof",
         agents: %{"W-1" => %{"port" => "codex", "backend" => "codex", "model" => "synthetic"}},
         ports: %{"codex" => CapacityProof.UncertainPort},
         port_opts: [observer: self()],
         every: 3_600_000,
         lease: 60_000,
         silence: 600_000,
         max: 7_200_000,
         turns_dir: c.dir}
      )

    AtlasRuntime.Engine.round(runtime)
    assert_receive {:adapter_ready, adapter, turn}, 2000

    query = %{
      "key" => turn.key,
      "admission" => %{
        "attempt" => turn.attempt,
        "pick" => turn.capacity.pick,
        "entry" => turn.capacity.entry
      }
    }

    assert %{"admitted" => true} = Talk.read("run", query)

    assert %{"admitted" => false} =
             Talk.read("run", put_in(query, ["admission", "attempt"], "other"))

    assert %{"admitted" => false} =
             Talk.read("run", put_in(query, ["admission", "pick"], "other"))

    assert %{"admitted" => false} =
             Talk.read("run", put_in(query, ["admission", "entry"], "other"))

    :ok = :sys.suspend(c.engine)
    on_exit(fn -> if Process.alive?(c.engine), do: :sys.resume(c.engine) end)
    %{"facts" => [job]} = Talk.read("job", %{"plain" => true})

    for delta <- [
          %{"entry" => job["values"]["entry"] + 1},
          %{"generation" => job["values"]["generation"] + 1},
          %{"status" => "blocked"},
          %{"definition_sha256" => "unknown"},
          %{"state" => "done"}
        ] do
      assert {:ok, []} = Rela.change(c.rela, "jobs", job["key"], delta, nil, %{})
      assert %{"admitted" => false} = Talk.read("run", query)
      assert {:ok, []} = Rela.change(c.rela, "jobs", job["key"], job["values"], nil, %{})
      assert %{"admitted" => true} = Talk.read("run", query)
    end

    # The real restart constructor produces another durable generation in the
    # same state. Store commits the completed old generation before its successor.
    config = CapacityProof.Model.runs()
    flow = Enum.find(CapacityProof.Model.subflows(:test), &(&1.name() == "work"))
    assert {:ok, old_run} = AtlasFlow.Runs.Store.decode(config, job)

    assert {:ok, restarted} =
             AtlasFlow.Runs.Run.restart(
               Map.put(old_run, "status", "completed"),
               flow,
               read("ticket", "T-1"),
               ManualClock.now(c.clock)
             )

    assert restarted["state"] == old_run["state"]
    assert restarted["generation"] == old_run["generation"] + 1

    assert {:ok, []} =
             Rela.change(c.rela, "jobs", job["key"], %{"status" => "completed"}, nil, %{})

    assert %{"admitted" => false} = Talk.read("run", query)

    assert {:ok, []} =
             Rela.create(
               c.rela,
               "jobs",
               restarted["key"],
               AtlasFlow.Runs.Store.encode(config, restarted),
               %{}
             )

    assert %{"admitted" => false} = Talk.read("run", query)
    assert :ok = Rela.delete(c.rela, "jobs", restarted["key"], nil)
    assert {:ok, []} = Rela.change(c.rela, "jobs", job["key"], job["values"], nil, %{})
    assert %{"admitted" => true} = Talk.read("run", query)

    assert :ok = Rela.delete(c.rela, "jobs", job["key"], nil)
    assert %{"admitted" => false} = Talk.read("run", query)
    [{pid, _}] = Registry.lookup(AtlasRuntime.Turns, turn.key)
    monitor = Process.monitor(pid)
    send(adapter, :confirmed_end)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 2000
  end

  for binding <- [
        %{"port" => "claude", "command" => "/bin/echo"},
        %{"port" => "codex", "backend" => "codex", "model" => "wrong"},
        %{"port" => "unknown", "backend" => "codex", "model" => "synthetic"},
        %{
          "port" => "claude",
          "command" => "/bin/echo",
          "backends" => %{"codex" => %{"port" => "codex", "backend" => "codex"}}
        },
        %{
          "port" => "codex",
          "backend" => "codex",
          "model" => "synthetic",
          "command" => "/missing"
        }
      ] do
    @tag binding: binding
    test "unusable binding #{inspect(binding)} never reserves a slot", c do
      create("T-1", c.engine)

      if c[:binding]["command"] == "/missing" do
        [{probe, _}] = Registry.lookup(AtlasBus.Endpoints, "runtime@proof")
        :sys.replace_state(probe, &%{&1 | opts: Keyword.delete(&1.opts, :ports)})
      end

      scheduler = capacity(c.capacity_opts)
      assert :ok = Capacity.round(scheduler)
      assert owner("T-1") == []
      assert read("ticket", "T-1")["values"]["picked"] in [nil, ""]
      assert %{"waiting" => [%{"key" => "T-1", "why" => "no live slot fits"}]} = queue()
    end
  end

  test "matching backend map stands alone and enforces selected machine", _c do
    [{probe, _}] = Registry.lookup(AtlasBus.Endpoints, "runtime@proof")

    settings = %{
      "port" => "claude",
      "command" => "/foreign",
      "backends" => %{
        "codex" => %{"port" => "codex", "backend" => "codex", "model" => "synthetic"}
      }
    }

    :sys.replace_state(probe, &%{&1 | opts: Keyword.put(&1.opts, :agents, %{"W-1" => settings})})
    assert binding_request("proof", "codex", "synthetic")["ready"] == true
    assert binding_request("different", "codex", "synthetic")["ready"] == false
    assert binding_request("proof", "claude", "synthetic")["ready"] == false
    assert binding_request("proof", "codex", "other")["ready"] == false
  end

  test "Native refuses stale capacity admission before launching its host", c do
    turn = %{
      key: "native-refusal",
      item: "T-1",
      agent: "W-1",
      machine: "proof",
      capacity: %{pick: "p", entry: "e"},
      attempt: "a"
    }

    observer = self()

    opts = [
      turns_dir: c.dir,
      agent: %{
        "port" => "codex",
        "backend" => "codex",
        "model" => "synthetic",
        "command" => "/usr/bin/true",
        "workspace" => c.dir,
        "goal" => "synthetic",
        "sandbox" => "read-only"
      },
      admission: fn ->
        send(observer, {:native_admission, turn.capacity.pick, turn.attempt})
        {:error, :stale}
      end
    ]

    assert AtlasRuntime.Agent.Native.ready?(opts[:agent])
    assert {:error, _} = AtlasRuntime.Agent.Native.start_monitor(turn, opts)
    assert_receive {:native_admission, "p", "a"}, 1000
    refute File.exists?(Path.join(c.dir, "native-refusal"))

    assert {:error, _} =
             AtlasRuntime.Agent.Native.start_monitor(turn, Keyword.delete(opts, :admission))
  end

  test "dispatch rechecks incompatible settings after a valid reservation", c do
    create("T-1", c.engine)
    scheduler = capacity(c.capacity_opts)
    assert :ok = Capacity.round(scheduler)
    assert owner("T-1") == ["W-1"]
    picked = read("ticket", "T-1")["values"]["picked"]

    runtime =
      runtime(
        {AtlasRuntime.Engine,
         model: CapacityProof.Model,
         machine: "proof",
         agents: %{"W-1" => %{"port" => "claude", "command" => "/foreign"}},
         ports: %{"codex" => CapacityProof.UncertainPort},
         port_opts: [observer: self()],
         every: 3_600_000,
         lease: 60_000,
         silence: 600_000,
         max: 7_200_000,
         turns_dir: c.dir}
      )

    AtlasRuntime.Engine.round(runtime)
    refute_receive {:adapter_ready, _, _}, 300
    assert :ok = Capacity.round(scheduler)
    assert read("ticket", "T-1")["values"]["picked"] == picked

    assert %{
             "waiting" => [
               %{"key" => "T-1", "why" => "execution binding unavailable; reservation retained"}
             ]
           } = queue()
  end

  defp binding_request(machine, backend, model) do
    e = %{AtlasBus.Envelope.new("request", "_capacity_binding") | address: "runtime@proof"}

    :ok =
      AtlasBus.send(e, %{
        "agent" => "W-1",
        "machine" => machine,
        "backend" => backend,
        "model" => model
      })

    receive do
      {:atlas_bus, %{id: id, class: "answer"}, answer} when id == e.id -> answer
    after
      1000 -> flunk("binding did not answer")
    end
  end

  defp queue do
    e = %{AtlasBus.Envelope.new("request", "_capacity") | address: "flow/capacity"}
    :ok = AtlasBus.send(e, %{})

    receive do
      {:atlas_bus, %{id: id, class: "answer"}, answer} when id == e.id -> answer
    after
      2000 -> flunk("capacity queue did not answer")
    end
  end

  for boundary <- [:advanced_entry, :read_failure] do
    test "INDEPENDENT durable authority #{boundary} after turn commit prevents adapter startup",
         c do
      create("T-1", c.engine)
      scheduler = capacity(c.capacity_opts)
      assert :ok = Capacity.round(scheduler)
      :ok = :sys.suspend(c.engine)
      on_exit(fn -> if Process.alive?(c.engine), do: :sys.resume(c.engine) end)
      %{"facts" => [job]} = Talk.read("job", %{"plain" => true})
      {GuidanceStore, backend} = c.rela
      GuidanceStore.barrier(backend, self(), "runs")

      runtime(
        {AtlasRuntime.Engine,
         model: CapacityProof.Model,
         machine: "proof",
         agents: %{"W-1" => %{"port" => "codex", "backend" => "codex", "model" => "synthetic"}},
         ports: %{"codex" => CapacityProof.UncertainPort},
         port_opts: [observer: self()],
         every: 3_600_000,
         lease: 60000,
         silence: 600_000,
         max: 7_200_000,
         turns_dir: c.dir}
      )

      assert_receive {:committed, ^backend, "R-T-1-1"}, 2000

      if unquote(boundary) == :advanced_entry do
        file = Path.join(c.dir, "facts.json")
        contents = file |> File.read!() |> JSON.decode!()

        contents =
          put_in(
            contents,
            ["jobs", job["key"], "properties", "entry"],
            job["values"]["entry"] + 1
          )

        File.write!(file, JSON.encode!(contents), [:sync])
        send(backend, :release_commit)
      else
        send(backend, {:release_commit, {:fail_get, "jobs", job["key"], :unavailable}})
      end

      refute_receive {:adapter_ready, _, _}, 500
      %{"facts" => [turn]} = Talk.read("run", %{"plain" => true})
      assert turn["values"]["state"] == "running"
      refute turn["values"]["quiescent"] == true
      assert read("ticket", "T-1")["values"]["picked"] not in [nil, ""]
    end
  end

  test "INDEPENDENT live Turn completion retries without a new adapter or lease", c do
    create("T-1", c.engine)
    scheduler = capacity(c.capacity_opts)
    assert :ok = Capacity.round(scheduler)

    runtime =
      runtime(
        {AtlasRuntime.Engine,
         model: CapacityProof.Model,
         machine: "proof",
         agents: %{"W-1" => %{"port" => "codex", "backend" => "codex", "model" => "synthetic"}},
         ports: %{"codex" => CapacityProof.UncertainPort},
         port_opts: [observer: self()],
         every: 3_600_000,
         lease: 20,
         silence: 600_000,
         max: 7_200_000,
         turns_dir: c.dir}
      )

    AtlasRuntime.Engine.round(runtime)
    assert_receive {:adapter_ready, adapter, turn}, 2000
    [{pid, _}] = Registry.lookup(AtlasRuntime.Turns, turn.key)
    monitor = Process.monitor(pid)

    assert {:ok, []} =
             Rela.change(c.rela, "runs", turn.key, %{"attempt" => "replacement"}, nil, %{})

    send(adapter, :confirmed_end)
    Process.sleep(100)
    assert Process.alive?(pid)
    pending = :sys.get_state(pid)
    assert pending.pending_end != nil
    assert pending.agent_pid == nil
    assert pending.attempt == turn.attempt
    assert pending.confirmed_quiescent
    {GuidanceStore, backend} = c.rela
    assert {:ok, before_retry} = GuidanceStore.get(backend, "runs", turn.key)
    Process.sleep(100)
    assert {:ok, ^before_retry} = GuidanceStore.get(backend, "runs", turn.key)
    refute_receive {:adapter_ready, _, _}, 50
    assert :ok = Capacity.round(scheduler)
    assert read("ticket", "T-1")["values"]["picked"] == turn.capacity.pick

    assert {:ok, []} =
             Rela.change(c.rela, "runs", turn.key, %{"attempt" => turn.attempt}, nil, %{})

    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 2000
    assert {:ok, completed} = GuidanceStore.get(backend, "runs", turn.key)
    assert completed.properties["state"] == "ended"
    assert completed.properties["quiescent"] == true
    assert completed.properties["lease"] in [nil, ""]
    refute_receive {:adapter_ready, _, _}, 50
  end

  defp await_turn(item, attempts \\ 100)
  defp await_turn(_item, 0), do: flunk("Runtime did not start the picked work")

  defp await_turn(item, attempts) do
    %{"facts" => turns} = Talk.read("run", %{"plain" => true})

    case Enum.find(
           turns,
           &(get_in(&1, ["links", "task"]) == [item] and &1["values"]["state"] == "running")
         ) do
      nil ->
        receive do
        after
          10 -> await_turn(item, attempts - 1)
        end

      turn ->
        turn
    end
  end
end
