# Private neutral model (atlas_flow's test depot), real Bus and durable receiver journal,
# fake Facts/native worker.
# From beam/: MIX_ENV=test mix run integration/flow_pass.exs
# This proves protocol recovery, not a provider run or a deployed environment. Runtime's
# native receiver is opt-in via config :atlas_runtime, :flow_passes,
#   machine: MACHINE, dir: SERVICE_HOME
# in the same node as the named native Service. Review input must already be frozen;
# the receiver verifies packet-scope before admission and again before returning evidence.
ExUnit.start()

defmodule FlowPassReceiver do
  def validate(_, _), do: :ok

  def accept(pid, r) do
    Agent.get_and_update(pid, fn s ->
      result = s.requests[r["id"]] || %{"execution" => "execution-1", "status" => "running"}

      next =
        if s.requests[r["id"]],
          do: s,
          else: %{s | starts: s.starts + 1, requests: Map.put(s.requests, r["id"], result)}

      {{:ok, result}, next}
    end)
  end

  def lookup(pid, r, _), do: {:ok, Agent.get(pid, & &1.requests[r["id"]])}
end

defmodule FlowPassProof do
  use ExUnit.Case, async: false
  alias AtlasFlow.{FakeFacts, ManualClock}
  alias AtlasFlow.Runs.Store
  alias AtlasRuntime.FlowPasses
  @now ~U[2026-11-12 00:00:00Z]
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    # The neutral depot's runs, with its sort replaced by an inspection pass (compiled
    # from the Rela DSL, test/support of atlas_flow); no import makes a run final.
    c = put_in(AtlasFlow.TestModel.config(), ["selection", "sort", "imports"], [])
    d = FakeFacts.description()
    start_supervised!({FakeFacts, description: d})
    clock = start_supervised!({ManualClock, @now})
    receiver = start_supervised!({Agent, fn -> %{starts: 0, requests: %{}} end})
    opts = [machine: "desk", dir: dir, backend: {FlowPassReceiver, receiver}]
    :ok = AtlasBus.attach("flow")

    FakeFacts.put("box", %{
      "key" => "B-1",
      "values" => %{"phase" => "first", "revision" => "a"},
      "links" => %{"owned_by" => ["ada"]}
    })

    FakeFacts.put("clerk", %{"key" => "ada", "values" => %{"node" => "desk"}})
    FakeFacts.put("clerk", %{"key" => "bob", "values" => %{"node" => "other-desk"}})
    flow = AtlasFlow.Sorts.Inspect
    assert :ok = AtlasFlow.Runs.Run.validate(flow)

    %{
      c: c,
      description: d,
      flows: %{"sort" => flow},
      clock: clock,
      receiver: receiver,
      opts: opts
    }
  end

  defp reconcile(c), do: Store.reconcile(c.c, c.flows, ManualClock.now(c.clock))
  # Acknowledgement barrier, no timer wait: all previously delivered Bus requests were handled.
  defp drain(endpoint) do
    :sys.get_state(endpoint)
    :sys.get_state(AtlasFlow.Activities.Pass.Inbox)
  end

  test "offline, reconnect, lost answer, caller restart and receiver restart yield one outcome",
       c do
    {:ok, [offline]} = reconcile(c)
    frozen = offline["pending"]["pass"]
    assert frozen["request"]["machine"] == "desk"
    assert Agent.get(c.receiver, & &1.starts) == 0
    endpoint = start_supervised!({FlowPasses, c.opts})
    ManualClock.advance(c.clock, 1000)
    {:ok, [_]} = reconcile(c)
    drain(endpoint)
    # Lose the answer and restart the caller; Facts alone restores the frozen request.
    Supervisor.terminate_child(AtlasFlow.Root, AtlasFlow.Activities.Pass.Inbox)
    Supervisor.restart_child(AtlasFlow.Root, AtlasFlow.Activities.Pass.Inbox)
    stop_supervised!(FlowPasses)
    endpoint = start_supervised!({FlowPasses, c.opts})
    ManualClock.advance(c.clock, 1000)
    {:ok, [_]} = reconcile(c)
    drain(endpoint)
    {:ok, [accepted]} = reconcile(c)
    assert accepted["pending"]["pass"]["execution"] == "execution-1"
    assert accepted["pending"]["pass"]["request"] == frozen["request"]
    id = frozen["request"]["id"]

    Agent.update(c.receiver, fn s ->
      put_in(s.requests[id], %{
        "execution" => "execution-1",
        "status" => "completed",
        "outcome" => "delivered"
      })
    end)

    ManualClock.advance(c.clock, 1000)
    reconcile(c)
    drain(endpoint)
    {:ok, [done]} = reconcile(c)
    assert done["status"] == "completed"
    assert done["last_input"]["execution"] == "execution-1"
    assert done["pending"]["pass_result"]["id"] == id
    assert [%{"request" => request, "result" => result}] = done["pending"]["passes"]
    assert request == frozen["request"]
    assert result["execution"] == "execution-1"
    assert {:ok, [^done]} = reconcile(c)
    assert Agent.get(c.receiver, & &1.starts) == 1
  end

  test "owner changes block a frozen offline pass without routing to the replacement", c do
    {:ok, [_]} = reconcile(c)
    endpoint = start_supervised!({FlowPasses, Keyword.put(c.opts, :machine, "other-desk")})
    fact = FakeFacts.get("box", "B-1")
    FakeFacts.put("box", put_in(fact, ["links", "owned_by"], ["bob"]))
    ManualClock.advance(c.clock, 1000)
    {:ok, [blocked]} = reconcile(c)
    drain(endpoint)
    assert blocked["status"] == "blocked"
    assert blocked["pending"]["pass"]["request"]["owner"] == "ada"
    assert Agent.get(c.receiver, & &1.starts) == 0
  end

  test "late completion after a subject fingerprint change cannot advance the entry", c do
    endpoint = start_supervised!({FlowPasses, c.opts})
    {:ok, [_]} = reconcile(c)
    drain(endpoint)
    {:ok, [_]} = reconcile(c)
    fact = FakeFacts.get("box", "B-1")
    FakeFacts.put("box", put_in(fact, ["values", "revision"], "b"))
    {:ok, [blocked]} = reconcile(c)
    assert blocked["status"] == "blocked"
    assert blocked["entry"] == 1
    assert Agent.get(c.receiver, & &1.starts) == 1
  end

  test "ownership through a related assignment routes to that assignment's current owner", c do
    d = put_in(c.description, ["relations", "holder"], %{"from" => ["box"], "to" => ["job"]})
    FakeFacts.set_description(d)

    FakeFacts.put("job", %{
      "key" => "J-1",
      "values" => %{"instructions" => "Inspect"},
      "links" => %{"owned_by" => ["ada"]}
    })

    fact = FakeFacts.get("box", "B-1")
    fact = put_in(fact, ["links", "holder"], ["J-1"])
    FakeFacts.put("box", put_in(fact, ["links", "owned_by"], ["bob"]))
    # The same pass, owned through the box's holder.
    c = %{c | flows: %{"sort" => AtlasFlow.Sorts.InspectHeld}}
    {:ok, [run]} = reconcile(c)
    r = run["pending"]["pass"]["request"]
    assert r["owner"] == "ada" and r["machine"] == "desk"
    assert r["assignment"]["key"] == "J-1"
    assignment = FakeFacts.get("job", "J-1")
    FakeFacts.put("job", put_in(assignment, ["links", "owned_by"], ["bob"]))
    {:ok, [blocked]} = reconcile(c)
    assert blocked["status"] == "blocked"
    assert Agent.get(c.receiver, & &1.starts) == 0
  end

  test "an owner without a registered machine waits without dispatch or changing the owner", c do
    FakeFacts.put("clerk", %{"key" => "ada", "values" => %{}})
    {:ok, [waiting]} = reconcile(c)
    assert waiting["status"] == "active"
    assert waiting["pending"]["pass"] == nil
    assert Agent.get(c.receiver, & &1.starts) == 0
    FakeFacts.put("clerk", %{"key" => "ada", "values" => %{"node" => "desk"}})
    {:ok, [frozen]} = reconcile(c)
    assert frozen["pending"]["pass"]["request"]["owner"] == "ada"
  end
end
