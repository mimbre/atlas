# Cross-layer proof: production Runtime still communicates only through Bus.
# Run with MIX_ENV=test mix run integration/runtime_guidance.exs.
ExUnit.start(seed: 0)

defmodule AtlasRuntime.RuntimeGuidanceTest do
  use ExUnit.Case, async: false
  alias AtlasRuntime.{Engine, GuidancePort, Talk}
  alias AtlasRuntime.Agent.FakeInbox
  alias AtlasFacts.{GuidanceStore, Rela}
  @moduletag :tmp_dir
  # Runtime and Facts run the neutral guided model; its store serves the model's schema.
  @model AtlasRuntime.TestModel.Guided
  defp description, do: AtlasRuntime.FakeFacts.description_of(@model)

  setup %{tmp_dir: dir} do
    :ets.new(GuidancePort, [:named_table, :public])

    Application.put_env(
      :atlas_bus,
      :store,
      "runtime-guidance-#{System.unique_integer([:positive])}"
    )

    d = description()
    {:ok, store} = GuidanceStore.start(Path.join(dir, "facts.json"), @model.rela_schema())
    rela = {GuidanceStore, store}
    {:ok, []} = Rela.create(rela, "clerks", "ada", %{}, %{})

    {:ok, []} =
      Rela.create(rela, "cards", "card-a", %{"step" => "packing", "later" => ""}, %{
        "owned_by" => {"clerk", ["ada"]}
      })

    # The box whose work the card carries: Facts presents the work on a card for the box
    # that points at it (the model's legacy flow runs on boxes and writes on their card).
    {:ok, _} = Rela.create(rela, "boxes", "box-a", %{}, %{"card" => {"card", ["card-a"]}})

    server =
      start_supervised!(
        {AtlasFacts.Server, rela: rela, data_dir: Path.join(dir, "facts"), model: @model}
      )

    :ok = AtlasBus.attach("control/session-runtime-test")

    opts = [
      machine: "here",
      agents: %{"ada" => %{"port" => "proof"}},
      ports: %{"proof" => GuidancePort},
      port_opts: [observer: self(), inbox_root: Path.join(dir, "inboxes")],
      guidance_every: :manual,
      every: 60_000,
      silence: 60_000,
      max: 300_000,
      lease: 60_000,
      crash_pause: 10,
      leave_grace: 10,
      model: @model
    ]

    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(AtlasRuntime.Supervisor),
          do: DynamicSupervisor.terminate_child(AtlasRuntime.Supervisor, pid)
    end)

    %{d: d, opts: opts, rela: rela, store: store, dir: dir, server: server}
  end

  defp direct_change(c, plural, key, props, version, targets) do
    result = Rela.change(c.rela, plural, key, props, version, targets)
    :ok = AtlasFacts.Server.flush_collections(c.server)
    result
  end

  defp boot(c) do
    engine = start_supervised!({Engine, c.opts})
    assert_receive {:started, inbox, turn}, 5_000
    [{pid, _}] = Registry.lookup(AtlasRuntime.Turns, turn.key)
    {engine, pid, inbox, turn}
  end

  defp execution(t) do
    %{"fact" => ex} = Talk.read("synthetic_execution", %{"turn" => t.key, "attempt" => t.attempt})
    ex
  end

  defp submit(t, client \\ "client", body \\ "/literal\nstop/status are user text") do
    ex = execution(t)

    {:stored, %{"fact" => i}, _} =
      Talk.fact("synthetic_interaction", %{
        "op" => "submit_interaction",
        "by" => "reader",
        "values" => %{
          "client_key" => client,
          "body" => body,
          "worker" => t.agent,
          "turn" => t.key,
          "attempt" => t.attempt,
          "mode" => "queued_guidance",
          "execution" => ex["key"],
          "cause" => "test input"
        }
      })

    i
  end

  defp identity(t, i),
    do: %{
      "environment" => AtlasBus.environment(),
      "worker" => t.agent,
      "turn" => t.key,
      "attempt" => t.attempt,
      "interaction" => i["key"]
    }

  defp current(i), do: Talk.read("synthetic_interaction", %{"key" => i["key"]})["fact"]

  defp reconcile(pid) do
    send(pid, :guidance)
    # This normal call shares sender ordering with the hint; system introspection
    # alone is not a mailbox barrier for that ordinary guidance message.
    AtlasRuntime.Turn.agent(pid)
    :sys.get_state(pid)
  end

  test "execution commit precedes startup even when its acknowledgement is lost", c do
    GuidanceStore.barrier(c.store, self(), "executions")
    # Facts/DETS restart must fit the request deadline. A 30 ms timeout measured
    # incidental scheduler speed rather than the recovery guarantee.
    opts = Keyword.put(c.opts, :talk_opts, tries: 1, wait: 1_000)
    engine = start_supervised!({Engine, opts})
    # Fixture plural is executions; wait for Facts' durable commit before any start.
    assert_receive {:committed, store, _key}, 2_000
    refute_receive {:starting, _, _}, 20
    # Kill the reply owner after backend commit, then reopen Facts' retained ledger.
    Process.exit(c.server, :kill)
    send(store, :release_commit)
    assert_receive {:started, _inbox, turn}, 5_000
    assert execution(turn)["turn"] == turn.key
    assert :ok = Engine.round(engine)
  end

  test "unconfirmed execution registration never starts an adapter", c do
    # Block after durable turn create, then make the execution authority read fail.
    GuidanceStore.barrier(c.store, self(), "runs")
    start_supervised!({Engine, c.opts})
    assert_receive {:committed, store, key}, 2_000
    [{pid, _}] = Registry.lookup(AtlasRuntime.Turns, key)
    monitor = Process.monitor(pid)
    send(store, {:release_commit, {:fail_get, "runs", key, :unavailable}})
    assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 2_000
    {:ok, fact} = Rela.get(c.rela, "runs", key)
    assert fact.properties["status"] == "over"

    refute_receive {:starting, _, _}, 20
    refute_receive {:started, _, _}, 20
  end

  test "ordinary durable acknowledgement tolerates bounded backend latency", c do
    GuidanceStore.barrier(c.store, self(), "executions")
    start_supervised!({Engine, c.opts})
    assert_receive {:committed, store, _}, 2_000
    # Deterministically exceed the fixture's old30ms request deadline without CPU load.
    Process.sleep(100)
    send(store, :release_commit)
    assert_receive {:started, _, _}, 2_000
  end

  test "turn and execution are durable before adapter start, with exact immutable identity", c do
    {_engine, _pid, inbox, t} = boot(c)
    ex = execution(t)
    assert ex["attempt"] == t.attempt
    assert ex["queued_input"]
    assert {:ok, fact} = Rela.get(c.rela, "runs", t.key)
    assert fact.properties["fence"] == t.attempt
    assert fact.properties["host"] == "here"
    assert FakeInbox.capabilities(inbox) |> elem(0) == :ok
  end

  test "literal admission and correlated consumption append receipts without renewing activity",
       c do
    {_engine, pid, inbox, t} = boot(c)
    before = :sys.get_state(pid)
    i = submit(t)
    reconcile(pid)
    assert current(i)["projection"]["proven"] == "delivered"
    assert {:ok, proof} = FakeInbox.consume(inbox, identity(t, i))
    assert proof["stage"] == "consumed"
    reconcile(pid)
    assert current(i)["projection"]["proven"] == "acknowledged"
    assert {:ok, body} = FakeInbox.context_input(inbox, identity(t, i))
    assert body == i["body"]
    after_state = :sys.get_state(pid)

    assert {before.active, before.written, before.since} ==
             {after_state.active, after_state.written, after_state.since}

    count = current(i)["receipt_count"]
    for _ <- 1..3, do: reconcile(pid)
    assert current(i)["receipt_count"] == count
  end

  test "lost admission ack is recovered by query, never a second blind accept", c do
    {_engine, pid, inbox, t} = boot(c)
    :ets.insert(GuidancePort, {:lose_accept_ack, true})
    i = submit(t)
    reconcile(pid)
    assert current(i)["projection"]["uncertain"]
    assert current(i)["projection"]["proven"] == "queued"
    assert_receive {:accepting, ^inbox, _}
    reconcile(pid)
    assert current(i)["projection"]["proven"] == "delivered"
    refute_receive {:accepting, ^inbox, _}, 20
  end

  test "unavailable native query is uncertainty, not absence or retry permission", c do
    {_engine, pid, inbox, t} = boot(c)
    :ets.insert(GuidancePort, {:query_fault, :unavailable})
    i = submit(t)
    reconcile(pid)
    assert current(i)["projection"]["uncertain"]
    refute_receive {:accepting, ^inbox, _}, 20
    :ets.delete(GuidancePort, :query_fault)
    reconcile(pid)
    assert current(i)["projection"]["proven"] == "delivered"
  end

  test "outcome and transferred ownership close original target without retargeting", c do
    {_engine, pid, inbox, t} = boot(c)
    i = submit(t)

    {:ok, []} =
      direct_change(c, "cards", "card-a", %{}, nil, %{"owned_by" => {"clerk", ["other"]}})

    reconcile(pid)
    assert "stale" in current(i)["projection"]["closures"]
    assert {:not_admitted, _} = FakeInbox.query(inbox, identity(t, i))

    {:ok, []} =
      direct_change(c, "cards", "card-a", %{}, nil, %{"owned_by" => {"clerk", ["ada"]}})

    reconcile(pid)
    assert {:not_admitted, _} = FakeInbox.query(inbox, identity(t, i))
    j = submit(t, "outcome")

    {:stored, _, _} =
      Talk.fact("run", %{
        "op" => "change",
        "key" => t.key,
        "values" => %{"result" => "done"},
        "by" => "reader",
        "cause" => "finished"
      })

    reconcile(pid)
    reconcile(pid)
    assert "stale" in current(j)["projection"]["closures"]
  end

  test "handover barrier pauses admission while Flow retains owner", c do
    {_engine, pid, inbox, t} = boot(c)
    i = submit(t)
    {:ok, []} = direct_change(c, "cards", "card-a", %{"later" => "held"}, nil, %{})
    reconcile(pid)
    assert {:not_admitted, _} = FakeInbox.query(inbox, identity(t, i))
    assert current(i)["projection"]["closures"] == []
    {:ok, []} = direct_change(c, "cards", "card-a", %{"later" => ""}, nil, %{})
    reconcile(pid)
    assert current(i)["projection"]["proven"] == "delivered"
  end

  test "activity and forged guidance events cannot manufacture evidence", c do
    {_engine, pid, inbox, t} = boot(c)
    i = submit(t)
    :ets.insert(GuidancePort, {:query_fault, :unavailable})
    send(pid, {:agent, inbox, {:activity, "acknowledged"}})
    send(pid, {:agent, inbox, {:guidance, %{"stage" => "consumed"}}})
    :sys.get_state(pid)
    assert current(i)["projection"]["proven"] == "queued"
  end

  test "orphan restart closes input and reconciles historical proof without starting a model",
       c do
    {engine, pid, inbox, t} = boot(c)
    i = submit(t)
    reconcile(pid)
    assert {:ok, _} = FakeInbox.consume(inbox, identity(t, i))
    # Lose a Facts receipt acknowledgement by preventing the next local reconciliation.
    Process.exit(pid, :kill)
    monitor = Process.monitor(inbox)
    assert_receive {:DOWN, ^monitor, :process, ^inbox, _}, 2_000
    # records orphan end
    assert :ok = Engine.round(engine)
    # historical proof recovery only
    assert :ok = Engine.round(engine)
    assert current(i)["projection"]["proven"] == "acknowledged"
    assert_receive {:recovering, %{key: key}}, 2_000
    assert key == t.key
    # No replay through adapter start for the old attempt.
    refute_receive {:started, _, %{key: ^key}}, 20
  end

  test "unavailable Facts eligibility never becomes an absent target", c do
    {_engine, pid, inbox, t} = boot(c)
    i = submit(t)
    GuidanceStore.fail_next_get(c.store, "runs", t.key, :unavailable)
    reconcile(pid)
    assert current(i)["projection"]["uncertain"]
    assert {:not_admitted, _} = FakeInbox.query(inbox, identity(t, i))
    refute_receive {:accepting, ^inbox, _}, 20
  end

  test "expired Facts lease and local budget prohibit admission without renewing either", c do
    {_engine, pid, inbox, t} = boot(c)
    i = submit(t)
    {:ok, []} = direct_change(c, "runs", t.key, %{"until" => "2000-01-01T00:00:00Z"}, nil, %{})
    reconcile(pid)
    assert "stale" in current(i)["projection"]["closures"]
    assert {:not_admitted, _} = FakeInbox.query(inbox, identity(t, i))
    j = submit(t, "budget")
    :sys.replace_state(pid, fn state -> %{state | since: state.since - state.max} end)
    for _ <- 1..2, do: reconcile(pid)
    assert "stale" in current(j)["projection"]["closures"]
  end

  test "in-flight adapter admission enforces the original deadline", c do
    opts =
      Keyword.update!(c.opts, :port_opts, &Keyword.put(&1, :barrier, {self(), :before_accept}))

    {_engine, pid, inbox, t} = boot(%{c | opts: opts})
    i = submit(t)
    # Persisted lease grants only a short admission window, while local budget stays long.
    until = DateTime.utc_now() |> DateTime.add(1, :second) |> DateTime.to_iso8601()
    {:ok, []} = direct_change(c, "runs", t.key, %{"until" => until}, nil, %{})
    send(pid, :guidance)
    assert_receive {:inbox_barrier, ^inbox, :before_accept, _}, 2_000
    # Deterministic typed expired deadline is tested directly below; here await wall lease.
    Process.sleep(1_050)
    send(inbox, {:release, :before_accept})
    :sys.get_state(pid)
    assert {:not_admitted, _} = FakeInbox.query(inbox, identity(t, i))
    assert "stale" in current(i)["projection"]["closures"]
  end

  test "closed attempt recovers pending as stale and never sends to a successor", c do
    {engine, pid, inbox, t} = boot(c)
    i = submit(t)
    # Prevent Flow-independent new starts during historical reconciliation.
    {:ok, []} = direct_change(c, "cards", "card-a", %{"later" => "held"}, nil, %{})
    monitor = Process.monitor(pid)
    AtlasRuntime.Turn.finish(pid, "done")
    assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 2_000
    assert :ok = Engine.round(engine)
    assert current(i)["projection"]["proven"] == "queued"
    assert "stale" in current(i)["projection"]["closures"]
    refute Process.alive?(inbox)
    refute_receive {:started, _, _}, 20
  end

  test "named inbox loss retains uncertainty after Runtime restart", c do
    {engine, pid, inbox, t} = boot(c)
    i = submit(t)
    reconcile(pid)
    history = Path.join([c.dir, "inboxes", t.key, "inbox.dets"])
    File.rename!(history, history <> ".retained")
    Process.exit(pid, :kill)
    monitor = Process.monitor(inbox)
    assert_receive {:DOWN, ^monitor, :process, ^inbox, _}, 2_000
    {:ok, []} = direct_change(c, "cards", "card-a", %{"later" => "held"}, nil, %{})
    Engine.round(engine)
    Engine.round(engine)
    assert current(i)["projection"]["uncertain"]
    assert current(i)["projection"]["proven"] == "delivered"
    assert File.exists?(history <> ".retained")
  end

  test "bounded pages reconcile every queued interaction and repeated hints do not duplicate receipts",
       c do
    {_engine, pid, inbox, t} = boot(c)
    inputs = for n <- 1..4, do: submit(t, "page-#{n}")
    reconcile(pid)
    assert Enum.count(inputs, &(current(&1)["projection"]["proven"] == "delivered")) == 1
    for _ <- 1..8, do: reconcile(pid)

    for i <- inputs do
      assert current(i)["projection"]["proven"] == "delivered"
      assert current(i)["receipt_count"] == 1
      assert {:ok, _} = FakeInbox.query(inbox, identity(t, i))
    end
  end

  test "periodic reconciliation works when the interaction hint is dropped", c do
    opts = Keyword.put(c.opts, :guidance_every, 25)
    {_engine, _pid, _inbox, t} = boot(%{c | opts: opts})
    AtlasBus.drop_hints(1)
    i = submit(t)
    eventually(fn -> current(i)["projection"]["proven"] == "delivered" end)
  end

  test "closure concurrent with native commit preserves evidence and reports boundary uncertainty",
       c do
    opts =
      Keyword.update!(c.opts, :port_opts, &Keyword.put(&1, :barrier, {self(), :before_accept}))

    {_engine, pid, inbox, t} = boot(%{c | opts: opts})
    i = submit(t)
    send(pid, :guidance)
    assert_receive {:inbox_barrier, ^inbox, :before_accept, _}, 2_000
    # Eligibility was read before dispatch. This external Facts closure has no native
    # transaction with the harness. Its historical admission must not be hidden.
    {:stored, _, _} =
      Talk.fact("run", %{
        "op" => "change",
        "key" => t.key,
        "values" => %{"result" => "done"},
        "by" => "reader",
        "cause" => "concurrent close"
      })

    send(inbox, {:release, :before_accept})
    :sys.get_state(pid)
    assert current(i)["projection"]["proven"] == "delivered"
    assert current(i)["projection"]["uncertain"]
    assert {:ok, _} = FakeInbox.query(inbox, identity(t, i))
  end

  test "configured model and adapter options survive exact historical consumption recovery", c do
    opts =
      c.opts
      |> Keyword.update!(:agents, &put_in(&1, ["ada", "model"], "private-configured-model"))
      |> Keyword.merge(
        stub_dir: "private-stub",
        turns_dir: "private-turns",
        env_file: "private-env",
        atlas_bin: "private-atlas"
      )

    {engine, pid, inbox, t} = boot(%{c | opts: opts})
    ex = execution(t)
    assert ex["configured_model"] == "private-configured-model"
    i = submit(t)
    reconcile(pid)
    assert current(i)["projection"]["proven"] == "delivered"
    :sys.suspend(pid)
    assert {:ok, consumed} = FakeInbox.consume(inbox, identity(t, i))
    Process.exit(pid, :kill)
    monitor = Process.monitor(inbox)
    assert_receive {:DOWN, ^monitor, :process, ^inbox, _}, 2_000
    assert current(i)["projection"]["proven"] == "delivered"
    {:ok, []} = direct_change(c, "cards", "card-a", %{"later" => "held"}, nil, %{})
    Engine.round(engine)
    Engine.round(engine)
    assert current(i)["projection"]["proven"] == "acknowledged"
    assert_receive {:recovering, %{execution: ^ex}}
    assert_receive {:recovery_options, recovered_opts}
    assert recovered_opts[:inbox_root] == opts[:port_opts][:inbox_root]
    assert recovered_opts[:observer] == self()
    %{"facts" => receipts} = Talk.read("synthetic_receipt", %{"interaction" => i["key"]})
    ack = Enum.find(receipts, &(&1["stage"] == "acknowledged"))
    assert ack["admission_id"] == consumed["admission_id"]
    assert ack["consumption_id"] == consumed["consumption_id"]
    assert recovered_opts[:agent] == opts[:agents]["ada"]

    for key <- [:stub_dir, :turns_dir, :env_file, :atlas_bin],
        do: assert(recovered_opts[key] == opts[key])

    assert execution(t) == ex
  end

  test "changed model configuration cannot query history as the original execution", c do
    opts = Keyword.update!(c.opts, :agents, &put_in(&1, ["ada", "model"], "original-model"))
    {engine, pid, inbox, t} = boot(%{c | opts: opts})
    ex = execution(t)
    i = submit(t)
    reconcile(pid)
    :sys.suspend(pid)
    assert {:ok, _} = FakeInbox.consume(inbox, identity(t, i))
    Process.exit(pid, :kill)
    monitor = Process.monitor(inbox)
    assert_receive {:DOWN, ^monitor, :process, ^inbox, _}, 2_000
    {:ok, []} = direct_change(c, "cards", "card-a", %{"later" => "held"}, nil, %{})
    changed = Keyword.update!(opts, :agents, &put_in(&1, ["ada", "model"], "changed-model"))
    :sys.replace_state(engine, fn state -> %{state | opts: changed} end)
    Engine.round(engine)
    Engine.round(engine)
    assert current(i)["projection"]["proven"] == "delivered"
    assert current(i)["projection"]["uncertain"]
    key = t.key
    refute_receive {:recovering, %{key: ^key}}, 20
    assert execution(t) == ex
    # Restoring the original binding can recover its retained proof, without erasing
    # uncertainty or rewriting immutable model provenance.
    :sys.replace_state(engine, fn state -> %{state | opts: opts} end)
    Engine.round(engine)
    assert current(i)["projection"]["proven"] == "acknowledged"
    assert current(i)["projection"]["uncertain"]
    assert execution(t) == ex
  end

  defp eventually(fun, remaining \\ 50)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, n) do
    if not fun.() do
      Process.sleep(20)
      eventually(fun, n - 1)
    end
  end
end
