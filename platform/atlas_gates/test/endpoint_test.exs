defmodule AtlasGates.EndpointTest do
  use ExUnit.Case, async: false
  alias AtlasGates.{Endpoint, FakeFacts}
  alias AtlasBus.Envelope

  def gate do
    %{
      "version" => 1,
      "purpose" => "decider",
      "flavor" => "rule",
      "fingerprint" => %{"fields" => ["title"], "relations" => []},
      "evidence" => %{"late" => ["flow", "timed_out", %{"default" => false}]},
      "rule" => %{"all" => [["equals", "late", true]]},
      "decide" => %{
        "pass" => "agent_unverified",
        "changes_required" => "clerk",
        "uncertain" => "clerk",
        "error" => "clerk"
      },
      "verdicts" => ["agent_unverified", "clerk"]
    }
  end

  setup do
    {module, pid} = facts = FakeFacts.start()
    {:ok, subject} = module.create(pid, "box", "fixture", %{"title" => "Box"}, %{})
    opts = [gates: %{"allocate" => gate()}, kind: "ruling", now: ~U[2026-11-12 00:05:00Z]]

    body = %{
      "version" => 1,
      "id" => "activity-1",
      "run" => "r",
      "entry" => 2,
      "gate" => "allocate",
      "gate_version" => 1,
      "subject" => subject,
      "flow" => %{"timed_out" => true}
    }

    on_exit(fn -> if Process.alive?(pid), do: Agent.stop(pid) end)
    %{facts: facts, opts: opts, body: body}
  end

  test "record survives endpoint restart and a lost reply", %{
    facts: facts,
    opts: opts,
    body: body
  } do
    :ok = AtlasBus.attach("flow")
    endpoint = start_supervised!({Endpoint, opts ++ [facts: facts]})

    send_request = fn payload ->
      e = %{Envelope.new("request", "gate_activity") | address: "gates"}
      :ok = AtlasBus.send(e, payload)

      receive do
        {:atlas_bus, %Envelope{id: id, sender: "gates", class: "answer"}, answer}
        when id == e.id ->
          answer
      after
        1000 -> flunk("endpoint did not answer")
      end
    end

    prepared = send_request.(Map.put(body, "operation", "prepare"))
    request = Map.merge(body, %{"operation" => "decide", "request" => prepared["request"]})
    lost = send_request.(request)
    assert lost["outcome"] == "agent_unverified"
    # Delivery was lost to the caller; the next process has only the persisted request.
    stop_supervised!(Endpoint)
    refute Process.alive?(endpoint)
    start_supervised!({Endpoint, opts ++ [facts: facts]})
    assert send_request.(request) == lost

    changed =
      Keyword.put(opts, :gates, put_in(opts[:gates], ["allocate", "decide", "pass"], "clerk"))

    assert Endpoint.handle(request, facts, changed) == lost
    assert Enum.count(FakeFacts.facts(facts), &(&1.kind == "ruling")) == 1

    assert send_request.(put_in(request, ["request", "links"], %{"about" => "other"}))["error"] =~
             "activity_conflict"
  end

  test "an empty gate catalogue starts and refuses an absent gate without reading Facts", %{
    body: body
  } do
    start_supervised!({Endpoint, gates: %{}, facts: {__MODULE__, :unused}})
    :ok = AtlasBus.attach("flow")
    envelope = %{Envelope.new("request", "gate_activity") | address: "gates"}
    :ok = AtlasBus.send(envelope, Map.put(body, "operation", "prepare"))
    id = envelope.id
    assert_receive {:atlas_bus, %Envelope{id: ^id, class: "answer"}, answer}
    assert answer["error"]
    refute Map.has_key?(answer, "recorded")
  end

  test "refuses unknown versions, stale fingerprints and changed evidence", %{
    facts: facts,
    opts: opts,
    body: body
  } do
    assert Endpoint.handle("malformed", facts, opts)["error"]
    prepared = Endpoint.handle(Map.put(body, "operation", "prepare"), facts, opts)
    request = Map.merge(body, %{"operation" => "decide", "request" => prepared["request"]})

    for bad <- [
          Map.put(request, "version", 2),
          Map.put(request, "gate_version", 8),
          put_in(request, ["request", "fingerprint"], "old"),
          put_in(request, ["request", "evidence"], %{})
        ] do
      assert Endpoint.handle(bad, facts, opts)["error"]
    end

    refute Enum.any?(FakeFacts.facts(facts), &(&1.kind == "ruling"))
  end
end
