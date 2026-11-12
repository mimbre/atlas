defmodule AtlasFacts.GuidanceVisibilityTest do
  use ExUnit.Case, async: false
  alias AtlasBus.Envelope
  alias AtlasFacts.CountingRela
  @moduletag :tmp_dir

  defp schema do
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
        properties =
          Map.new(spec["fields"], fn {slot, field} ->
            type =
              cond do
                slot in ~w(queued_input durable_accept_query consumption_evidence) -> "boolean"
                slot == "recorded_position" -> "integer"
                true -> "string"
              end

            {field, %{"type" => type}}
          end)

        {spec["kind"], %{"plural" => role <> "s", "properties" => properties}}
      end)

    CountingRela.schema()
    |> Map.put("guidance", mapping)
    |> Map.update!("entities", &Map.merge(&1, entities))
    |> put_in(["entities", "run"], %{
      "plural" => "runs",
      "properties" => Map.new(~w(host fence status), &{&1, %{"type" => "string"}})
    })
    |> put_in(["relations", "performer"], %{"from" => ["run"], "to" => ["clerk"]})
    |> Map.put("runtime", %{
      "turn" => %{
        "kind" => "run",
        "machine" => "host",
        "attempt" => "fence",
        "by" => "performer",
        "state" => "status",
        "running" => "live"
      }
    })
  end

  setup %{tmp_dir: dir} do
    Application.put_env(
      :atlas_bus,
      :store,
      "protocol-visibility-#{System.unique_integer([:positive])}"
    )

    {:ok, backend} = CountingRela.start_link(0, schema: schema())
    assert {:ok, []} = CountingRela.create(backend, "clerks", "worker-a", %{}, %{})

    server =
      start_supervised!(
        {AtlasFacts.Server,
         rela: {CountingRela, backend},
         data_dir: dir,
         collection_clock: fn -> CountingRela.clock(backend) end}
      )

    :ok = AtlasBus.attach("control/session-protocol-#{System.unique_integer([:positive])}")
    %{backend: backend, server: server}
  end

  defp request(class, kind, content) do
    e = Envelope.new(class, kind)
    :ok = AtlasBus.send(e, content)
    assert_receive {:atlas_bus, %Envelope{id: id} = response, body} when id == e.id
    {response.class, body}
  end

  defp runtime(kind, content) do
    Task.async(fn ->
      :ok = AtlasBus.attach("runtime@box")

      try do
        request("fact", kind, content)
      after
        Registry.unregister(AtlasBus.Endpoints, "runtime@box")
      end
    end)
    |> Task.await()
  end

  defp create_run do
    runtime("run", %{
      "op" => "create",
      "key" => "run-a",
      "values" => %{"host" => "box", "fence" => "attempt-a", "status" => "live"},
      "links" => %{"performer" => ["worker-a"]}
    })
  end

  defp register do
    runtime("synthetic_execution", %{
      "op" => "register_execution",
      "values" => %{
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
    })
  end

  defp submit(execution) do
    request("fact", "synthetic_interaction", %{
      "op" => "submit_interaction",
      "by" => "reader-a",
      "values" => %{
        "client_key" => "client-a",
        "body" => "guidance",
        "worker" => "worker-a",
        "turn" => "run-a",
        "attempt" => "attempt-a",
        "mode" => "queued_guidance",
        "execution" => execution["key"],
        "cause" => "test"
      }
    })
  end

  test "a warmed turn list cannot consume an authority failure after turn creation", c do
    assert {"answer", %{"facts" => []}} = request("read", "run", %{})
    Agent.update(c.backend, &Map.put(&1, :get_after_create, %{{"runs", "run-a"} => :unavailable}))
    CountingRela.reset(c.backend)
    assert {"stored", _} = create_run()
    # No row refresh consumes the one-shot failed authority read. Registration
    # must fail before Runtime can use its acknowledgement to start an adapter.
    assert {"refused", %{"code" => "unavailable"}} = register()
    assert {:ok, []} = CountingRela.list(c.backend, "executions")
  end

  test "closed and replaced turns are visible immediately after direct writes", c do
    assert {"stored", _} = create_run()
    request("read", "run", %{})

    assert {:ok, []} =
             CountingRela.change(c.backend, "runs", "run-a", %{"status" => "over"}, nil, %{})

    :ok = AtlasFacts.Server.flush_collections(c.server)

    assert {"answer", %{"fact" => %{"values" => %{"status" => "over"}}}} =
             request("read", "run", %{"key" => "run-a", "plain" => true})

    assert {"refused", %{"code" => "execution_authority"}} = register()

    assert {:ok, []} =
             CountingRela.change(
               c.backend,
               "runs",
               "run-a",
               %{"status" => "live", "fence" => "new"},
               nil,
               %{}
             )

    :ok = AtlasFacts.Server.flush_collections(c.server)
    assert {"refused", %{"code" => "execution_authority"}} = register()
    assert CountingRela.clock(c.backend) == 0
  end

  test "receipt writes and direct closure evidence immediately update the projection", c do
    assert {"stored", _} = create_run()
    assert {"stored", %{"fact" => execution}} = register()
    assert {"stored", %{"fact" => interaction}} = submit(execution)
    key = interaction["key"]
    assert interaction["projection"]["closures"] == []

    receipt =
      Map.take(interaction, ~w(worker turn attempt execution))
      |> Map.merge(%{
        "interaction" => key,
        "stage" => "stale",
        "evidence_id" => "closure-a",
        "reason" => "ended",
        "cause" => "test"
      })

    assert {"stored", _} =
             runtime("synthetic_receipt", %{"op" => "record_receipt", "values" => receipt})

    assert {"answer", %{"fact" => view}} =
             request("read", "synthetic_interaction", %{"key" => key})

    assert view["projection"]["closures"] == ["stale"]

    assert {"answer", %{"facts" => [_]}} =
             request("read", "synthetic_receipt", %{"interaction" => key})

    values =
      receipt
      |> Map.put("stage", "rejected")
      |> Map.put("evidence_id", "closure-b")
      |> Map.put("environment", AtlasBus.environment())
      |> Map.put("recorded_position", 999)
      |> Map.put("recorded_at", "2026-11-12T00:00:00Z")

    fields = schema()["guidance"]["receipt"]["fields"]
    props = Map.new(values, fn {slot, value} -> {Map.fetch!(fields, slot), value} end)
    assert {:ok, []} = CountingRela.create(c.backend, "receipts", "direct-closure", props, %{})
    :ok = AtlasFacts.Server.flush_collections(c.server)

    assert {"answer", %{"fact" => view}} =
             request("read", "synthetic_interaction", %{"key" => key})

    assert view["projection"]["closures"] == ["rejected", "stale"]
    assert view["receipt_count"] == 2

    assert {"answer", %{"facts" => receipts}} =
             request("read", "synthetic_receipt", %{"interaction" => key})

    assert length(receipts) == 2
    assert CountingRela.clock(c.backend) == 0
  end

  test "protocol reads always reach the backend, including failed authority reads", c do
    assert {"stored", _} = create_run()
    assert {"stored", %{"fact" => execution}} = register()
    assert {"stored", %{"fact" => interaction}} = submit(execution)

    for _ <- 1..2 do
      CountingRela.reset(c.backend)
      assert {"answer", _} = request("read", "synthetic_execution", %{"key" => execution["key"]})

      assert {"answer", _} =
               request("read", "synthetic_interaction", %{"key" => interaction["key"]})

      assert CountingRela.calls(c.backend) == %{{:list, "receipts"} => 1, :get => 2}
    end

    Agent.update(c.backend, &%{&1 | down: true})

    assert {"answer", %{"code" => "unavailable"}} =
             request("read", "synthetic_execution", %{"key" => execution["key"]})

    assert {"answer", %{"code" => "unavailable"}} =
             request("read", "synthetic_interaction", %{"key" => interaction["key"]})
  end
end
