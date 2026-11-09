defmodule AtlasFacts.GuidanceTest do
  use ExUnit.Case, async: false
  alias AtlasBus.Envelope
  alias AtlasFacts.{Guidance, GuidanceStore, Rela}
  @moduletag :tmp_dir
  defp description do
    roles = %{
      "execution" =>
        ~w(environment worker turn attempt machine harness harness_version configured_model reported_model capability_version queued_input durable_accept_query consumption_evidence recorded_at recorded_position),
      "interaction" =>
        ~w(environment actor client_key body body_digest worker turn attempt mode execution cause recorded_at recorded_position),
      "receipt" =>
        ~w(environment interaction worker turn attempt execution stage evidence_id admission_id consumption_id reason writer cause recorded_at recorded_position)
    }

    mapping =
      Map.new(roles, fn {role, fields} ->
        {role,
         %{"kind" => "synthetic_" <> role, "fields" => Map.new(fields, &{&1, "slot_" <> &1})}}
      end)

    entities =
      Map.new(mapping, fn {role, spec} ->
        props =
          Map.new(spec["fields"], fn {slot, field} ->
            {field,
             %{
               "type" =>
                 if(slot in ~w(queued_input durable_accept_query consumption_evidence),
                   do: "boolean",
                   else: if(slot == "recorded_position", do: "integer", else: "string")
                 )
             }}
          end)

        {spec["kind"], %{"plural" => role <> "s", "properties" => props}}
      end)

    %{
      "guidance" => mapping,
      "entities" =>
        Map.put(entities, "run", %{
          "plural" => "runs",
          "properties" => Map.new(~w(host fence status), &{&1, %{"type" => "string"}})
        }),
      "runtime" => %{
        "turn" => %{
          "kind" => "run",
          "machine" => "host",
          "attempt" => "fence",
          "by" => "performer",
          "state" => "status",
          "running" => "live"
        }
      }
    }
  end

  setup %{tmp_dir: dir} do
    d = description()

    Application.put_env(
      :atlas_bus,
      :store,
      "guidance-state-#{System.unique_integer([:positive])}"
    )

    {:ok, store} = GuidanceStore.start(Path.join(dir, "facts.json"), d)
    rela = {GuidanceStore, store}

    {:ok, []} =
      Rela.create(
        rela,
        "runs",
        "run-a",
        %{"host" => "box", "fence" => "attempt-a", "status" => "live"},
        %{"performer" => {"actor", ["worker-a"]}}
      )

    server = start_supervised!({AtlasFacts.Server, rela: rela, data_dir: dir})
    :ok = AtlasBus.attach("control/session-#{System.unique_integer([:positive])}")

    assert {"stored", %{"fact" => ex}, _} =
             as("runtime@box", "execution", %{
               "op" => "register_execution",
               "values" => execution()
             })

    %{store: store, rela: rela, d: d, execution: ex, dir: dir, server: server}
  end

  defp execution,
    do: %{
      "worker" => "worker-a",
      "turn" => "run-a",
      "attempt" => "attempt-a",
      "machine" => "box",
      "harness" => "stub",
      "harness_version" => "1",
      "configured_model" => "fake",
      "capability_version" => "1",
      "queued_input" => true,
      "durable_accept_query" => true,
      "consumption_evidence" => true
    }

  test "execution lookup is bounded to exact environment turn and attempt", c do
    assert {"answer", %{"fact" => fact}, _} =
             request("execution", %{"turn" => "run-a", "attempt" => "attempt-a"}, class: "read")

    assert fact == c.execution

    assert {"answer", %{"code" => "not_found"}, _} =
             request("execution", %{"turn" => "run-a", "attempt" => "different"}, class: "read")

    assert {"answer", %{"code" => "exact_identity_required"}, _} =
             request("execution", %{}, class: "read")
  end

  defp interaction(ex),
    do: %{
      "op" => "submit_interaction",
      "by" => "reader-a",
      "values" => %{
        "client_key" => "client-1",
        "body" => "/literal guidance",
        "worker" => "worker-a",
        "turn" => "run-a",
        "attempt" => "attempt-a",
        "mode" => "queued_guidance",
        "execution" => ex["key"],
        "cause" => "user submitted"
      }
    }

  defp receipt(i, stage, extra \\ %{}) do
    v =
      Map.take(i, ~w(worker turn attempt execution))
      |> Map.merge(%{
        "interaction" => i["key"],
        "stage" => stage,
        "evidence_id" => "evidence-" <> stage,
        "cause" => "harness lookup"
      })
      |> Map.merge(extra)

    %{"op" => "record_receipt", "values" => v}
  end

  defp request(role, content, opts \\ []) do
    e =
      Envelope.new(
        Keyword.get(opts, :class, "fact"),
        Keyword.get(opts, :kind, "synthetic_" <> role),
        Keyword.take(opts, [:id, :environment])
      )

    case AtlasBus.send(e, content) do
      :ok ->
        assert_receive {:atlas_bus, %Envelope{id: id} = reply, body} when id == e.id, 2_000
        {reply.class, body, reply.position}

      error ->
        error
    end
  end

  defp as(endpoint, role, content, opts \\ []),
    do:
      Task.async(fn ->
        :ok = AtlasBus.attach(endpoint)

        try do
          request(role, content, opts)
        after
          # Task.await can return before Registry handles the task's DOWN signal.
          # Release synchronously before another request reuses this exact identity.
          Registry.unregister(AtlasBus.Endpoints, endpoint)
        end
      end)
      |> Task.await()

  defp race(content, other) do
    owner = self()

    tasks =
      for {c, n} <- [{content, 1}, {other, 2}] do
        Task.async(fn ->
          :ok = AtlasBus.attach("control/session-race-#{n}")
          send(owner, {:ready, self()})

          receive do
            :go -> request("interaction", c)
          end
        end)
      end

    for _ <- tasks, do: assert_receive({:ready, _})
    Enum.each(tasks, &send(&1.pid, :go))
    Enum.map(tasks, &Task.await/1)
  end

  test "concurrent identical submissions return one immutable fact and position", c do
    content = interaction(c.execution)
    [a, b] = race(content, content)
    assert a == b
    assert {"stored", %{"fact" => f}, _} = a
    assert f["projection"] == %{"proven" => "queued", "uncertain" => false, "closures" => []}
    assert {:ok, [_]} = Rela.list(c.rela, "interactions")
  end

  test "deployment guard probes stay distinct from valid private scoped reads", c do
    # These are semantic roles mapped to synthetic kinds/properties, not production data.
    for role <- ~w(execution interaction receipt) do
      assert {"answer",
              %{"code" => "exact_identity_required", "error" => ":exact_identity_required"},
              _} =
               request(role, %{}, class: "read")
    end

    assert {"stored", %{"fact" => note}, _} = request("interaction", interaction(c.execution))
    evidence = receipt(note, "delivered", %{"admission_id" => "private-inbox"})
    assert {"refused", %{"code" => "receipt_authority"}, _} = request("receipt", evidence)
    assert {"stored", %{"fact" => proof}, _} = as("runtime@box", "receipt", evidence)
    before = for plural <- ~w(executions interactions receipts), do: Rela.list(c.rela, plural)

    assert {"answer", %{"fact" => execution}, _} =
             request("execution", %{"key" => c.execution["key"]}, class: "read")

    assert execution["key"] == c.execution["key"]

    assert {"answer", %{"facts" => [found], "more" => false}, _} =
             request("interaction", %{"execution" => execution["key"], "limit" => 1},
               class: "read"
             )

    assert found["key"] == note["key"]

    assert {"answer", %{"facts" => [^proof], "more" => false}, _} =
             request("receipt", %{"interaction" => note["key"], "limit" => 1}, class: "read")

    assert {"answer", %{"code" => "invalid_page"}, _} =
             request("interaction", %{"execution" => execution["key"], "limit" => 0},
               class: "read"
             )

    assert {"answer", %{"code" => "not_found"}, _} =
             request("receipt", %{"interaction" => "absent-private-parent"}, class: "read")

    assert before ==
             for(plural <- ~w(executions interactions receipts), do: Rela.list(c.rela, plural))
  end

  test "a private backend failure is not the exact-identity guard", c do
    GuidanceStore.fail_next_get(
      c.store,
      "executions",
      c.execution["key"],
      {:unavailable, "private outage"}
    )

    assert {"answer", %{"code" => "store_error", "error" => error}, _} =
             request("execution", %{"key" => c.execution["key"]}, class: "read")

    assert error =~ "private outage"
    refute error == ":exact_identity_required"
  end

  test "concurrent conflicting bodies have one winner", c do
    content = interaction(c.execution)
    result = race(content, put_in(content, ["values", "body"], "changed"))
    assert Enum.sort(Enum.map(result, &elem(&1, 0))) == ["refused", "stored"]
    assert {:ok, [_]} = Rela.list(c.rela, "interactions")
  end

  test "all target fields and body/mode/cause are immutable", c do
    content = interaction(c.execution)
    assert {"stored", _, _} = request("interaction", content)

    for field <- ~w(worker turn attempt mode execution body cause) do
      assert {"refused", %{"code" => "immutable_conflict"}, _} =
               request("interaction", put_in(content, ["values", field], "changed"))
    end
  end

  test "actor isolation and environment injection refusal", c do
    content = interaction(c.execution)
    {"stored", %{"key" => a}, _} = request("interaction", content)
    {"stored", %{"key" => b}, _} = request("interaction", %{content | "by" => "reader-b"})
    assert a != b

    for field <- ~w(actor environment body_digest recorded_at) do
      assert {"refused", %{"code" => "unknown_fields"}, _} =
               request("interaction", put_in(content, ["values", field], "forged"))
    end

    assert {:error, {:other_environment, "elsewhere"}} =
             request("interaction", content, environment: "elsewhere")

    e = %{
      Envelope.new("fact", "synthetic_interaction")
      | environment: "elsewhere",
        sender: "control/session-forged"
    }

    assert {:error, :wrong_environment} =
             Guidance.write(c.rela, c.d, "interaction", e, content, fn -> 1 end)
  end

  test "writer validation precedes successful envelope id replay", c do
    content = interaction(c.execution)
    assert {"stored", %{"fact" => f}, _} = request("interaction", content, id: "shared")

    assert {"refused", %{"code" => "interaction_authority"}, _} =
             as("runtime@box", "interaction", content, id: "shared")

    r = receipt(f, "delivered", %{"admission_id" => "inbox-1"})
    assert {"stored", _, _} = as("runtime@box", "receipt", r, id: "r-shared")

    assert {"refused", %{"code" => "receipt_authority"}, _} =
             request("receipt", r, id: "r-shared")

    assert {"refused", %{"code" => "receipt_authority"}, _} =
             as("runtime@other", "receipt", r, id: "r-shared")

    assert {"refused", _, _} =
             as("runtime@box", "receipt", put_in(r, ["values", "attempt"], "replacement"))
  end

  test "generic CRUD cannot alter or delete durable records", c do
    {"stored", %{"key" => key}, _} = request("interaction", interaction(c.execution))

    for op <- ~w(create change delete), role <- ~w(execution interaction receipt) do
      assert {"refused", %{"code" => "protected_operation_required"}, _} =
               request(role, %{"op" => op, "key" => key, "values" => %{}})
    end
  end

  test "receipt replay returns original; projection retains proof and uncertainty", c do
    content = interaction(c.execution)
    {"stored", %{"fact" => f}, position} = request("interaction", content)

    ack =
      receipt(f, "acknowledged", %{"admission_id" => "inbox-1", "consumption_id" => "context-1"})

    first = as("runtime@box", "receipt", ack)
    assert first == as("runtime@box", "receipt", ack)

    assert {"refused", %{"code" => "immutable_conflict"}, _} =
             as("runtime@box", "receipt", put_in(ack, ["values", "consumption_id"], "changed"))

    for {stage, extra} <- [
          {"delivered", %{"admission_id" => "inbox-1"}},
          {"uncertain", %{"reason" => "lost response"}},
          {"stale", %{"reason" => "turn ended"}}
        ] do
      assert {"stored", _, _} = as("runtime@box", "receipt", receipt(f, stage, extra))
    end

    assert {"stored", %{"fact" => current}, ^position} = request("interaction", content)

    assert current["projection"] == %{
             "proven" => "acknowledged",
             "uncertain" => true,
             "closures" => ["stale"]
           }

    assert current["receipt_count"] == 4
    assert length(receipt_history(current["key"], 0, [])) == 4

    assert {"answer", %{"fact" => ^current}, _} =
             request("interaction", %{"actor" => "reader-a", "client_key" => "client-1"},
               class: "read"
             )
  end

  test "receipt stages require correlated evidence or a reason", c do
    {"stored", %{"fact" => f}, _} = request("interaction", interaction(c.execution))

    for {stage, code} <- [
          {"delivered", "admission_evidence_required"},
          {"acknowledged", "consumption_evidence_required"},
          {"uncertain", "reason_required"},
          {"unsupported", "reason_required"},
          {"rejected", "reason_required"}
        ] do
      assert {"refused", %{"code" => ^code}, _} = as("runtime@box", "receipt", receipt(f, stage))
    end

    assert {:ok, []} = Rela.list(c.rela, "receipts")
  end

  test "execution registration checks durable turn and attempt", c do
    for field <- ~w(turn worker attempt machine) do
      assert {"refused", _, _} =
               as("runtime@box", "execution", %{
                 "op" => "register_execution",
                 "values" => Map.put(execution(), field, "other")
               })
    end

    assert {"refused", _, _} =
             request("execution", %{"op" => "register_execution", "values" => execution()})

    assert {"refused", %{"code" => "immutable_conflict"}, _} =
             as("runtime@box", "execution", %{
               "op" => "register_execution",
               "values" => Map.put(execution(), "configured_model", "changed")
             })

    refute Map.has_key?(c.execution, "reported_model")
  end

  test "lost create response recovers after Facts and store restart", c do
    content = interaction(c.execution)
    GuidanceStore.barrier(c.store, self())

    task =
      Task.async(fn ->
        :ok = AtlasBus.attach("control/session-lost")
        request("interaction", content)
      end)

    assert_receive {:committed, store, key}, 2_000
    Process.unlink(c.server)
    Process.exit(c.server, :kill)
    send(store, :release_commit)
    stop_supervised!(AtlasFacts.Server)
    Task.shutdown(task, :brutal_kill)
    Agent.stop(c.store)
    {:ok, fresh} = GuidanceStore.start(Path.join(c.dir, "facts.json"), c.d)
    start_supervised!({AtlasFacts.Server, rela: {GuidanceStore, fresh}, data_dir: c.dir})
    assert {"stored", %{"key" => ^key, "fact" => original}, _} = request("interaction", content)
    assert {:ok, [_]} = Rela.list({GuidanceStore, fresh}, "interactions")

    assert {"stored", %{"fact" => r}, _} =
             as(
               "runtime@box",
               "receipt",
               receipt(original, "delivered", %{"admission_id" => "recovered"})
             )

    stop_supervised!(AtlasFacts.Server)
    start_supervised!({AtlasFacts.Server, rela: {GuidanceStore, fresh}, data_dir: c.dir})
    assert {"stored", %{"fact" => restored}, _} = request("interaction", content)
    assert restored["recorded_at"] == original["recorded_at"]
    assert restored["receipt_count"] == 1
    assert receipt_history(restored["key"], 0, []) == [r]
    assert restored["projection"]["proven"] == "delivered"
  end

  test "malformed values refuse without crashing Facts", c do
    content = interaction(c.execution)

    for value <- [false, true, 12, [], %{}, nil] do
      assert {"refused", _, _} =
               request("interaction", put_in(content, ["values", "body"], value))
    end

    assert {"stored", %{"fact" => f}, _} = request("interaction", content)

    assert {"refused", %{"code" => "receipt_authority"}, _} =
             as(
               "runtime@box/another-turn",
               "receipt",
               receipt(f, "delivered", %{"admission_id" => "a"})
             )

    assert {"refused", %{"code" => "immutable_conflict"}, _} =
             request("interaction", put_in(content, ["values", "mode"], "interrupt"))
  end

  test "fenced turn authority cannot be replaced through generic writes", c do
    e = %{Envelope.new("fact", "run") | sender: "control/session-forged"}
    content = %{"op" => "change", "key" => "run-a", "values" => %{"fence" => "replacement"}}
    assert {:error, :turn_authority} = Guidance.authorize_turn(c.rela, c.d, e, content)

    assert {:error, :turn_authority} =
             Guidance.authorize_turn(c.rela, c.d, %{e | sender: "runtime@other"}, content)

    assert {:error, :turn_authority} =
             Guidance.authorize_turn(c.rela, c.d, %{e | sender: "runtime@box"}, content)

    assert :ok = Guidance.authorize_turn(c.rela, %{}, e, content)
    unfenced = put_in(c.d, ["runtime", "turn"], Map.delete(c.d["runtime"]["turn"], "attempt"))
    assert :ok = Guidance.authorize_turn(c.rela, unfenced, e, content)
  end

  test "execution history uses bounded durable position pages", c do
    content = interaction(c.execution)
    {"stored", %{"fact" => first}, position} = request("interaction", content)

    {"stored", %{"fact" => second}, _} =
      request("interaction", put_in(content, ["values", "client_key"], "second"))

    query = %{"execution" => c.execution["key"], "limit" => 1}

    assert {"answer", %{"facts" => [^first], "more" => true, "after_position" => ^position}, _} =
             request("interaction", query, class: "read")

    assert {"answer", %{"facts" => [^second], "more" => false}, _} =
             request("interaction", Map.put(query, "after_position", position), class: "read")

    assert {"answer", %{"code" => "invalid_page"}, _} =
             request("interaction", Map.put(query, "limit", 101), class: "read")
  end

  test "unsupported capability does not invent a queued interaction", c do
    # A different environment on this private store demonstrates independent dedup
    # scope without bridging actual environments or using any live facts.
    old = AtlasBus.environment()
    on_exit(fn -> Application.put_env(:atlas_bus, :environment, old) end)
    Application.put_env(:atlas_bus, :environment, "synthetic-other")

    assert {:error, :wrong_environment} =
             Guidance.read(c.rela, c.d, "execution", %{"key" => c.execution["key"]})

    e = %{Envelope.new("fact", "synthetic_execution") | sender: "runtime@box"}
    opts = fn -> System.unique_integer([:positive, :monotonic]) end

    assert {:ok, ex} =
             Guidance.write(
               c.rela,
               c.d,
               "execution",
               e,
               %{
                 "op" => "register_execution",
                 "values" => Map.put(execution(), "queued_input", false)
               },
               opts
             )

    assert ex["key"] != c.execution["key"]
    content = interaction(ex)
    e = %{Envelope.new("fact", "synthetic_interaction") | sender: "control/session-other"}
    assert {:error, :unsupported} = Guidance.write(c.rela, c.d, "interaction", e, content, opts)
    assert {:ok, []} = Rela.list(c.rela, "interactions")
  end

  test "P1 unreadable fenced turn cannot be moved by another Runtime", c do
    for reason <- [:unavailable, {:failed, "503 after a transient store failure"}, :not_found] do
      GuidanceStore.fail_next_get(c.store, "runs", "run-a", reason)

      assert {"refused", _, _} =
               as(
                 "runtime@other",
                 "unused",
                 %{"op" => "change", "key" => "run-a", "values" => %{"host" => "other"}},
                 kind: "run"
               )

      assert GuidanceStore.mutations(c.store) == []

      assert {:ok, %{properties: %{"host" => "box", "fence" => "attempt-a"}}} =
               Rela.get(c.rela, "runs", "run-a")
    end
  end

  test "P1 unreadable fenced turn cannot be deleted by Control", c do
    GuidanceStore.fail_next_get(c.store, "runs", "run-a", :unavailable)

    assert {"refused", _, _} =
             request("unused", %{"op" => "delete", "key" => "run-a"}, kind: "run")

    assert GuidanceStore.mutations(c.store) == []
    assert {:ok, _} = Rela.get(c.rela, "runs", "run-a")
  end

  test "P1 successful unfenced read retains legacy write compatibility", c do
    assert {:ok, []} =
             Rela.create(c.rela, "runs", "run-b", %{"host" => "box", "status" => "live"}, %{})

    assert {"stored", _, _} =
             as(
               "runtime@box",
               "unused",
               %{"op" => "change", "key" => "run-b", "values" => %{"status" => "ended"}},
               kind: "run"
             )

    assert {:ok, %{properties: %{"status" => "ended"}}} = Rela.get(c.rela, "runs", "run-b")
  end

  test "P1 only confirmed absence permits new fenced creation; unreadable unfenced state refuses",
       c do
    payload = %{
      "op" => "create",
      "key" => "run-new",
      "values" => %{"host" => "box", "fence" => "fresh", "status" => "live"}
    }

    assert {"stored", _, _} = as("runtime@box", "unused", payload, kind: "run")

    assert {:ok, []} =
             Rela.create(
               c.rela,
               "runs",
               "run-legacy",
               %{"host" => "box", "status" => "live"},
               %{}
             )

    GuidanceStore.fail_next_get(c.store, "runs", "run-legacy", :unavailable)

    assert {"refused", _, _} =
             as(
               "runtime@box",
               "unused",
               %{"op" => "change", "key" => "run-legacy", "values" => %{"status" => "ended"}},
               kind: "run"
             )

    assert GuidanceStore.mutations(c.store) == []
  end

  test "fenced delete exact replay preserves acknowledgement across restart", c do
    assert_delete_replay(c, "run-a")
  end

  test "historical unbound answer cannot acknowledge a present turn deletion after restart", c do
    :sys.replace_state(c.server, fn state ->
      AtlasFacts.Ledger.stored(state.ledger, "old-unbound", %{
        "op" => "delete",
        "key" => "previous-target"
      })

      state
    end)

    stop_supervised!(AtlasFacts.Server)
    server = start_supervised!({AtlasFacts.Server, rela: c.rela, data_dir: c.dir})
    assert_unbound_delete_refused(%{c | server: server}, "old-unbound")
    assert {:ok, _} = Rela.get(c.rela, "runs", "run-a")
  end

  test "ordinary unbound answer cannot acknowledge a present turn deletion", c do
    seed_ordinary_answer(c, "ordinary-unbound")
    assert_unbound_delete_refused(c, "ordinary-unbound")
    assert {:ok, _} = Rela.get(c.rela, "runs", "run-a")
  end

  test "completed deletion proof cannot relabel an answered unbound alias", c do
    seed_ordinary_answer(c, "ordinary-unbound")

    assert {"stored", _, _} =
             as("runtime@box", "unused", %{"op" => "delete", "key" => "run-a"},
               kind: "run",
               id: "proven-delete"
             )

    assert_unbound_delete_refused(c, "ordinary-unbound")
    assert {:error, :not_found} = Rela.get(c.rela, "runs", "run-a")
  end

  defp seed_ordinary_answer(_c, id) do
    assert {"stored", %{"op" => "create"}, _} =
             as(
               "runtime@box",
               "unused",
               %{
                 "op" => "create",
                 "key" => "unrelated",
                 "values" => %{
                   "host" => "box",
                   "fence" => "unrelated-attempt",
                   "status" => "live"
                 }
               },
               kind: "run",
               id: id
             )
  end

  defp assert_unbound_delete_refused(c, id) do
    ledger = :sys.get_state(c.server).ledger
    original = AtlasFacts.Ledger.answer(ledger, id)
    mutations = GuidanceStore.mutations(c.store)
    assert AtlasFacts.Ledger.request(ledger, id) == nil

    for sender <- ["runtime@box", "runtime@other", "turn/run-a"] do
      assert {"refused", _, _} =
               as(sender, "unused", %{"op" => "delete", "key" => "run-a"}, kind: "run", id: id)

      assert AtlasFacts.Ledger.request(ledger, id) == nil
      assert AtlasFacts.Ledger.answer(ledger, id) == original
      assert GuidanceStore.mutations(c.store) == mutations
    end

    # The journal primitive must also refuse to relabel an ordinary answer, even
    # if a future caller omits the Server's pre-cache eligibility check.
    binding = %{
      environment: AtlasBus.environment(),
      kind: "run",
      sender: "runtime@box",
      content: %{"op" => "delete", "key" => "run-a"}
    }

    assert {:error, :request_conflict} =
             AtlasFacts.Ledger.prepare_delete(ledger, id, binding, %{machine: "box"})

    assert AtlasFacts.Ledger.request(ledger, id) == nil
    assert AtlasFacts.Ledger.answer(ledger, id) == original
  end

  test "legacy delete exact replay preserves acknowledgement across restart", c do
    assert {:ok, []} =
             Rela.create(
               c.rela,
               "runs",
               "run-legacy",
               %{"host" => "box", "status" => "ended"},
               %{}
             )

    assert_delete_replay(c, "run-legacy")
  end

  defp assert_delete_replay(c, key) do
    content = %{"op" => "delete", "key" => key, "values" => %{}}
    first = as("runtime@box", "unused", content, kind: "run", id: "delete-lost")
    assert elem(first, 0) == "stored"
    stop_supervised!(AtlasFacts.Server)
    Agent.stop(c.store)
    {:ok, fresh} = GuidanceStore.start(Path.join(c.dir, "facts.json"), c.d)
    start_supervised!({AtlasFacts.Server, rela: {GuidanceStore, fresh}, data_dir: c.dir})
    assert as("runtime@box", "unused", content, kind: "run", id: "delete-lost") == first

    for changed <- [
          Map.put(content, "cause", "different"),
          Map.put(content, "version", "old"),
          %{content | "key" => "other-target"},
          %{content | "values" => %{"host" => "other"}}
        ] do
      assert {"refused", %{"code" => "request_conflict"}, _} =
               as("runtime@box", "unused", changed, kind: "run", id: "delete-lost")
    end

    assert {"refused", %{"code" => "request_conflict"}, _} =
             as("runtime@box", "unused", content, kind: "other-kind", id: "delete-lost")

    assert {"refused", %{"code" => "request_conflict"}, _} =
             as("turn/" <> key, "unused", content, kind: "run", id: "delete-lost")

    assert {:error, {:other_environment, "elsewhere"}} =
             as("runtime@box", "unused", content,
               kind: "run",
               id: "delete-lost",
               environment: "elsewhere"
             )

    for reason <- [:unavailable, {:failed, "503"}] do
      GuidanceStore.fail_next_get(fresh, "runs", key, reason)

      assert {"refused", _, _} =
               as("runtime@box", "unused", content, kind: "run", id: "delete-lost")
    end

    assert as("runtime@box", "unused", content, kind: "run", id: "delete-lost") == first

    assert {"refused", _, _} =
             as("runtime@other", "unused", content, kind: "run", id: "delete-lost")

    assert {"refused", _, _} = request("unused", content, kind: "run", id: "delete-lost")

    assert {"refused", _, _} =
             as("runtime@other", "unused", content, kind: "run", id: "other-fresh")

    assert {"refused", _, _} = request("unused", content, kind: "run", id: "control-fresh")

    assert {"stored", _, _} =
             as("runtime@box", "unused", content, kind: "run", id: "delete-fresh")

    assert GuidanceStore.mutations(fresh) == []
  end

  test "a completed delete id cannot acknowledge another authorized target or payload", c do
    content = %{"op" => "delete", "key" => "run-a", "values" => %{}}

    assert {"stored", _, _} =
             as("runtime@box", "unused", content, kind: "run", id: "delete-bound")

    assert {:ok, []} =
             Rela.create(
               c.rela,
               "runs",
               "run-next",
               %{"host" => "box", "fence" => "attempt-next", "status" => "live"},
               %{}
             )

    assert {"refused", _, _} =
             as("runtime@box", "unused", %{content | "key" => "run-next"},
               kind: "run",
               id: "delete-bound"
             )

    assert {"refused", _, _} =
             as("runtime@box", "unused", Map.put(content, "cause", "changed"),
               kind: "run",
               id: "delete-bound"
             )

    assert {:ok, _} = Rela.get(c.rela, "runs", "run-next")
    assert length(GuidanceStore.mutations(c.store)) == 1
  end

  test "authorized delete committed before its acknowledgement recovers without another deletion",
       c do
    content = %{"op" => "delete", "key" => "run-a", "values" => %{}}
    GuidanceStore.delete_barrier(c.store, self())

    task =
      Task.async(fn ->
        :ok = AtlasBus.attach("runtime@box")
        request("unused", content, kind: "run", id: "delete-commit-gap")
      end)

    assert_receive {:deleted, store, "run-a"}, 2_000
    Process.unlink(c.server)
    Process.exit(c.server, :kill)
    send(store, :release_delete)
    stop_supervised!(AtlasFacts.Server)
    Task.shutdown(task, :brutal_kill)
    Agent.stop(c.store)
    {:ok, fresh} = GuidanceStore.start(Path.join(c.dir, "facts.json"), c.d)
    start_supervised!({AtlasFacts.Server, rela: {GuidanceStore, fresh}, data_dir: c.dir})
    recovered = as("runtime@box", "unused", content, kind: "run", id: "delete-commit-gap")
    assert elem(recovered, 0) == "stored"
    assert GuidanceStore.mutations(fresh) == []
    assert as("runtime@box", "unused", content, kind: "run", id: "delete-commit-gap") == recovered

    assert {:ok, []} =
             Rela.create(
               {GuidanceStore, fresh},
               "runs",
               "run-a",
               %{"host" => "box", "fence" => "replacement", "status" => "live"},
               %{}
             )

    assert {"refused", _, _} =
             as("runtime@box", "unused", content, kind: "run", id: "delete-commit-gap")

    assert GuidanceStore.mutations(fresh) == []
  end

  test "pending deletion authorization cannot transfer to a replacement attempt", c do
    content = %{"op" => "delete", "key" => "run-a", "values" => %{}}
    GuidanceStore.fail_next_delete(c.store, "runs", "run-a", :unavailable)

    assert {"refused", _, _} =
             as("runtime@box", "unused", content, kind: "run", id: "pending-delete")

    assert GuidanceStore.mutations(c.store) == []
    assert {:ok, []} = Rela.change(c.rela, "runs", "run-a", %{"fence" => "replacement"}, nil, %{})
    stop_supervised!(AtlasFacts.Server)
    start_supervised!({AtlasFacts.Server, rela: c.rela, data_dir: c.dir})

    assert {"refused", _, _} =
             as("runtime@box", "unused", content, kind: "run", id: "pending-delete")

    assert {"refused", _, _} =
             as("runtime@box", "unused", content, kind: "run", id: "fresh-pending-delete")

    refute Enum.any?(GuidanceStore.mutations(c.store), &(elem(&1, 0) == :delete))
    assert {:ok, %{properties: %{"fence" => "replacement"}}} = Rela.get(c.rela, "runs", "run-a")
  end

  test "P2 replay and interaction pages do not embed retained evidence", c do
    content = interaction(c.execution)
    {"stored", %{"fact" => f}, _} = request("interaction", content)

    evidence =
      for n <- 1..101 do
        assert {"stored", %{"fact" => r}, _} =
                 as(
                   "runtime@box",
                   "receipt",
                   receipt(f, "delivered", %{
                     "evidence_id" => "evidence-#{n}",
                     "admission_id" => "same-inbox"
                   })
                 )

        r
      end

    assert {"stored", %{"fact" => replay}, _} = request("interaction", content)
    refute Map.has_key?(replay, "receipts")
    assert replay["receipt_count"] == 101
    assert byte_size(JSON.encode!(replay)) < 2_048

    assert {"answer", %{"fact" => exact}, _} =
             request("interaction", %{"key" => f["key"]}, class: "read")

    refute Map.has_key?(exact, "receipts")

    assert {"answer", %{"facts" => [summary]}, _} =
             request("interaction", %{"execution" => c.execution["key"], "limit" => 1},
               class: "read"
             )

    refute Map.has_key?(summary, "receipts")
    restored = receipt_history(f["key"], 0, [])
    assert restored == evidence
    assert length(Enum.uniq_by(restored, & &1["key"])) == 101
    assert {:ok, persisted} = Rela.list(c.rela, "receipts")
    assert length(persisted) == 101
    stop_supervised!(AtlasFacts.Server)
    Agent.stop(c.store)
    {:ok, fresh} = GuidanceStore.start(Path.join(c.dir, "facts.json"), c.d)
    start_supervised!({AtlasFacts.Server, rela: {GuidanceStore, fresh}, data_dir: c.dir})
    assert {"stored", %{"fact" => after_restart}, _} = request("interaction", content)
    assert after_restart == replay
    assert receipt_history(f["key"], 0, []) == evidence
  end

  defp receipt_history(key, after_position, acc) do
    assert {"answer", page, _} =
             request(
               "receipt",
               %{"interaction" => key, "after_position" => after_position, "limit" => 17},
               class: "read"
             )

    assert byte_size(JSON.encode!(page)) <= 65_536
    acc = acc ++ page["facts"]

    if page["more"] do
      assert page["after_position"] > after_position
      receipt_history(key, page["after_position"], acc)
    else
      acc
    end
  end

  test "P2 per-record byte limits refuse oversized writes without storing", c do
    content = put_in(interaction(c.execution), ["values", "body"], String.duplicate("x", 40_000))
    assert {"refused", %{"code" => "record_too_large"}, _} = request("interaction", content)
    assert {:ok, []} = Rela.list(c.rela, "interactions")
    {"stored", %{"fact" => f}, _} = request("interaction", interaction(c.execution))

    assert {"refused", %{"code" => "record_too_large"}, _} =
             as(
               "runtime@box",
               "receipt",
               receipt(f, "uncertain", %{"reason" => String.duplicate("x", 9_000)})
             )

    assert {:ok, []} = Rela.list(c.rela, "receipts")
  end

  test "P2 a valid record at its byte boundary still replays after position growth", c do
    {"stored", %{"fact" => f}, _} = request("interaction", interaction(c.execution))

    {"stored", %{"fact" => base}, _} =
      as(
        "runtime@box",
        "receipt",
        receipt(f, "uncertain", %{"evidence_id" => "first", "reason" => "x"})
      )

    {:ok, raw} = Rela.get(c.rela, "receipts", base["key"])
    size = byte_size(JSON.encode!(Map.put(raw.properties, "key", raw.key)))

    input =
      receipt(f, "uncertain", %{
        "evidence_id" => "other",
        "reason" => String.duplicate("x", 8_192 - size + 1)
      })

    {"stored", %{"fact" => edge}, _} = as("runtime@box", "receipt", input)
    {:ok, raw_edge} = Rela.get(c.rela, "receipts", edge["key"])
    assert byte_size(JSON.encode!(Map.put(raw_edge.properties, "key", raw_edge.key))) == 8_192

    for n <- 1..6 do
      assert {"stored", _, _} =
               as(
                 "runtime@box",
                 "receipt",
                 receipt(f, "uncertain", %{"evidence_id" => "advance-#{n}", "reason" => "x"})
               )
    end

    replay = as("runtime@box", "receipt", input)
    assert elem(replay, 0) == "stored"
    assert elem(replay, 1)["fact"] == edge
  end

  test "P2 page bytes cap large interaction and receipt pages", c do
    for n <- 1..3 do
      v =
        interaction(c.execution)
        |> put_in(["values", "client_key"], "large-#{n}")
        |> put_in(["values", "body"], String.duplicate("x", 24_000))

      assert {"stored", _, _} = request("interaction", v)
    end

    assert {"answer", page, _} =
             request("interaction", %{"execution" => c.execution["key"], "limit" => 100},
               class: "read"
             )

    assert byte_size(JSON.encode!(page)) <= 65_536
    assert length(page["facts"]) == 2
    assert page["more"]
    f = hd(page["facts"])

    for n <- 1..20 do
      assert {"stored", _, _} =
               as(
                 "runtime@box",
                 "receipt",
                 receipt(f, "uncertain", %{
                   "evidence_id" => "large-#{n}",
                   "reason" => String.duplicate("x", 4_000)
                 })
               )
    end

    assert {"answer", receipts, _} =
             request("receipt", %{"interaction" => f["key"], "limit" => 100}, class: "read")

    assert byte_size(JSON.encode!(receipts)) <= 65_536
    assert length(receipts["facts"]) < 20
    assert receipts["more"]
    assert length(receipt_history(f["key"], 0, [])) == 20
  end

  test "projection is independent of receipt arrival order" do
    receipts = [
      %{"stage" => "acknowledged", "admission_id" => "a"},
      %{"stage" => "delivered", "admission_id" => "a"},
      %{"stage" => "stale"}
    ]

    assert Guidance.project(receipts) == Guidance.project(Enum.reverse(receipts))

    assert Guidance.project(
             receipts ++ [%{"stage" => "delivered", "admission_id" => "different"}]
           )["uncertain"]
  end
end
