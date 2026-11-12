# Boot Flow over a pre-upgrade store. No native service or real timer is needed.
ExUnit.start()

defmodule MigrationGate do
  use GenServer
  alias AtlasBus.{Digest, Envelope, SubjectFingerprint}
  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  def init(_) do
    :ok = AtlasBus.attach("gates")
    {:ok, []}
  end

  def handle_call(:calls, _, calls), do: {:reply, calls, calls}

  def handle_info({:atlas_bus, e, intent}, calls) do
    definition = %{"fields" => [], "relations" => []}
    fingerprint = SubjectFingerprint.of(%{"values" => %{}, "links" => %{}}, definition)

    request = %{
      "subject" => intent["subject"],
      "gate_version" => 1,
      "fingerprint_definition" => definition,
      "fingerprint" => fingerprint,
      "evidence" => %{},
      "evidence_digest" => Digest.of_term(%{}),
      "allowed_outcomes" => ["person"]
    }

    reply =
      if intent["operation"] == "prepare" do
        Map.put(intent, "request", request)
      else
        Map.merge(intent, %{
          "fingerprint" => fingerprint,
          "evidence_digest" => Digest.of_term(%{}),
          "outcome" => "person",
          "recorded" => "V-#{intent["id"]}"
        })
      end

    AtlasBus.send(Envelope.reply(e, "answer"), reply)
    {:noreply, [{intent["operation"], intent["subject"], intent["entry"]} | calls]}
  end
end

