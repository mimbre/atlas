defmodule AtlasFacts.DeciderAuthorityTest do
  use ExUnit.Case, async: false
  alias AtlasBus.{Envelope, SubjectFingerprint}
  alias AtlasFacts.CountingRela, as: Store
  @moduletag :tmp_dir

  @fingerprint %{"fields" => ["phase"], "relations" => []}

  defmodule Decided do
    @moduledoc """
    The counting kinds, where a clerk seals a bead, or a stamp under a fresh verdict of
    the allocate gate (a jar about the bead).
    """
    use AtlasFacts.TestModel,
      description:
        AtlasFacts.CountingRela.schema()
        |> put_in(["entities", "bead", "authority"], %{
          "when" => %{"status" => ["sealed"]},
          "writes" => %{"status" => ["sealed"]},
          "by" => "ruled_by",
          "kind" => "clerk",
          "agent_kind" => "stamp",
          "decider" => %{
            "gate" => "allocate",
            "kind" => "jar",
            "relation" => "about",
            "fingerprint" => %{"fields" => ["phase"], "relations" => []}
          }
        })
        |> put_in(["relations", "ruled_by"], %{"from" => ["bead"], "to" => ["clerk", "stamp"]})
        |> put_in(["relations", "about"], %{"from" => ["jar"], "to" => ["bead"]})
        |> update_in(["entities", "jar", "properties"], fn props ->
          Map.merge(
            props,
            Map.new(
              ~w(gate subject purpose verdict fingerprint decided_at),
              &{&1, %{"type" => "string"}}
            )
          )
        end)
  end

  setup %{tmp_dir: dir} do
    fingerprint = @fingerprint
    {:ok, store} = Store.start_link(0, schema: Decided.rela_schema())
    Application.put_env(:atlas_bus, :store, "store-#{System.unique_integer([:positive])}")

    start_supervised!(
      {AtlasFacts.Server,
       rela: {Store, store}, model: Decided, data_dir: dir, collection_freshness_ms: 60_000}
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
