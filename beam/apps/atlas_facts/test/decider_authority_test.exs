defmodule AtlasFacts.DeciderAuthorityTest do
  use ExUnit.Case, async: false
  alias AtlasBus.{Envelope, SubjectFingerprint}
  alias AtlasFacts.CountingRela, as: Store
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    fingerprint = %{"fields" => ["phase"], "relations" => []}
    schema = Store.schema()

    schema =
      put_in(schema, ["entities", "bead", "authority"], %{
        "when" => %{"status" => ["sealed"]},
        "writes" => %{"status" => ["sealed"]},
        "by" => "ruled_by",
        "kind" => "clerk",
        "agent_kind" => "stamp",
        "decider" => %{
          "gate" => "allocate",
          "kind" => "jar",
          "relation" => "about",
          "fingerprint" => fingerprint
        }
      })

    schema =
      put_in(schema, ["relations", "ruled_by"], %{"from" => ["bead"], "to" => ["clerk", "stamp"]})

    schema = put_in(schema, ["relations", "about"], %{"from" => ["jar"], "to" => ["bead"]})

    schema =
      update_in(schema, ["entities", "jar", "properties"], fn props ->
        Map.merge(
          props,
          Map.new(
            ~w(gate subject purpose verdict fingerprint decided_at),
            &{&1, %{"type" => "string"}}
          )
        )
      end)

    {:ok, store} = Store.start_link(0, schema: schema)
    Application.put_env(:atlas_bus, :store, "store-#{System.unique_integer([:positive])}")

    start_supervised!(
      {AtlasFacts.Server, rela: {Store, store}, data_dir: dir, collection_freshness_ms: 60_000}
    )

    :ok = AtlasBus.attach("authority-#{System.unique_integer([:positive])}")
    %{store: store, fingerprint: fingerprint}
  end

  defp send_write(kind, key, op, values, links \\ %{}, by \\ "stamp-A") do
    send_read(Envelope.new("fact", kind), %{
      "op" => op,
      "key" => key,
      "values" => values,
      "links" => links,
      "by" => by
    })
  end

  defp send_read(envelope, content) do
    :ok = AtlasBus.send(envelope, content)
    id = envelope.id
    assert_receive {:atlas_bus, %Envelope{id: ^id, class: class}, answer}, 1_000
    {class, answer}
  end

  test "no verdict refuses, a linked fresh verdict permits, a changed subject refuses again", c do
    assert {"stored", _} = send_write("stamp", "stamp-A", "create", %{})
    assert {"stored", _} = send_write("clerk", "clerk-A", "create", %{})
    fields = %{"phase" => "packing", "status" => "open"}

    assert {"stored", _} =
             send_write("bead", "bead-A", "create", fields, %{"ruled_by" => ["stamp-A"]})

    assert {"refused", _} = send_write("bead", "bead-A", "change", %{"status" => "sealed"})

    verdict = %{
      "gate" => "allocate",
      "purpose" => "decider",
      "subject" => "bead-A",
      "verdict" => "agent",
      "decided_at" => "2026-11-12T00:00:00Z",
      "fingerprint" => SubjectFingerprint.of(%{"values" => fields}, c.fingerprint)
    }

    assert {"stored", _} = send_write("jar", "jar-A", "create", verdict)
    assert {"refused", _} = send_write("bead", "bead-A", "change", %{"status" => "sealed"})
    assert {"stored", _} = send_write("jar", "jar-A", "change", %{}, %{"about" => ["bead-A"]})
    assert {"stored", _} = send_write("bead", "bead-A", "change", %{"status" => "sealed"})

    assert {"stored", _} =
             send_write("bead", "bead-A", "change", %{"status" => "open", "phase" => "unpacking"})

    assert {"refused", _} = send_write("bead", "bead-A", "change", %{"status" => "sealed"})

    assert {"stored", _} =
             send_write(
               "bead",
               "bead-A",
               "change",
               %{"status" => "sealed"},
               %{"ruled_by" => ["clerk-A"]},
               "clerk-A"
             )
  end

  test "authority lookup bypasses a warmed collection after an external verdict write", c do
    fields = %{"phase" => "packing", "status" => "open"}
    assert {"stored", _} = send_write("stamp", "stamp-A", "create", %{})

    assert {"stored", _} =
             send_write("bead", "bead-A", "create", fields, %{"ruled_by" => ["stamp-A"]})

    verdict = %{
      "gate" => "allocate",
      "purpose" => "decider",
      "subject" => "bead-A",
      "verdict" => "agent",
      "fingerprint" => SubjectFingerprint.of(%{"values" => fields}, c.fingerprint)
    }

    assert {"stored", _} = send_write("jar", "jar-A", "create", verdict, %{"about" => ["bead-A"]})
    assert {"answer", %{"facts" => _}} = send_read(Envelope.new("read", "jar"), %{})
    assert {:ok, _} = Store.change(c.store, "jars", "jar-A", %{"verdict" => "ask"}, nil, %{})
    Store.reset(c.store)
    assert {"refused", _} = send_write("bead", "bead-A", "change", %{"status" => "sealed"})
    assert Store.calls(c.store)[{:list, "jars"}] == 1
  end
end
