defmodule AtlasRuntimeModel.Test.LocalSource do
  @moduledoc false
  # The compile-time target over the local work source's model, as
  # AtlasRuntime.Model.LocalSource uses it.
  use AtlasRuntimeModel.Generator.Targets.Model, contract: AtlasRuntimeModel.LocalSource
end

defmodule AtlasRuntimeModel.LocalSourceTest do
  use ExUnit.Case, async: true

  alias AtlasRuntimeModel.Generator.{Header, Targets.Json}
  alias AtlasRuntimeModel.Test.LocalSource, as: Target
  alias AtlasRuntimeModel.Test.LocalSource.{QueueKeyEntry, QueuedWork}

  @t0 ~U[2026-11-17 09:00:00.000000Z]

  defp request(workspace \\ %{kind: :folder, path: "/w", permissions: :workspace_write}) do
    %{
      title: "t",
      instructions: "i",
      profile: "p",
      cost_class: :standard,
      workspace: workspace,
      after_check: %{command: ["true"]}
    }
  end

  defp queued(fields \\ []) do
    QueuedWork.new!(
      Keyword.merge(
        [
          work_id: "work-0123456789abcdef",
          client: "local",
          client_key: "k1",
          request: request(),
          priority: 1,
          added_at: @t0,
          position: 1,
          state: :queued
        ],
        fields
      )
    )
  end

  defp round_trip(module, record),
    do: record |> module.encode() |> JSON.encode!() |> JSON.decode!() |> module.decode()

  defp shape(name) do
    entity = Enum.find(AtlasRuntimeModel.LocalSource.__schema__().entities, &(&1.name == name))
    Enum.map(entity.fields, &{&1.name, &1.type, &1.required})
  end

  describe "schema" do
    test "two records under local-source/, each at format version 1" do
      schema = AtlasRuntimeModel.LocalSource.__schema__()
      records = for %{persistence: %{} = p} = e <- schema.entities, do: {e.name, p}

      assert records == [
               queued_work: %{
                 form: :json_file,
                 path: "local-source/queue/{work_id}.json",
                 format_version: 1
               },
               queue_key_entry: %{
                 form: :json_file,
                 path: "local-source/index.json",
                 format_version: 1
               }
             ]
    end

    test "a queued work has the planned fields" do
      states = {:enum, [:queued, :leased, :ended]}

      assert shape(:queued_work) == [
               {:work_id, :string, true},
               {:client, :string, true},
               {:client_key, :string, false},
               {:request, :request, true},
               {:priority, :integer, true},
               {:added_at, :datetime, true},
               {:position, :integer, true},
               {:state, states, true},
               {:lease_id, :string, false},
               {:result, :result_ref, false}
             ]
    end

    test "a key entry keeps a tombstone: final kind and pruned" do
      kinds = {:enum, [:completed, :failed, :crashed, :interrupted, :cancelled, :returned]}

      assert shape(:queue_key_entry) == [
               {:client, :string, true},
               {:client_key, :string, true},
               {:work_id, :string, true},
               {:final_kind, kinds, false},
               {:pruned, :boolean, true}
             ]

      assert {:kind, kinds, true} in shape(:result_ref)
    end

    test "the request has the work contract's request fields" do
      work = AtlasRuntimeModel.Work.__schema__().entities
      work_request = Enum.find(work, &(&1.name == :request)).fields
      assert shape(:request) == Enum.map(work_request, &{&1.name, &1.type, &1.required})
    end

    test "the model target has the contract's __schema__/0" do
      assert Target.__schema__() == AtlasRuntimeModel.LocalSource.__schema__()
      assert Enum.map(Target.records(), &elem(&1, 0)) == [:queued_work, :queue_key_entry]
    end

    test "targets/json/local_source.json is what the contract generates (golden)" do
      schema = AtlasRuntimeModel.LocalSource.__schema__()
      [{"local_source.json", body}] = Json.files(:local_source, schema)
      root = Path.expand("../../../..", File.cwd!())
      source = List.to_string(AtlasRuntimeModel.LocalSource.module_info(:compile)[:source])
      expected = Header.put(".json", Path.relative_to(source, root), body)
      assert File.read!("../targets/json/local_source.json") == expected
    end
  end

  describe "persistence" do
    test "new → encode → JSON → decode gives the same queued work, in every state" do
      ended =
        queued(
          state: :ended,
          lease_id: "lease-1",
          result: %{
            kind: :completed,
            attempt: 1,
            frozen_id: "work-0123456789abcdef.1",
            ended_at: @t0
          }
        )

      for record <- [
            queued(),
            queued(state: :leased, lease_id: "lease-1"),
            ended,
            queued(
              client_key: nil,
              request: request(%{kind: :base, base_id: "b", permissions: :read_only})
            )
          ] do
        assert round_trip(QueuedWork, record) == {:ok, record}
      end
    end

    test "its path is local-source/queue/<work_id>.json" do
      assert QueuedWork.path(queued()) == "local-source/queue/work-0123456789abcdef.json"
      assert QueueKeyEntry.path() == "local-source/index.json"
    end

    test "the index file round-trips live entries and tombstones" do
      entries = [
        QueueKeyEntry.new!(client: "local", client_key: "a", work_id: "w1", pruned: false),
        QueueKeyEntry.new!(
          client: "local",
          client_key: "b",
          work_id: "w2",
          final_kind: :failed,
          pruned: true
        )
      ]

      decoded =
        entries
        |> QueueKeyEntry.encode_file()
        |> JSON.encode!()
        |> JSON.decode!()
        |> QueueKeyEntry.decode_file()

      assert decoded == {:ok, entries}
    end
  end

  describe "refusals" do
    test "another format version, an unknown field or a wrong value is an error" do
      map = queued() |> QueuedWork.encode() |> JSON.encode!() |> JSON.decode!()
      assert {:error, _} = QueuedWork.decode(Map.put(map, "format_version", 2))
      assert {:error, _} = QueuedWork.decode(Map.put(map, "extra", 1))
      assert {:error, _} = QueuedWork.decode(Map.put(map, "state", "running"))
      assert {:error, _} = QueuedWork.decode(Map.put(map, "priority", "high"))
      assert {:error, _} = QueuedWork.decode(Map.delete(map, "position"))
    end

    test "a key entry without pruned is refused" do
      assert {:error, _} = QueueKeyEntry.new(client: "local", client_key: "a", work_id: "w1")
    end
  end
end
