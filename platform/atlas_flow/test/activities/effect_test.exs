defmodule AtlasFlow.Activities.EffectTest do
  use ExUnit.Case, async: false
  alias AtlasBus.Digest
  alias AtlasFlow.Activities.Effect
  alias AtlasFlow.{EffectReceiver, EffectReceiverContract, FakeFacts, ManualClock, Sorts}
  alias AtlasFlow.Runs.{Run, Store}
  @now ~U[2026-11-12 00:00:00Z]
  @moduletag :tmp_dir
  @address "ledger/effects"
  @receivers %{
    "ledger" => %{
      "contract" => 1,
      "address" => @address,
      "operations" => ["create", "update", "integrate"]
    }
  }

  defp spec(operation \\ "create") do
    %{
      "contract" => 1,
      "name" => "publish",
      "service" => "ledger",
      "operation" => operation,
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
    |> then(&if(operation != "create", do: Map.put(&1, "target", "artifact"), else: &1))
    |> then(
      &if(operation == "integrate",
        do: Map.merge(&1, %{"approved" => "title", "approving" => %{"verdict" => ["yes"]}}),
        else: &1
      )
    )
  end

  # The composition's links of a box: a check writes `verdict` (`yes` when it accepted,
  # `no` when it rejected), a count `tally`.
  @links [
    %{
      "child" => "check",
      "child_subject" => "check",
      "parent_subject" => "box",
      "relation" => "check_of",
      "field" => "verdict",
      "current" => %{"child" => "title", "parent" => "title"},
      "states" => %{"accepted" => "yes", "rejected" => "no"}
    },
    %{
      "child" => "tally",
      "child_subject" => "tally",
      "parent_subject" => "box",
      "relation" => "tally_of",
      "field" => "tally",
      "states" => %{"counted" => "counted"}
    }
  ]

  # A run whose composition applied `sources`: `{field, child state, current identity}`.
  defp approving(run, sources) do
    links =
      sources
      |> Enum.with_index()
      |> Map.new(fn {{field, state, identity}, i} ->
        {field, %{"child" => "C-#{i}", "state" => state, "current" => identity}}
      end)

    Map.update(
      run,
      "pending",
      %{"composition" => %{"version" => 1, "links" => links}},
      &Map.put(&1, "composition", %{"version" => 1, "links" => links})
    )
  end

  defp subject(values \\ %{}),
    do: %{"key" => "B-1", "values" => Map.merge(%{"title" => "a", "phase" => "first"}, values)}

  defp run(entry \\ 1), do: %{"key" => "r", "entry" => entry, "subject_key" => "B-1"}

  defp frozen(operation \\ "create", values \\ %{}) do
    {:ok, i} = Effect.freeze(run(), spec(operation), subject(values), @receivers)
    i
  end

  defp reply(i, extra \\ %{}) do
    Map.merge(
      %{
        "version" => 1,
        "id" => i["request"]["id"],
        "digest" => i["digest"],
        "fingerprint" => i["request"]["fingerprint"],
        "status" => "done",
        "reference" => "artifact-1",
        "outputs" => %{"reference" => "artifact-1"}
      },
      extra
    )
  end

  describe "the frozen request" do
    test "is enabled per receiver and operation only, never by default" do
      assert Effect.valid?(spec(), @receivers)
      refute Effect.valid?(spec())
      refute Effect.valid?(spec(), %{})
      only_create = put_in(@receivers, ["ledger", "operations"], ["create"])
      assert Effect.valid?(spec("create"), only_create)
      refute Effect.valid?(spec("update"), only_create)
      refute Effect.valid?(spec("integrate"), only_create)
      refute Effect.valid?(spec(), put_in(@receivers, ["ledger", "contract"], nil))
      refute Effect.valid?(Map.delete(spec(), "contract"), @receivers)
      refute Effect.valid?(Map.put(spec(), "service", "elsewhere"), @receivers)
      refute Effect.valid?(Map.delete(spec("update"), "target"), @receivers)
      refute Effect.valid?(Map.delete(spec("integrate"), "approved"), @receivers)
      # What approves it must be said: a field and the values of it that approve.
      refute Effect.valid?(Map.delete(spec("integrate"), "approving"), @receivers)
      refute Effect.valid?(Map.put(spec("integrate"), "approving", %{}), @receivers)

      refute Effect.valid?(
               Map.put(spec("integrate"), "approving", %{"verdict" => []}),
               @receivers
             )

      # The approved identity must be one the fingerprint covers.
      refute Effect.valid?(Map.put(spec("integrate"), "approved", "artifact"), @receivers)

      # The shape the flow format writes without a contract names no enabled one: refused.
      {:effect, generated} = Sorts.Unbound.mechanism("publishing")
      refute Effect.valid?(generated, @receivers)
      assert {:error, :unsupported_definition} = Run.validate(Sorts.Unbound)
    end

    test "has a stable identity per run, entry and activity name, and survives JSON" do
      i = frozen()
      assert i["request"]["id"] == Effect.id(run(), spec())
      assert i["request"]["id"] =~ ~r/\A[0-9a-f]{64}\z/
      assert i["digest"] == Digest.of_term(i["request"])
      assert i["request"]["payload"] == %{"title" => "a"}
      assert i["address"] == @address and i["attempt"] == "submit"
      assert JSON.decode!(JSON.encode!(i)) == i
      {:ok, next} = Effect.freeze(run(2), spec(), subject(), @receivers)
      refute next["request"]["id"] == i["request"]["id"]
      assert Effect.current?(i, subject())
      refute Effect.current?(i, subject(%{"title" => "b"}))
    end

    test "an update waits for its target, an integration for its run's approval of this identity" do
      assert {:error, :not_ready} = Effect.freeze(run(), spec("update"), subject(), @receivers)
      u = frozen("update", %{"artifact" => "artifact-1"})
      assert u["request"]["target"] == "artifact-1"
      fp = u["request"]["fingerprint"]
      target = subject(%{"artifact" => "artifact-1"})

      freeze = fn r, s -> Effect.freeze(r, spec("integrate"), s, @receivers, @links) end
      accepted = {"verdict", "accepted", "a"}

      # No approval, an approval of another title, one current approval beside a stale
      # one, a check of no title, or a check of this title that rejected it: not ready.
      for r <- [
            run(),
            approving(run(), [{"verdict", "accepted", "b"}]),
            approving(run(), [accepted, {"tally", "counted", "b"}]),
            approving(run(), [{"verdict", "accepted", nil}]),
            approving(run(), [{"verdict", "rejected", "a"}]),
            # A link that only some other field's applied, not the approving one.
            approving(run(), [{"tally", "counted", "a"}])
          ],
          do: assert({:error, :not_ready} = freeze.(r, target))

      # Without the composition's links nothing says what the link wrote: no approval.
      assert {:error, :not_ready} =
               Effect.freeze(approving(run(), [accepted]), spec("integrate"), target, @receivers)

      # A field written by hand is no approval.
      assert {:error, :not_ready} =
               freeze.(run(), subject(%{"artifact" => "artifact-1", "approved" => fp}))

      # The check of this title accepted it, and every other current link is of this title:
      # frozen, carrying its fingerprint.
      for r <- [
            approving(run(), [accepted]),
            approving(run(), [accepted, {"tally", "counted", "a"}]),
            approving(run(), [accepted, {"tally", "counted", nil}])
          ] do
        {:ok, i} = freeze.(r, target)
        assert i["request"]["approved"] == fp
        assert i["request"]["id"] == Effect.id(run(), spec())
      end

      # The title moved on after its approval: not ready again.
      assert {:error, :not_ready} =
               freeze.(
                 approving(run(), [accepted]),
                 subject(%{"artifact" => "artifact-1", "title" => "b"})
               )
    end
  end

  describe "replies" do
    test "repeated id, stale fingerprint, old entry, changed payload and unknown outcome are fenced" do
      i = frozen()
      r = reply(i)
      assert {:ok, ^r} = Effect.validate_reply(i, r)
      assert {:ok, ^r} = Effect.validate_reply(i, r)

      for {field, value} <- [
            {"version", 2},
            {"id", "foreign"},
            {"digest", "old"},
            {"fingerprint", "stale"},
            {"reference", ""},
            {"outputs", nil},
            {"status", "running"}
          ] do
        assert {:error, :invalid_effect_evidence} =
                 Effect.validate_reply(i, Map.put(r, field, value)),
               field
      end

      {:ok, later} = Effect.freeze(run(2), spec(), subject(), @receivers)
      assert {:error, :invalid_effect_evidence} = Effect.validate_reply(later, r)

      refused = reply(i, %{"status" => "refused", "reason" => "unknown target"})
      assert {:ok, ^refused} = Effect.validate_reply(i, Map.drop(refused, []))
      assert {:error, _} = Effect.validate_reply(i, Map.put(refused, "reason", ""))

      for status <- ["unknown", "conflict"] do
        assert {:error, :effect_requires_reconciliation} =
                 Effect.validate_reply(i, reply(i, %{"status" => status}))
      end

      # A conflict binds the id, whichever digest the receiver echoes.
      assert {:error, :effect_requires_reconciliation} =
               Effect.validate_reply(i, reply(i, %{"status" => "conflict", "digest" => "theirs"}))

      waiting = Map.merge(i, %{"attempt" => "lookup", "retry_at" => "2026-11-12T00:00:01Z"})

      assert {:retry, %{"attempt" => "submit", "retry_at" => nil}} =
               Effect.validate_reply(waiting, reply(i, %{"status" => "not_found"}))

      assert {:error, _} = Effect.validate_reply(i, "malformed")
    end

    test "records and outputs become replayable writes with ids bound to the activity" do
      i = frozen()
      [record, change] = Effect.writes(i, spec(), run(), reply(i))
      assert record["kind"] == "crate"
      assert record["content"]["op"] == "create"
      assert record["content"]["key"] == record["id"]
      assert record["content"]["values"] == %{"label" => "artifact-1"}
      assert record["content"]["links"] == %{"in_box" => ["B-1"]}

      assert change["content"]["values"] == %{
               "effect_result" => "done",
               "artifact" => "artifact-1"
             }

      assert Effect.writes(i, spec(), run(), reply(i)) == [record, change]

      [refusal] =
        Effect.writes(i, spec(), run(), reply(i, %{"status" => "refused", "reason" => "no"}))

      assert refusal["content"]["values"] == %{"effect_result" => "refused"}
      assert refusal["id"] == change["id"]
    end
  end

  describe "the private receiver" do
    test "passes the receiver contract for create, update and integrate", %{tmp_dir: dir} do
      pid = start_supervised!({EffectReceiver, dir: dir, address: @address})
      call = &EffectReceiver.request(pid, &1)
      create = frozen()["request"]
      assert :ok = EffectReceiverContract.check!(call, [create])
      update = frozen("update", %{"artifact" => "artifact-1"})["request"]

      {:ok, %{"request" => integrate}} =
        Effect.freeze(
          approving(run(), [{"verdict", "accepted", "a"}]),
          spec("integrate"),
          subject(%{"artifact" => "artifact-1"}),
          @receivers,
          @links
        )

      # Different entries: different ids for the same activity name.
      update = Map.put(update, "id", Effect.id(run(2), spec()))
      integrate = Map.put(integrate, "id", Effect.id(run(3), spec()))
      assert :ok = EffectReceiverContract.check!(call, [update, integrate])
      assert length(EffectReceiver.operations(dir)) == 3

      # A restarted receiver returns the original result from its journal.
      stop_supervised!(EffectReceiver)
      pid = start_supervised!({EffectReceiver, dir: dir, address: @address})
      d = Digest.of_term(create)

      again =
        EffectReceiver.request(pid, %{"operation" => "lookup", "request" => create, "digest" => d})

      assert again["reference"] == "artifact-1"
      assert length(EffectReceiver.operations(dir)) == 3
    end
  end

  describe "through the run store" do
    setup %{tmp_dir: dir} do
      previous = Application.get_env(:atlas_flow, :effect_receivers)
      Application.put_env(:atlas_flow, :effect_receivers, @receivers)
      on_exit(fn -> Application.put_env(:atlas_flow, :effect_receivers, previous) end)
      c = put_in(AtlasFlow.TestModel.config(), ["selection", "sort", "imports"], [])
      start_supervised!(FakeFacts)
      clock = start_supervised!({ManualClock, @now})
      receiver = start_supervised!({EffectReceiver, dir: dir, address: @address})
      :ok = AtlasBus.attach("flow")
      FakeFacts.put("box", subject())
      flow = Sorts.Publish
      assert :ok = Run.validate(flow)
      %{c: c, flows: %{"sort" => flow}, clock: clock, receiver: receiver, dir: dir}
    end

    test "a lost response is recovered by lookup: one operation, its original result", c do
      EffectReceiver.lose(c.receiver)
      {:ok, [sent]} = reconcile(c)
      frozen = sent["pending"]["effect"]
      assert frozen["attempt"] == "lookup"
      barrier(c)
      {:ok, [waiting]} = reconcile(c)
      assert waiting["state"] == "publishing" and waiting["pending"]["effect"] == frozen
      [{id, "create", "artifact-1"}] = EffectReceiver.operations(c.dir)
      assert id == frozen["request"]["id"]

      # Restart Flow's side: only the run in Facts holds the request.
      restart_inbox()
      ManualClock.advance(c.clock, 999)
      assert {:ok, [^waiting]} = reconcile(c)
      ManualClock.advance(c.clock, 1)
      {:ok, _} = reconcile(c)
      barrier(c)
      {:ok, [done]} = reconcile(c)
      assert done["state"] == "done" and done["status"] == "completed"
      assert done["last_input"]["reference"] == "artifact-1"
      assert [%{"request" => request, "result" => result}] = done["pending"]["effects"]
      assert request == frozen["request"] and result["reference"] == "artifact-1"
      assert length(EffectReceiver.operations(c.dir)) == 1
      assert FakeFacts.get("box", "B-1")["values"]["artifact"] == "artifact-1"
      assert [_] = crates()
    end

    test "a lookup that finds nothing submits the same request again, once", c do
      # The first submit never reaches the receiver.
      stop_supervised!(EffectReceiver)
      {:ok, [sent]} = reconcile(c)
      barrier_inbox()
      receiver = start_supervised!({EffectReceiver, dir: c.dir, address: @address})
      c = %{c | receiver: receiver}
      ManualClock.advance(c.clock, 1000)
      {:ok, _} = reconcile(c)
      barrier(c)
      {:ok, _} = reconcile(c)
      barrier(c)
      {:ok, [done]} = reconcile(c)
      assert done["status"] == "completed"
      assert [%{"request" => request}] = done["pending"]["effects"]
      assert request == sent["pending"]["effect"]["request"]
      assert [{_, "create", "artifact-1"}] = EffectReceiver.operations(c.dir)
    end

    test "partial record writes replay under their ids to exactly one record", c do
      # Hold the answer until the run has stored its request and waits.
      :sys.suspend(c.receiver)
      {:ok, _} = reconcile(c)
      :sys.resume(c.receiver)
      barrier(c)
      FakeFacts.lose_ack("crate")
      assert {:error, {:pending, _}} = reconcile(c)
      assert [_] = crates()
      assert FakeFacts.get("box", "B-1")["values"]["effect_result"] == "none"
      restart_inbox()
      {:ok, [done]} = reconcile(c)
      assert done["status"] == "completed" and done["pending"]["writes"] == []
      assert [crate] = crates()
      assert crate["values"]["label"] == "artifact-1" and crate["links"]["in_box"] == ["B-1"]
      assert FakeFacts.get("box", "B-1")["values"]["effect_result"] == "done"
      assert length(EffectReceiver.operations(c.dir)) == 1
    end

    test "a refusal takes its branch and writes no record", c do
      flows = %{"sort" => Sorts.Update}
      c = %{c | flows: flows}
      FakeFacts.put("box", subject(%{"artifact" => "missing"}))
      {:ok, _} = reconcile(c)
      barrier(c)
      {:ok, [stuck]} = reconcile(c)
      assert stuck["state"] == "stuck"
      assert stuck["last_input"]["status"] == "refused"
      assert FakeFacts.get("box", "B-1")["values"]["effect_result"] == "refused"
      assert crates() == [] and EffectReceiver.operations(c.dir) == []
    end

    test "an unknown remote outcome blocks with the frozen request kept", c do
      EffectReceiver.uncertain(c.receiver)
      {:ok, [sent]} = reconcile(c)
      barrier(c)
      {:ok, [blocked]} = reconcile(c)
      assert blocked["status"] == "blocked"
      assert blocked["blocked_reason"] =~ "unknown"
      assert blocked["pending"]["effect"]["request"] == sent["pending"]["effect"]["request"]
      ManualClock.advance(c.clock, 10_000)
      assert {:ok, [^blocked]} = reconcile(c)
      assert crates() == []
    end

    test "a changed payload under a used id is refused by the receiver and blocks", c do
      :sys.suspend(c.receiver)
      {:ok, [sent]} = reconcile(c)
      # Another payload was bound to this id first (an earlier, different deployment).
      r = sent["pending"]["effect"]["request"]
      other = put_in(r, ["payload", "title"], "other")
      result = %{"status" => "done", "reference" => "artifact-9", "outputs" => %{}}
      record = %{"request" => other, "digest" => Digest.of_term(other), "result" => result}
      File.write!(Path.join([c.dir, "journal", r["id"] <> ".json"]), JSON.encode!(record))
      :sys.resume(c.receiver)
      barrier(c)
      {:ok, [blocked]} = reconcile(c)
      assert blocked["status"] == "blocked" and blocked["blocked_reason"] =~ "conflicting"
      assert blocked["pending"]["effect"]["request"] == r
      assert crates() == [] and EffectReceiver.operations(c.dir) == []
    end

    test "a stale fingerprint blocks before any further attempt and late replies are ignored",
         c do
      EffectReceiver.lose(c.receiver)
      {:ok, _} = reconcile(c)
      barrier(c)
      FakeFacts.put("box", subject(%{"title" => "b"}))
      ManualClock.advance(c.clock, 1000)
      {:ok, [blocked]} = reconcile(c)
      barrier(c)
      assert blocked["status"] == "blocked" and blocked["blocked_reason"] =~ "binding changed"
      assert {:ok, [^blocked]} = reconcile(c)
      assert length(EffectReceiver.operations(c.dir)) == 1
      assert crates() == []
    end

    test "an integration is not frozen until its run approved this title", c do
      flows = %{"sort" => Sorts.Integrate}
      # The box's links, as the model's composition would give them (no check exists, so
      # the composition writes nothing itself).
      c = %{c | flows: flows, c: put_in(c.c, ["composition", "links"], @links)}
      fp = AtlasBus.SubjectFingerprint.of(subject(), spec()["fingerprint"])
      # A field written by hand, even holding the fingerprint, approves nothing.
      FakeFacts.put("box", subject(%{"artifact" => "artifact-1", "approved" => fp}))
      {:ok, [waiting]} = reconcile(c)
      assert waiting["pending"]["effect"] == nil
      assert EffectReceiver.operations(c.dir) == []

      # The run's composition applied a link from a child current for another title.
      stored = fn run ->
        key = run["key"]
        fact = FakeFacts.get("cursor", key)
        FakeFacts.put("cursor", %{fact | "values" => Store.encode(c.c, run)})
      end

      stored.(approving(waiting, [{"verdict", "accepted", "b"}]))
      {:ok, [still]} = reconcile(c)
      assert still["pending"]["effect"] == nil

      # One current for this title that rejected it.
      stored.(approving(still, [{"verdict", "rejected", "a"}]))
      {:ok, [rejected]} = reconcile(c)
      assert rejected["pending"]["effect"] == nil

      # And then one for this title that accepted it.
      stored.(approving(rejected, [{"verdict", "accepted", "a"}]))
      # Hold the answer: this reconcile freezes and sends, and must end while it waits.
      :sys.suspend(c.receiver)
      {:ok, [sent]} = reconcile(c)
      assert sent["pending"]["effect"]["request"]["approved"] == fp
      # Asked: a branch by hand no longer moves it, only the answer does.
      FakeFacts.put("box", subject(%{"artifact" => "artifact-1", "result" => "no"}))
      :sys.resume(c.receiver)
      barrier(c)
      # The private receiver holds no artifact-1, so it refuses; the approval was carried.
      {:ok, [stuck]} = reconcile(c)
      assert stuck["state"] == "stuck" and stuck["last_input"]["status"] == "refused"
      assert [%{"request" => %{"approved" => ^fp}}] = stuck["pending"]["effects"]
    end

    test "while nothing is asked, an effect's state takes its plain branches", c do
      c = %{
        c
        | flows: %{"sort" => Sorts.Integrate},
          c: put_in(c.c, ["composition", "links"], @links)
      }

      FakeFacts.put("box", subject(%{"artifact" => "artifact-1"}))
      {:ok, [waiting]} = reconcile(c)
      assert waiting["state"] == "publishing" and waiting["pending"]["effect"] == nil

      # Never approved, discarded by hand: it ends, and nothing was asked of the receiver.
      FakeFacts.put("box", subject(%{"artifact" => "artifact-1", "result" => "no"}))
      {:ok, [discarded]} = reconcile(c)
      assert {discarded["state"], discarded["status"]} == {"discarded", "completed"}
      assert discarded["last_input"]["branch"] == "discarded"
      assert discarded["pending"]["effect"] == nil
      assert EffectReceiver.operations(c.dir) == []
    end

    test "a timer passing without an answer is not proof: the run blocks, it does not branch",
         c do
      EffectReceiver.lose(c.receiver)
      {:ok, _} = reconcile(c)
      barrier(c)
      # The receiver stays unreachable from here on.
      stop_supervised!(EffectReceiver)
      ManualClock.advance(c.clock, 3_600_000 - 1)
      {:ok, [waiting]} = reconcile(c)
      assert waiting["status"] == "active"
      ManualClock.advance(c.clock, 1)
      {:ok, [blocked]} = reconcile(c)
      assert blocked["status"] == "blocked" and blocked["state"] == "publishing"
      assert blocked["blocked_reason"] =~ "no_answer"
      assert blocked["pending"]["effect"]["request"]["id"]
    end
  end

  defp reconcile(c), do: Store.reconcile(c.c, c.flows, ManualClock.now(c.clock))

  # Acknowledgement barriers, no timer waits.
  defp barrier(c) do
    :sys.get_state(c.receiver)
    barrier_inbox()
  end

  defp barrier_inbox, do: :sys.get_state(Effect.Inbox)

  defp restart_inbox do
    :ok = Supervisor.terminate_child(AtlasFlow.Root, Effect.Inbox)
    {:ok, _} = Supervisor.restart_child(AtlasFlow.Root, Effect.Inbox)
  end

  # Every record create Facts applied (a replay answered from its ledger is not one).
  defp crates do
    for f <- FakeFacts.sent(),
        f["op"] == "create",
        record = FakeFacts.get("crate", f["key"]),
        do: record
  end
end
