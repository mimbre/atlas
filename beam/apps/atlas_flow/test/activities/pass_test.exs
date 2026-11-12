defmodule AtlasFlow.Activities.PassTest do
  use ExUnit.Case, async: false
  alias AtlasBus.{Digest, Envelope}
  alias AtlasFlow.Activities.Pass
  alias AtlasFlow.ManualClock
  @now ~U[2026-11-12 00:00:00Z]

  defp spec do
    %{
      "contract" => 1,
      "name" => "inspect",
      "routing" => %{"machine_field" => "node"},
      "fingerprint" => %{"fields" => ["revision"], "relations" => []},
      "request" => %{
        "assignment" => "Inspect the frozen input",
        "cwd" => "/private/work",
        "mode" => "start",
        "permissions" => "review-packet",
        "packet_contract" => 1,
        "packet" => %{"packet_id" => "packet-1", "fingerprint" => "frozen"},
        "vendors" => ["codex"],
        "backend" => "codex"
      }
    }
  end

  setup do
    :ok = AtlasBus.attach("flow")
    subject = %{"key" => "B-1", "values" => %{"revision" => "a"}}
    assignment = %{"key" => "A-1", "values" => %{}, "links" => %{"owned_by" => ["clerk"]}}
    owner = %{"key" => "clerk", "values" => %{"node" => "desk"}}
    run = %{"key" => "r", "entry" => 1}
    {:ok, intent} = Pass.freeze(run, spec(), subject, assignment, owner)
    clock = start_supervised!({ManualClock, @now})
    %{intent: intent, subject: subject, assignment: assignment, owner: owner, clock: clock}
  end

  defp reply(i),
    do: %{
      "version" => 1,
      "id" => i["request"]["id"],
      "digest" => i["digest"],
      "fingerprint" => i["request"]["fingerprint"],
      "packet" => i["request"]["request"]["packet"],
      "execution" => "turn-1",
      "status" => "completed",
      "outcome" => "finished"
    }

  test "freezes routing, assignment, permissions, vendors and packet before dispatch", c do
    i = c.intent
    assert Pass.endpoint(i) == "runtime@desk/passes"
    assert i["request"]["assignment"] == c.assignment
    assert i["digest"] == Digest.of_term(i["request"])
    assert Pass.current?(i, c.subject, c.assignment, c.owner)
    refute Pass.current?(i, c.subject, c.assignment, Map.put(c.owner, "key", "other"))

    refute Pass.current?(
             i,
             c.subject,
             c.assignment,
             put_in(c.owner, ["values", "node"], "other-desk")
           )

    refute Pass.current?(i, put_in(c.subject, ["values", "revision"], "b"), c.assignment, c.owner)
    refute Pass.current?(i, c.subject, put_in(c.assignment, ["values", "changed"], true), c.owner)

    for {field, value} <- [
          {"packet_contract", nil},
          {"packet", nil},
          {"vendors", []},
          {"mode", "continue"}
        ] do
      refute Pass.valid?(put_in(spec(), ["request", field], value))
    end
  end

  test "offline waits and retries the same request only at the manual clock deadline", c do
    i = c.intent
    assert {:waiting, waiting} = Pass.poll(i, @now)
    assert {:waiting, ^waiting} = Pass.poll(waiting, @now)
    ManualClock.advance(c.clock, 999)
    assert {:waiting, ^waiting} = Pass.poll(waiting, ManualClock.now(c.clock))
    ManualClock.advance(c.clock, 1)
    assert {:waiting, retried} = Pass.poll(waiting, ManualClock.now(c.clock))
    assert retried["request"] == i["request"]
    assert retried["digest"] == i["digest"]
    # A serialized/restarted caller preserves the exact binding and identity.
    assert JSON.decode!(JSON.encode!(retried)) == retried
    assert Pass.endpoint(retried) == "runtime@desk/passes"
  end

  test "duplicates, stale entries, execution replacement and packet mismatch are fenced", c do
    i = c.intent
    r = reply(i)
    assert {:ok, ^r} = Pass.validate_reply(i, r)
    assert {:ok, ^r} = Pass.validate_reply(i, r)

    refusal =
      Map.merge(r, %{"error" => "indeterminate execution", "requires_reconciliation" => true})

    assert {:error, :pass_requires_reconciliation} = Pass.validate_reply(i, refusal)

    assert {:error, :invalid_pass_evidence} =
             Pass.validate_reply(i, Map.put(refusal, "digest", "old"))

    for field <- ~w(version id digest fingerprint packet status) do
      assert {:error, _} = Pass.validate_reply(i, Map.put(r, field, "foreign")), field
    end

    for field <- ~w(execution outcome),
        do: assert({:error, _} = Pass.validate_reply(i, Map.put(r, field, "")))

    assert {:error, _} = Pass.validate_reply(Map.put(i, "execution", "another"), r)
    newer = put_in(i, ["request", "entry"], 2)
    newer = Map.put(newer, "digest", Digest.of_term(newer["request"]))
    assert {:error, _} = Pass.validate_reply(newer, r)

    send(
      Pass.Inbox,
      {:atlas_bus,
       %{Envelope.new("answer", "flow_pass", id: r["id"]) | sender: "runtime@foreign/passes"}, r}
    )

    assert {:waiting, _} = Pass.poll(i, @now)

    send(
      Pass.Inbox,
      {:atlas_bus, %{Envelope.new("answer", "flow_pass", id: r["id"]) | sender: Pass.endpoint(i)},
       r}
    )

    assert {:ok, ^r} = Pass.poll(i, @now)
  end
end
