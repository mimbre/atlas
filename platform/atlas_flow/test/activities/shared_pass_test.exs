defmodule AtlasFlow.Activities.SharedPassTest do
  @moduledoc """
  A shared pass, on Flow's durable runs (`AtlasFlow.Sorts.Answered`): a clerk
  whose node has a Runtime is inspected once there, on the packet the box names, and the
  pass's answer is the clerk's choice; a clerk with no node chooses by hand; an offline
  node leaves the pass waiting while the state's timer runs; a late answer of a pass the
  state moved on from, or of another packet, is not taken. Facts and the node's Runtime
  are stand-ins; the clock is manual.
  """
  use ExUnit.Case, async: false
  alias AtlasBus.Envelope
  alias AtlasFlow.{FakeFacts, ManualClock, Talk}
  alias AtlasFlow.Runs.Store
  @now ~U[2026-11-12 00:00:00Z]

  defmodule Node do
    @moduledoc "A node's pass receiver: one execution per request id, ended on request."
    use GenServer
    def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
    def finish(outcome), do: GenServer.call(__MODULE__, {:finish, outcome})
    def refuse, do: GenServer.call(__MODULE__, :refuse)
    def started, do: GenServer.call(__MODULE__, :started)

    @impl true
    def init(_) do
      :ok = AtlasBus.attach("runtime@desk/passes")
      {:ok, %{started: [], outcome: nil, refused: false}}
    end

    @impl true
    def handle_call({:finish, outcome}, _, s), do: {:reply, :ok, %{s | outcome: outcome}}
    def handle_call(:refuse, _, s), do: {:reply, :ok, %{s | refused: true}}
    def handle_call(:started, _, s), do: {:reply, s.started, s}

    @impl true
    def handle_info({:atlas_bus, %Envelope{class: "request"} = e, body}, s) do
      r = body["request"]
      s = if r["id"] in s.started, do: s, else: %{s | started: s.started ++ [r["id"]]}

      reply =
        %{
          "version" => 1,
          "id" => r["id"],
          "digest" => body["digest"],
          "fingerprint" => r["fingerprint"],
          "packet" => r["request"]["packet"],
          "execution" => "execution-" <> String.slice(r["id"], 0, 8),
          "status" => if(s.outcome, do: "completed", else: "running")
        }
        |> then(&if(s.outcome, do: Map.put(&1, "outcome", s.outcome), else: &1))
        |> then(
          &if(s.refused,
            do:
              Map.merge(Map.drop(&1, ~w(execution status outcome)), %{
                "error" => "the packet is not the one named",
                "requires_reconciliation" => true
              }),
            else: &1
          )
        )

      :ok = AtlasBus.send(Envelope.reply(e, "answer"), reply)
      {:noreply, s}
    end

    def handle_info(_, s), do: {:noreply, s}
  end

  setup do
    c = put_in(AtlasFlow.TestModel.config(), ["selection", "sort", "imports"], [])
    start_supervised!({FakeFacts, description: FakeFacts.description()})
    clock = start_supervised!({ManualClock, @now})
    :ok = AtlasBus.attach("flow")

    FakeFacts.put("box", %{
      "key" => "B-1",
      "values" => %{
        "phase" => "first",
        "revision" => "a",
        "tree" => "/private/packet/tree",
        "packet_id" => "packet-1",
        "packet_fp" => "frozen"
      },
      "links" => %{"owned_by" => ["ada"]}
    })

    FakeFacts.put("clerk", %{"key" => "ada", "values" => %{"node" => "desk"}})
    flows = %{"sort" => AtlasFlow.Sorts.Answered}
    assert :ok = AtlasFlow.Runs.Run.validate(flows["sort"])
    %{c: c, flows: flows, clock: clock}
  end

  defp reconcile(c) do
    {:ok, [run]} = Store.reconcile(c.c, c.flows, ManualClock.now(c.clock))
    run
  end

  # Acknowledgement barrier, no timer wait: every delivered request and answer was handled.
  defp drain do
    if Process.whereis(Node), do: :sys.get_state(Node)
    :sys.get_state(AtlasFlow.Activities.Pass.Inbox)
  end

  defp tick(c), do: ManualClock.advance(c.clock, 1000)

  defp box, do: FakeFacts.get("box", "B-1")

  test "a clerk with a node is inspected once there; its answer is the clerk's, across restarts",
       c do
    frozen = reconcile(c)
    assert {frozen["state"], frozen["entry"]} == {"working", 1}
    request = frozen["pending"]["pass"]["request"]
    assert {request["owner"], request["machine"]} == {"ada", "desk"}
    assert request["request"]["cwd"] == "/private/packet/tree"

    # Offline: it waits, retried at the clock's deadline; then the node comes up.
    tick(c)
    assert reconcile(c)["pending"]["pass"]["request"] == request
    start_supervised!(Node)
    tick(c)
    reconcile(c)
    drain()
    assert reconcile(c)["pending"]["pass"]["execution"]

    # Flow restarts: the request is the one Facts kept; the node runs nothing again.
    Supervisor.terminate_child(AtlasFlow.Root, AtlasFlow.Activities.Pass.Inbox)
    Supervisor.restart_child(AtlasFlow.Root, AtlasFlow.Activities.Pass.Inbox)
    Node.finish("pass")
    tick(c)
    reconcile(c)
    drain()
    done = reconcile(c)

    assert {done["state"], done["status"], done["entry"]} == {"done", "completed", 2}
    assert done["last_input"]["pass"] == request["id"]

    assert [%{"request" => ^request, "result" => %{"outcome" => "pass"}}] =
             done["pending"]["passes"]

    assert box()["values"]["choice"] == "yes"
    assert box()["links"]["signed_by"] == ["ada"]
    assert Node.started() == [request["id"]]
    assert reconcile(c) == done
    assert Node.started() == [request["id"]]
  end

  test "a clerk with no node chooses by hand; nothing is frozen or sent", c do
    FakeFacts.put("clerk", %{"key" => "ada", "values" => %{}})
    start_supervised!(Node)
    waiting = reconcile(c)
    assert {waiting["state"], waiting["pending"]["pass"]} == {"working", nil}

    {:stored, _} =
      Talk.put("choice", %{
        "op" => "submit",
        "key" => "I-1",
        "values" => %{
          "run" => waiting["key"],
          "entry" => waiting["entry"],
          "roles" => ["clerk"],
          "changed_fields" => %{"choice" => "no"}
        }
      })

    assert {"discarded", "completed"} == {reconcile(c)["state"], reconcile(c)["status"]}
    drain()
    assert Node.started() == []
  end

  test "an offline node leaves the pass waiting; the day still counts, a late answer is not taken",
       c do
    frozen = reconcile(c)
    id = frozen["pending"]["pass"]["request"]["id"]
    ManualClock.advance(c.clock, 86_400_000)
    stuck = reconcile(c)
    assert {stuck["state"], stuck["entry"], stuck["pending"]["pass"]} == {"stuck", 2, nil}
    assert [%{"left" => true, "request" => %{"id" => ^id}}] = stuck["pending"]["passes"]

    start_supervised!(Node)
    Node.finish("pass")
    tick(c)
    assert reconcile(c) == stuck
    drain()
    assert reconcile(c) == stuck
    assert Node.started() == []
    assert box()["values"]["choice"] == nil
  end

  test "an uncertain answer leaves the choice to the clerk; the pass is not asked again", c do
    start_supervised!(Node)
    Node.finish("uncertain")
    reconcile(c)
    drain()
    waits = reconcile(c)
    assert {waits["state"], waits["entry"]} == {"working", 1}
    assert waits["pending"]["pass"]["result"]["outcome"] == "uncertain"
    tick(c)
    tick(c)
    assert reconcile(c) == waits
    drain()
    assert length(Node.started()) == 1
    assert box()["values"]["choice"] == nil
  end

  test "a box refrozen on another packet is another pass; the first one's answer is not taken",
       c do
    start_supervised!(Node)
    first = reconcile(c)["pending"]["pass"]["request"]["id"]
    drain()
    FakeFacts.put("box", put_in(box(), ["values", "packet_fp"], "refrozen"))
    moved = reconcile(c)
    assert [%{"left" => true, "request" => %{"id" => ^first}}] = moved["pending"]["passes"]
    second = reconcile(c)["pending"]["pass"]["request"]
    refute second["id"] == first
    assert second["request"]["packet"]["fingerprint"] == "refrozen"
    Node.finish("changes_required")
    tick(c)
    reconcile(c)
    drain()
    done = reconcile(c)
    assert {done["state"], done["last_input"]["pass"]} == {"discarded", second["id"]}
    assert box()["values"]["choice"] == "no"
  end

  defp choose(run, choice) do
    {:stored, _} =
      Talk.put("choice", %{
        "op" => "submit",
        "key" => "I-" <> choice,
        "values" => %{
          "run" => run["key"],
          "entry" => run["entry"],
          "roles" => ["clerk"],
          "changed_fields" => %{"choice" => choice}
        }
      })
  end

  # The node refuses the pass for reconciliation: it ends without an answer, and the run
  # stays active, waiting for the clerk by hand and for its timer.
  defp refused(c) do
    start_supervised!(Node)
    Node.refuse()
    reconcile(c)
    drain()
    waits = reconcile(c)
    assert {waits["state"], waits["status"], waits["entry"]} == {"working", "active", 1}

    assert %{"status" => "failed", "requires_reconciliation" => true} =
             waits["pending"]["pass"]["result"]

    tick(c)
    assert reconcile(c) == waits
    drain()
    assert length(Node.started()) == 1
    waits
  end

  test "a pass refused for reconciliation leaves the choice to the clerk", c do
    waits = refused(c)
    choose(waits, "no")
    assert {"discarded", "completed"} == {reconcile(c)["state"], reconcile(c)["status"]}
    assert box()["links"]["signed_by"] == nil
  end

  test "a pass refused for reconciliation keeps the state's timer", c do
    refused(c)
    ManualClock.advance(c.clock, 86_400_000)
    stuck = reconcile(c)
    assert {stuck["state"], stuck["status"], stuck["entry"]} == {"stuck", "active", 2}

    assert [%{"left" => true, "result" => %{"status" => "failed"}}] =
             stuck["pending"]["passes"]
  end

  test "a refused pass is left when the revision changes, with a new pass for that revision", c do
    waits = refused(c)
    first = waits["pending"]["pass"]["request"]["id"]
    FakeFacts.put("box", put_in(box(), ["values", "revision"], "b"))
    moved = reconcile(c)

    assert [%{"left" => true, "result" => %{"status" => "failed"}}] =
             moved["pending"]["passes"]

    request = reconcile(c)["pending"]["pass"]["request"]
    refute request["id"] == first
    assert request["request"]["packet"]["revision"] == "b"
    tick(c)
    reconcile(c)
    drain()
    assert reconcile(c)["status"] == "active"
    assert length(Node.started()) == 2
    assert box()["values"]["choice"] == nil
  end

  test "after an answer of nothing, another clerk or packet is another pass", c do
    FakeFacts.put("clerk", %{"key" => "bob", "values" => %{"node" => "desk"}})
    start_supervised!(Node)
    Node.finish("uncertain")
    first = reconcile(c)["pending"]["pass"]["request"]["id"]
    drain()
    assert reconcile(c)["pending"]["pass"]["result"]["outcome"] == "uncertain"

    # Handed to another clerk: the first pass is left with its result; one for bob starts.
    FakeFacts.put("box", put_in(box(), ["links", "owned_by"], ["bob"]))
    moved = reconcile(c)

    assert [
             %{
               "left" => true,
               "request" => %{"id" => ^first},
               "result" => %{"outcome" => "uncertain"}
             }
           ] = moved["pending"]["passes"]

    second = reconcile(c)["pending"]["pass"]["request"]
    assert {second["owner"], second["id"] == first} == {"bob", false}
    tick(c)
    reconcile(c)
    drain()
    assert reconcile(c)["pending"]["pass"]["result"]["outcome"] == "uncertain"

    # Refrozen on another packet: again another pass, and this one answers.
    Node.finish("pass")
    FakeFacts.put("box", put_in(box(), ["values", "packet_fp"], "refrozen"))
    reconcile(c)
    tick(c)
    reconcile(c)
    drain()
    done = reconcile(c)
    assert done["state"] == "done"

    assert [_ada, %{"left" => true, "result" => %{"outcome" => "uncertain"}}, third] =
             done["pending"]["passes"]

    assert third["request"]["request"]["packet"]["fingerprint"] == "refrozen"
    assert done["last_input"]["pass"] == third["request"]["id"]
    assert box()["values"]["choice"] == "yes"
    assert box()["links"]["signed_by"] == ["bob"]
    assert length(Node.started()) == 3
  end
end
