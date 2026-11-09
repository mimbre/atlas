# Manual clock proof of the Flow/Gates Bus boundary. No OS server or timer sleeps.
# From beam/: MIX_ENV=test mix run integration/flow_gate.exs
ExUnit.start()

defmodule FlowGateFacts do
  alias AtlasFlow.Talk

  def fetch(_, nil, key) do
    %{"description" => d} = Talk.read("_description", %{})

    Enum.reduce_while(d["entities"], {:ok, nil}, fn {kind, _}, acc ->
      case fetch(nil, kind, key) do
        {:ok, nil} -> {:cont, acc}
        other -> {:halt, other}
      end
    end)
  end

  def fetch(_, kind, nil) do
    case Talk.transition_read(kind, %{}) do
      %{"facts" => facts} -> {:ok, facts}
      other -> {:error, inspect(other)}
    end
  end

  def fetch(_, kind, key) do
    case Talk.transition_read(kind, %{"key" => key}) do
      %{"fact" => fact} -> {:ok, fact}
      other -> {:error, inspect(other)}
    end
  end

  def find(_, kind, identity) do
    {:ok, facts} = fetch(nil, kind, nil)
    found = Enum.find(facts, fn f -> Enum.all?(identity, &(&1 in Map.values(f["values"]))) end)
    {:ok, found && found["key"]}
  end

  def create(_, kind, id, values, links) do
    key = "GV-" <> String.replace(id, "GR-", "")
    links = Map.new(links, fn {rel, target} -> {rel, List.wrap(target)} end)

    case Talk.put(
           kind,
           %{"op" => "create", "key" => key, "values" => values, "links" => links},
           id
         ) do
      {:stored, _} -> {:ok, key}
      other -> {:error, inspect(other)}
    end
  end
end

defmodule FlowGateProof do
  use ExUnit.Case, async: false
  alias AtlasFlow.{FakeFacts, ManualClock}
  alias AtlasFlow.Runs.Store
  @now ~U[2026-11-12 00:00:00Z]

  setup do
    # The model Flow and Gates run, compiled for the test environment (its answer limits).
    Application.put_env(:atlas, :model, Model.AtlasEyra)
    # Who decides what a person decides: the environment's settings say (`actors`).
    Application.put_env(:atlas, :actors, %{"decider" => "tester"})
    %{config: c, flows: flows} = AtlasFlow.Model.load(Model.AtlasEyra, :test)
    c = Map.delete(c, "inputs")
    d = %{"entities" => %{"decision" => %{}, "gate_verdict" => %{}}}
    start_supervised!({FakeFacts, description: d})
    clock = start_supervised!({ManualClock, @now})
    start_supervised!({AtlasGates.Endpoint, facts: {FlowGateFacts, nil}, now: @now})
    :ok = AtlasBus.attach("flow")
    %{c: c, flows: flows, clock: clock}
  end

  defp subject(force \\ "direction") do
    %{
      "key" => "D-proof",
      "values" => %{
        "title" => "Private proof",
        "decision" => "Exercise timeout",
        "status" => "proposed",
        "force" => force,
        "category" => "process",
        "scope" => "platform",
        "reversibility" => "two_way"
      }
    }
  end

  defp reconcile(ctx), do: Store.reconcile(ctx.c, ctx.flows, ManualClock.now(ctx.clock))

  test "person, original deadline across restart, timed-out re-ask, follows and review", ctx do
    FakeFacts.put("decision", subject())
    assert {:ok, [first]} = reconcile(ctx)
    assert first["state"] == "for_person"
    [deadline] = first["deadlines"]["timers"]
    assert deadline["due"] == "2026-11-12T00:05:00.000Z"
    ManualClock.advance(ctx.clock, 299_999)
    assert {:ok, [^first]} = reconcile(ctx)
    # Each reconcile restores only Facts' durable cursor; no in-memory activity state survives.
    ManualClock.advance(ctx.clock, 1)
    assert {:ok, [late]} = reconcile(ctx)
    assert late["state"] == "for_agent_unverified"
    assert late["entry"] == 4
    assert late["deadlines"]["timers"] == []
    assert FakeFacts.get("decision", "D-proof")["values"]["unverified"]
    first_verdict = first["pending"]["verdict"]["recorded"]
    late_verdict = late["pending"]["verdict"]["recorded"]
    fact = FakeFacts.get("gate_verdict", late_verdict)
    assert fact["values"]["evidence"] =~ "timed_out: true"
    assert fact["values"]["evidence"] =~ "waited_from: 2026-11-12T00:00:00Z"
    assert fact["links"]["follows"] == [first_verdict]
    ManualClock.advance(ctx.clock, 100_000_000)
    assert {:ok, [^late]} = reconcile(ctx)
    FakeFacts.put("gate_verdict", put_in(fact, ["links", "reviewed_by"], ["reviewer"]))
    assert {:ok, [reviewed]} = reconcile(ctx)
    refute FakeFacts.get("decision", "D-proof")["values"]["unverified"]
    assert reviewed["entry"] == late["entry"]
  end

  test "fixed rules never acquire a timer", ctx do
    FakeFacts.put("decision", subject("principle"))
    assert {:ok, [first]} = reconcile(ctx)
    assert first["state"] == "for_person_always"
    assert first["deadlines"]["timers"] == []
    ManualClock.advance(ctx.clock, 1_000_000_000)
    assert {:ok, [^first]} = reconcile(ctx)
  end

  test "overrule clears the timeout flag and replaced anchors flag their work", ctx do
    FakeFacts.put("decision", subject())
    {:ok, [_]} = reconcile(ctx)
    ManualClock.advance(ctx.clock, 300_000)
    {:ok, [late]} = reconcile(ctx)
    key = late["pending"]["verdict"]["recorded"]
    verdict = FakeFacts.get("gate_verdict", key)
    FakeFacts.put("gate_verdict", put_in(verdict, ["links", "overruled_by"], ["reviewer"]))
    old = FakeFacts.get("decision", "D-proof")
    FakeFacts.put("decision", put_in(old, ["values", "status"], "superseded"))
    {:ok, [_]} = reconcile(ctx)
    refute FakeFacts.get("decision", "D-proof")["values"]["unverified"]

    # The review rules are the model's, compiled with it (relation reviews and the run
    # mapping's): what Facts works out on a read.
    work = %{key: "IS-proof", properties: %{}, links: %{"based_on" => ["D-proof"]}}

    for {status, flag, label} <- [
          {"accepted", true, "Based on unverified decisions"},
          {"accepted", false, nil},
          {"superseded", false, "Review: based on a superseded decision"}
        ] do
      anchor = %{
        key: "D-proof",
        properties: %{"status" => status, "unverified" => flag},
        links: %{}
      }

      list = fn
        "decision" -> {:ok, [anchor]}
        _ -> {:ok, []}
      end

      assert {:ok, [derived]} = Model.AtlasEyra.derived("issue", [work], %{"list" => list})
      assert (derived["review"] || %{})["label"] == label
    end
  end
end
