# Private neutral contract over the real Bus: Flow's run store and effect adapter, a
# durable private receiver (journal on disk), fake Facts and a manual clock.
# From beam/: MIX_ENV=test mix run integration/flow_effect.exs
#
# This proves Flow's side of the effect contract and recovery, not any real service.
# The receiver is a test stub: it does not show that Code (or any remote host) returns
# the original result for a repeated id, rejects a changed payload or recovers a lost
# answer. Code update support is an external prerequisite, so Code migration stays
# blocked: no real receiver is listed in :effect_receivers, and every generated effect
# definition is refused before any write.
ExUnit.start()

defmodule FlowEffectProof do
  use ExUnit.Case, async: false
  alias AtlasBus.Digest
  alias AtlasFlow.Activities.Effect
  alias AtlasFlow.{EffectReceiver, EffectReceiverContract, FakeFacts, ManualClock}
  alias AtlasFlow.Runs.{Run, Store}
  @now ~U[2026-11-12 00:00:00Z]
  @address "ledger/effects"
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    d = FakeFacts.run_description()
    c = put_in(d["flow_runtime"], ["selection", "sort", "imports"], [])
    start_supervised!({FakeFacts, description: Map.put(d, "flow_runtime", c)})
    clock = start_supervised!({ManualClock, @now})
    :ok = AtlasBus.attach("flow")
    FakeFacts.put("box", %{"key" => "B-1", "values" => %{"phase" => "first", "title" => "a"}})
    %{c: c, clock: clock, dir: dir, journal: Path.join(dir, "receiver")}
  end

  defp spec do
    %{
      "contract" => 1,
      "name" => "publish",
      "service" => "ledger",
      "operation" => "create",
      "field" => "effect_result",
      "fingerprint" => %{"fields" => ["title"], "relations" => []},
      "payload" => ["title"],
      "outputs" => %{"reference" => "artifact"},
      "records" => %{
        "kind" => "crate",
        "relation" => "in_box",
        "outputs" => %{"label" => "reference"}
      }
    }
  end

  defp flow do
    base = %{"set" => [], "creates" => [], "branches" => [], "timers" => [], "final" => false}

    %{
      "subject" => "box",
      "owner" => %{"default" => %{"kind" => "clerk", "key" => "ada"}},
      "initial" => "publishing",
      "per_subject" => "one",
      "start" => [%{"on" => "create"}],
      "states" => %{
        "done" => Map.put(base, "final", true),
        "stuck" => base,
        "publishing" =>
          Map.merge(base, %{
            "kind" => "effect",
            "set" => [%{"field" => "effect_result", "value" => "none"}],
            "branches" => [
              %{"when" => "entity.effect_result == 'done'", "roles" => [], "to" => "done"},
              %{"when" => "entity.effect_result == 'refused'", "roles" => [], "to" => "stuck"}
            ],
            "spec" => spec()
          })
      }
    }
  end

  defp receiver(c), do: start_supervised!({EffectReceiver, dir: c.journal, address: @address})
  defp reconcile(c), do: Store.reconcile(c.c, %{"sort" => flow()}, ManualClock.now(c.clock))

  # Acknowledgement barrier, no timer wait: every delivered request and answer was handled.
  defp drain(receiver) do
    :sys.get_state(receiver)
    :sys.get_state(Effect.Inbox)
  end

  defp restart_flow do
    :ok = Application.stop(:atlas_flow)
    {:ok, _} = Application.ensure_all_started(:atlas_flow)
  end

  test "the private receiver passes the contract before it is enabled", c do
    refute Run.validate(flow()) == :ok
    pid = receiver(c)

    {:ok, i} =
      Effect.freeze(%{"key" => "probe", "entry" => 1}, spec(), FakeFacts.get("box", "B-1"), %{
        "ledger" => %{"contract" => 1, "address" => @address, "operations" => ["create"]}
      })

    assert :ok = EffectReceiverContract.check!(&EffectReceiver.request(pid, &1), [i["request"]])
  end

  test "a lost response and a Flow restart give one operation with its original result", c do
    Application.put_env(:atlas_flow, :effect_receivers, %{
      "ledger" => %{"contract" => 1, "address" => @address, "operations" => ["create"]}
    })

    on_exit(fn -> Application.delete_env(:atlas_flow, :effect_receivers) end)
    assert :ok = Run.validate(flow())
    pid = receiver(c)

    # The receiver performs the operation and journals it; its answer is lost.
    EffectReceiver.lose(pid)
    {:ok, [sent]} = reconcile(c)
    frozen = sent["pending"]["effect"]
    drain(pid)
    assert [{id, "create", "artifact-1"}] = EffectReceiver.operations(c.journal)
    assert id == frozen["request"]["id"]
    IO.puts("request #{id} stored before sending; remote operation done, answer lost")

    # Restart both sides: Flow keeps nothing in memory; the receiver keeps its journal.
    restart_flow()
    stop_supervised!(EffectReceiver)
    pid = receiver(c)
    {:ok, [restored]} = reconcile(c)
    assert restored["pending"]["effect"] == frozen
    assert restored["status"] == "active"

    # Retry at the manual clock deadline: a lookup of the same id, never a second submit.
    ManualClock.advance(c.clock, 1000)
    {:ok, _} = reconcile(c)
    drain(pid)
    {:ok, [done]} = reconcile(c)
    assert done["status"] == "completed" and done["state"] == "done"
    assert [%{"request" => request, "result" => result}] = done["pending"]["effects"]
    assert request == frozen["request"]
    assert result["reference"] == "artifact-1"
    assert result["digest"] == Digest.of_term(frozen["request"])
    assert [{^id, "create", "artifact-1"}] = EffectReceiver.operations(c.journal)
    assert FakeFacts.get("box", "B-1")["values"]["artifact"] == "artifact-1"
    assert FakeFacts.get("box", "B-1")["values"]["effect_result"] == "done"

    crates =
      for f <- FakeFacts.sent(), f["op"] == "create", FakeFacts.get("crate", f["key"]), do: f

    assert [%{"values" => %{"label" => "artifact-1"}, "links" => %{"in_box" => ["B-1"]}}] = crates

    # Settled: another restart and reconcile change nothing and call nothing.
    restart_flow()
    ManualClock.advance(c.clock, 60_000)
    assert {:ok, [^done]} = reconcile(c)
    drain(pid)
    assert length(EffectReceiver.operations(c.journal)) == 1

    IO.puts(
      "after Flow restart: lookup returned #{result["reference"]}; " <>
        "operations=#{length(EffectReceiver.operations(c.journal))}, records=#{length(crates)}"
    )
  end
end