defmodule FlowMigrationBootTest do
  use ExUnit.Case, async: false
  alias AtlasFlow.{Engine, FakeFacts, ManualClock}
  alias AtlasFlow.Runs.{Run, Store}
  @now ~U[2026-11-12 00:00:00Z]
  # Slice 1's deployed definition digest, retained in the sidecar migration table.
  @old "8ca16b332a083209e6e44ffc3feeca0f152c632caa4d5206ab24fe540ab3770c"

  # The model Flow runs (its compiled decide and its runs), without its legacy flows: only
  # the runs boot here.
  defmodule Runs do
    @behaviour AtlasFlow.Model
    defdelegate subflows(env), to: Model.AtlasEyra
    defdelegate runs(), to: Model.AtlasEyra
    defdelegate selection(name), to: Model.AtlasEyra
    defdelegate migrations(), to: Model.AtlasEyra
    defdelegate actors(), to: Model.AtlasEyra
    def legacy, do: []
  end

  defp decide(env), do: AtlasFlow.Model.load(Runs, env).flows["decide"]

  # The canonical decide digests deployed before owner answers (test, prod).
  @answerless %{
    "test" => "e2d4c41b758cb858aa40b2835c703f2c42f60039471f855fa7e2df0dbf171b4b",
    "prod" => "d9aadf74d08e0fb4ee4ada4d17980c10aafd4424f251061779cbd61b1c01c7aa"
  }

  test "deploy boot migrates old cursors, preserves finals, and admits missed starts" do
    dir = Path.join(System.tmp_dir!(), "flow-migration-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    Application.put_env(:atlas_bus, :store, "migration-boot")
    config = AtlasFlow.Model.load(Runs, :test).config
    start_supervised!({FakeFacts, description: %{"entities" => %{}}})
    start_supervised!(MigrationGate)
    clock = start_supervised!({ManualClock, @now})
    flow = decide(:test)

    originals =
      for {key, state, import?} <- [
            {"D-active", "proposed", false},
            {"D-final-a", "accepted", false},
            {"D-final-r", "rejected", false},
            {"D-history", "accepted", true},
            {"D-unknown", "proposed", false}
          ],
          into: %{} do
        status = if state == "proposed", do: "proposed", else: state
        status = if import?, do: "superseded", else: status
        subject = %{"key" => key, "values" => %{"status" => status}}
        FakeFacts.put("decision", subject)
        run = Run.new("decide", flow, subject, config["selection"]["decide"]["imports"], @now)

        run =
          Map.merge(run, %{
            "definition_sha256" =>
              if(key == "D-unknown", do: String.duplicate("f", 64), else: @old),
            "state" => state,
            "entry" => 7,
            "blocked_reason" => nil,
            "status" => if(state == "proposed", do: "active", else: "completed"),
            "pending" => %{"version" => 1, "writes" => []},
            "last_input" =>
              if(import?, do: %{"version" => 1, "import" => true}, else: %{"version" => 1})
          })

        # No input subsystem existed in slice 1.
        run =
          if import? or state == "proposed",
            do: run,
            else: put_in(run, ["last_input"], %{"version" => 1, "branch" => state})

        # The first upgrade has already encountered and blocked this old run.
        run = if key == "D-active", do: Run.block_definition(run, flow), else: run

        FakeFacts.put("flow_run", %{"key" => run["key"], "values" => Store.encode(config, run)})
        {key, run}
      end

    for key <- ~w(D-0073 D-0074),
        do: FakeFacts.put("decision", %{"key" => key, "values" => %{"status" => "proposed"}})

    opts = [clock: {ManualClock, clock}, model: Runs, environment: :test]
    # Stop after the new entry commits and its first write loses its answer.
    FakeFacts.lose_ack("decision")
    engine = start_supervised!({Engine, opts})
    assert match?({:pending, _}, :sys.get_state(engine).refusal)

    {:ok, interrupted} =
      Store.decode(config, FakeFacts.get("flow_run", originals["D-active"]["key"]))

    assert interrupted["state"] == "deciding" and interrupted["entry"] == 8
    assert interrupted["pending"]["writes"] != []
    assert length(interrupted["pending"]["migrations"]) == 1
    assert GenServer.call(MigrationGate, :calls) == []
    stop_supervised!(Engine)
    engine = start_supervised!({Engine, opts})
    Engine.round(engine)
    assert :sys.get_state(engine).refusal == nil

    read = fn key ->
      {:ok, run} =
        Store.decode(config, FakeFacts.get("flow_run", Run.key("decide", "decision", key, 1)))

      run
    end

    active = read.("D-active")
    assert active["state"] == "for_person" and active["entry"] == 9, inspect(active)
    assert [audit] = active["pending"]["migrations"]
    assert audit["from"] == @old and audit["to"] == flow.digest()
    assert audit["entry"] == 7 and audit["state"] == "proposed"
    assert audit["reason"] =~ "Slice 1 to slice 3"
    assert active["definition_sha256"] == flow.digest()

    for key <- ~w(D-final-a D-final-r) do
      final = read.(key)

      assert Map.drop(final, ["definition_sha256", "pending"]) ==
               Map.drop(originals[key], ["definition_sha256", "pending"])

      assert final["pending"]["writes"] == []
    end

    assert read.("D-history") == originals["D-history"]
    blocked = read.("D-unknown")
    assert blocked["status"] == "blocked" and blocked["blocked_reason"] =~ "definition_changed"
    for key <- ~w(D-0073 D-0074), do: assert(read.(key)["state"] == "for_person")
    calls = GenServer.call(MigrationGate, :calls)
    assert Enum.count(calls, &(&1 == {"decide", "D-active", 8})) == 1
    before = FakeFacts.sent()
    stop_supervised!(Engine)
    restarted = start_supervised!({Engine, opts})
    Engine.round(restarted)
    assert :sys.get_state(restarted).refusal == nil
    assert read.("D-active") == active
    assert read.("D-unknown") == blocked
    assert FakeFacts.sent() == before
    assert GenServer.call(MigrationGate, :calls) == calls

    IO.puts(
      "flow migration boot proof: old store, gate once, finals, blocked isolation, restart ok"
    )
  end

  test "live person waits from the deployed definitions keep state, entry and deadline across restart" do
    for env <- ["test", "prod"] do
      Application.put_env(
        :atlas_bus,
        :store,
        "answers-#{env}-#{System.unique_integer([:positive])}"
      )

      config = AtlasFlow.Model.load(Runs, String.to_atom(env)).config
      start_supervised!({FakeFacts, description: %{"entities" => %{}}})
      start_supervised!(MigrationGate)
      clock = start_supervised!({ManualClock, @now})
      flow = decide(String.to_atom(env))
      old = @answerless[env]
      assert flow.digest() != old

      timers = fn entry ->
        [
          %{
            "name" => "no_answer",
            "entry" => entry,
            "to" => "deciding",
            "due" => "2026-11-14T00:00:00Z"
          }
        ]
      end

      originals =
        for {key, state, entry, due} <- [
              {"D-person", "for_person", 4, timers.(4)},
              {"D-always", "for_person_always", 2, []}
            ],
            into: %{} do
          subject = %{"key" => key, "values" => %{"status" => "proposed"}}
          FakeFacts.put("decision", subject)

          run =
            Run.new("decide", flow, subject, config["selection"]["decide"]["imports"], @now)
            |> Map.merge(%{
              "definition_sha256" => old,
              "state" => state,
              "entry" => entry,
              "status" => "active",
              "blocked_reason" => nil,
              "pending" => %{"version" => 1, "writes" => []},
              "deadlines" => %{"version" => 1, "timers" => due},
              "last_input" => %{"version" => 1}
            })

          FakeFacts.put("flow_run", %{"key" => run["key"], "values" => Store.encode(config, run)})
          {key, run}
        end

      opts = [clock: {ManualClock, clock}, model: Runs, environment: String.to_atom(env)]

      read = fn key ->
        {:ok, run} =
          Store.decode(config, FakeFacts.get("flow_run", Run.key("decide", "decision", key, 1)))

        run
      end

      engine = start_supervised!({Engine, opts})
      Engine.round(engine)
      assert :sys.get_state(engine).refusal == nil

      migrated =
        for {key, old_run} <- originals, into: %{} do
          run = read.(key)
          assert run["definition_sha256"] == flow.digest(), "#{env} #{key}"

          assert Map.take(run, ~w(state entry entered_at status deadlines last_input)) ==
                   Map.take(old_run, ~w(state entry entered_at status deadlines last_input))

          assert [%{"from" => ^old, "state" => state}] = run["pending"]["migrations"]
          assert state == old_run["state"]
          {key, run}
        end

      # No gate is asked again: the wait goes on where it was.
      assert GenServer.call(MigrationGate, :calls) == []
      before = FakeFacts.sent()
      stop_supervised!(Engine)
      restarted = start_supervised!({Engine, opts})
      Engine.round(restarted)
      for {key, run} <- migrated, do: assert(read.(key) == run)
      assert FakeFacts.sent() == before
      stop_supervised!(Engine)
      stop_supervised!(MigrationGate)
      stop_supervised!(ManualClock)
      stop_supervised!(FakeFacts)
    end

    IO.puts(
      "flow migration answers proof: test and prod person waits kept their entry and deadline"
    )
  end
end
