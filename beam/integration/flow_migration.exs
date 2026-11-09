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
  @root Path.expand("../..", __DIR__)
  @now ~U[2026-11-12 00:00:00Z]
  # Slice 1's deployed definition digest, retained in the sidecar migration table.
  @old "8ca16b332a083209e6e44ffc3feeca0f152c632caa4d5206ab24fe540ab3770c"

  defmodule Target do
    use AtlasFlowGenerator.Runtime, target: "../../flow/targets/test/atlas/flows.json"
  end

  test "deploy boot migrates old cursors, preserves finals, and admits missed starts" do
    dir = Path.join(System.tmp_dir!(), "flow-migration-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    Application.put_env(:atlas_bus, :store, "migration-boot")
    config = JSON.decode!(File.read!(Path.join(@root, "rela/flow-runtime.json")))["flow_runtime"]
    description = %{"entities" => %{}, "flows" => %{}, "flow_runtime" => config}
    start_supervised!({FakeFacts, description: description})
    start_supervised!(MigrationGate)
    clock = start_supervised!({ManualClock, @now})
    flow = Target.flows()["decide"]

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

    yaml = Path.join(dir, "flows.yaml")
    File.write!(yaml, File.read!(Path.join(@root, "flow/targets/test/rela/flows.yaml")))
    opts = [clock: {ManualClock, clock}, target: Target, deployed_yaml: yaml]
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
    assert audit["from"] == @old and audit["to"] == Run.digest(flow)
    assert audit["entry"] == 7 and audit["state"] == "proposed"
    assert audit["reason"] =~ "Slice 1 to slice 3"
    assert active["definition_sha256"] == Run.digest(flow)

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
end
