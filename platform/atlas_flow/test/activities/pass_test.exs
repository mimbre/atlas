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
      "fingerprint" => %{
        "fields" => ["revision", "tree", "packet_id", "packet_fp"],
        "relations" => []
      },
      "packet_from" => %{
        "cwd" => "tree",
        "packet_id" => "packet_id",
        "fingerprint" => "packet_fp",
        "revision" => "revision"
      },
      "request" => %{
        "assignment" => "Inspect the frozen input",
        "mode" => "start",
        "permissions" => "review-packet",
        "packet_contract" => 1,
        "vendors" => ["claude"],
        "backend" => "claude"
      }
    }
  end

  @values %{
    "revision" => "a",
    "tree" => "/private/packet/tree",
    "packet_id" => "packet-1",
    "packet_fp" => "frozen"
  }

  setup do
    :ok = AtlasBus.attach("flow")
    subject = %{"key" => "B-1", "values" => @values}
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
          {"packet", %{"packet_id" => "packet-1", "fingerprint" => "frozen", "revision" => "a"}},
          {"cwd", "/private/work"},
          {"vendors", []},
          {"mode", "continue"}
        ] do
      refute Pass.valid?(put_in(spec(), ["request", field], value))
    end

    # The packet is the subject's: its folder, identity and the revision it must be of, as
    # the subject names them, each a field of the fingerprint; a subject naming none yet
    # freezes nothing.
    assert i["request"]["request"]["cwd"] == "/private/packet/tree"

    assert i["request"]["request"]["packet"] == %{
             "packet_id" => "packet-1",
             "fingerprint" => "frozen",
             "revision" => "a"
           }

    refute Pass.valid?(Map.delete(spec(), "packet_from"))
    refute Pass.valid?(update_in(spec(), ["packet_from"], &Map.delete(&1, "revision")))
    refute Pass.valid?(put_in(spec(), ["fingerprint", "fields"], ["revision"]))

    for field <- ~w(tree packet_id packet_fp revision) do
      bare = put_in(c.subject, ["values", field], nil)

      assert {:error, :invalid_pass_binding} =
               Pass.freeze(%{"key" => "r", "entry" => 1}, spec(), bare, c.assignment, c.owner)
    end

    refute Pass.current?(
             i,
             put_in(c.subject, ["values", "packet_fp"], "refrozen"),
             c.assignment,
             c.owner
           )
  end

  test "a shared pass answers for its owner only by the outcomes it maps", c do
    shared =
      Map.merge(spec(), %{
        "with_person" => true,
        "writes" => "none",
        "answer" => %{
          "field" => "choice",
          "by" => "signed_by",
          "role" => "clerk",
          "outcomes" => %{"pass" => "yes", "changes_required" => "no"}
        }
      })

    assert Pass.valid?(shared) and Pass.with_person?(shared)
    refute Pass.with_person?(spec())
    # Only a pass that writes no result of its own answers, and only a shared one.
    refute Pass.valid?(Map.delete(shared, "writes"))
    refute Pass.valid?(Map.delete(shared, "with_person"))
    refute Pass.valid?(put_in(shared, ["answer", "outcomes"], %{}))
    refute Pass.valid?(put_in(shared, ["answer", "extra"], "x"))
    assert Pass.valid?(Map.delete(shared, "answer"))

    assert Pass.answer(shared, c.intent, %{"outcome" => "pass"}) ==
             {:answer, "choice", "yes", "signed_by", "clerk", "clerk"}

    assert Pass.answer(shared, c.intent, %{"outcome" => "uncertain"}) == :none
    assert Pass.answer(Map.delete(shared, "answer"), c.intent, %{"outcome" => "pass"}) == :none

    # Another owner, machine or subject is another request; the same binding the same one.
    {:ok, again} =
      Pass.freeze(%{"key" => "r", "entry" => 1}, shared, c.subject, c.assignment, c.owner)

    {:ok, same} =
      Pass.freeze(%{"key" => "r", "entry" => 1}, shared, c.subject, c.assignment, c.owner)

    assert again["request"]["id"] == same["request"]["id"]
    other = %{"key" => "bob", "values" => %{"node" => "desk"}}

    {:ok, moved} =
      Pass.freeze(%{"key" => "r", "entry" => 1}, shared, c.subject, c.assignment, other)

    refute moved["request"]["id"] == again["request"]["id"]
  end

  test "freezes the specified backend for either vendor and refuses a missing selection", c do
    for backend <- ~w(claude codex) do
      spec = put_in(spec(), ["request", "backend"], backend)
      spec = put_in(spec, ["request", "vendors"], ~w(claude codex))

      assert {:ok, intent} =
               Pass.freeze(%{"key" => "r", "entry" => 1}, spec, c.subject, c.assignment, c.owner)

      assert intent["request"]["request"]["backend"] == backend
      assert intent["request"]["request"]["vendors"] == ~w(claude codex)
    end

    assert {:error, :invalid_pass_binding} =
             Pass.freeze(
               %{"key" => "r", "entry" => 1},
               update_in(spec(), ["request"], &Map.delete(&1, "backend")),
               c.subject,
               c.assignment,
               c.owner
             )
  end

  test "every changed current binding has a distinct request; stored ids stay current", c do
    run = %{"key" => "r", "entry" => 1}
    stored = put_in(c.intent, ["request", "id"], String.duplicate("f", 64))
    assert Pass.current?(stored, c.subject, c.assignment, c.owner)

    for {subject, assignment, owner} <- [
          {c.subject, put_in(c.assignment, ["values", "title"], "new"), c.owner},
          {c.subject, put_in(c.assignment, ["links", "extra"], ["other"]), c.owner},
          {c.subject, Map.put(c.assignment, "key", "other"), c.owner},
          {put_in(c.subject, ["values", "revision"], "b"), c.assignment, c.owner},
          {c.subject, c.assignment, Map.put(c.owner, "key", "other")},
          {c.subject, c.assignment, put_in(c.owner, ["values", "node"], "other")}
        ] do
      refute Pass.current?(c.intent, subject, assignment, owner)
      assert {:ok, changed} = Pass.freeze(run, spec(), subject, assignment, owner)
      refute changed["request"]["id"] == c.intent["request"]["id"]
      assert Pass.current?(changed, subject, assignment, owner)
      assert {:ok, ^changed} = Pass.freeze(run, spec(), subject, assignment, owner)
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

    assert {:error, {:pass_requires_reconciliation, _}} = Pass.validate_reply(i, refusal)

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
