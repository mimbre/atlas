defmodule AtlasRuntimeModel.WorkTest do
  use ExUnit.Case, async: true

  alias AtlasRuntimeModel.Generator.{Header, Targets.Json}
  alias AtlasRuntimeModel.Test.Work
  alias Work.{Attempt, Folder, KeyIndexEntry, Option, Provenance, Repository, WorkRecord}

  @t0 ~U[2026-11-16 09:00:00.000000Z]
  @t1 ~U[2026-11-16 09:00:05.250000Z]
  @t2 ~U[2026-11-16 09:42:10.000000Z]

  defp record do
    WorkRecord.new!(
      work_id: "w-1",
      client: "local:someone",
      client_key: "key-1",
      idempotency_key: "key-1",
      revision: 7,
      sequence: 42,
      request: %{
        title: "Fix it",
        instructions: "Do the thing.",
        profile: "deep_coding",
        cost_class: :standard,
        workspace: %{kind: :repository, url: "https://example.test/r.git", branch: "b"}
      },
      attempts: [
        %{
          attempt: 1,
          state: :cancelled,
          cancel_stage: :forced,
          cancel_reason: :superseded,
          timestamps: %{received_at: @t0, accepted_at: @t0, started_at: @t1, ended_at: @t1},
          slot: "s1",
          turn_id: "t-1",
          quiescent: true,
          turn_folder: "turns/t-1",
          provenance: %{
            executor_kind: :agent,
            provider: "p",
            harness: "h",
            runtime_build: "build",
            machine: "m",
            slot: "s1",
            configured_model: "model-a",
            reported_model: "model-a",
            selection: %{
              profile: "deep_coding",
              policy_version: 4,
              option: %{provider: "p", harness: "h", model: "model-a"},
              reason: "preferred",
              skipped: [
                %{option: %{provider: "p2", harness: "h2", model: "model-b"}, why: "quota"}
              ]
            },
            conversation_id: "c-1",
            turn_id: "t-1",
            started_at: @t1,
            ended_at: @t1
          },
          resume_point: %{
            turn_id: "t-1",
            conversation_id: "c-1",
            workspace: %{path: "/w", branch: "b", commit: "abc"}
          },
          result: %{
            kind: :cancelled,
            reason: "superseded",
            retryable: false,
            native_outcome: :killed,
            never_started: false,
            log: %{complete: false, missing_bytes: 12, ref: "t-1"}
          }
        },
        %{
          attempt: 2,
          state: :completed,
          timestamps: %{received_at: @t1, started_at: @t1, ended_at: @t2},
          quiescent: true,
          result: %{
            kind: :completed,
            retryable: false,
            never_started: false,
            answer: "Done.",
            work_product: %{
              workspace: %{path: "/w", branch: "b", base_sha: "a", head_sha: "b", changed: true}
            },
            log: %{complete: true, missing_bytes: 0}
          }
        }
      ]
    )
  end

  describe "schema" do
    test "S1 has exactly work_record and key_index_entry, persisted as JSON files" do
      schema = AtlasRuntimeModel.Work.__schema__()
      records = for %{persistence: %{}} = e <- schema.entities, do: e
      assert Enum.map(records, & &1.name) == [:work_record, :key_index_entry]
      [work, index] = records

      assert work.persistence == %{
               form: :json_file,
               path: "work/{work_id}.json",
               format_version: 1
             }

      assert index.persistence == %{form: :json_file, path: "work/index.json", format_version: 1}

      assert Enum.map(index.fields, &{&1.name, &1.required}) == [
               client: true,
               client_key: true,
               work_id: true,
               final_kind: false,
               pruned: true
             ]

      kinds = {:enum, [:completed, :failed, :crashed, :interrupted, :cancelled, :returned]}
      assert Enum.find(index.fields, &(&1.name == :final_kind)).type == kinds
    end

    # The model schema shape (design §1.7, D36), which the boundary's generator reads.
    test "__schema__/0 is the documented model schema shape" do
      schema = AtlasRuntimeModel.Work.__schema__()
      assert Enum.sort(Map.keys(schema)) == [:entities, :version]
      assert schema.version == "0.1.0"
      names = Enum.map(schema.entities, & &1.name)

      for entity <- schema.entities do
        assert Enum.sort(Map.keys(entity)) == [:fields, :name, :persistence]

        assert entity.persistence == nil or
                 Enum.sort(Map.keys(entity.persistence)) == [:form, :format_version, :path]

        for field <- entity.fields do
          assert Enum.sort(Map.keys(field)) == [:name, :required, :type]
          assert type?(field.type, names), "#{entity.name}.#{field.name}: #{inspect(field.type)}"
        end
      end

      request = Enum.find(schema.entities, &(&1.name == :request))

      assert %{type: {:enum, [:low, :standard, :high]}} =
               Enum.find(request.fields, &(&1.name == :cost_class))

      assert %{type: {:one_of, [:repository, :folder]}} =
               Enum.find(request.fields, &(&1.name == :workspace))
    end

    # The boundary's generator reads the model through the target module (§1.5(c), D36).
    test "the model target has the contract's __schema__/0" do
      assert Work.__schema__() == AtlasRuntimeModel.Work.__schema__()
      assert Enum.map(Work.records(), &elem(&1, 0)) == [:work_record, :key_index_entry]
    end

    test "a selection's option is the model {provider, harness, model}, held inside" do
      entities = Map.new(AtlasRuntimeModel.Work.__schema__().entities, &{&1.name, &1})
      option = entities.option
      assert option.persistence == nil

      assert Enum.map(option.fields, &{&1.name, &1.type, &1.required}) ==
               [{:provider, :string, true}, {:harness, :string, true}, {:model, :string, true}]

      for {entity, field} <- [selection: :option, skipped_option: :option] do
        assert %{type: :option, required: true} =
                 Enum.find(entities[entity].fields, &(&1.name == field))
      end
    end

    # The CI job greps the contract for boundary and backend names.
    test "the model depends on its own generator only (innermost layer)" do
      assert Mix.Project.config()[:deps] == [
               {:atlas_runtime_model_generator, path: "../generator"}
             ]
    end

    test "targets/json/work.json is what the contract generates (golden)" do
      schema = AtlasRuntimeModel.Work.__schema__()
      [{"work.json", body}] = Json.files(:work, schema)
      root = Path.expand("../../../..", File.cwd!())
      source = List.to_string(AtlasRuntimeModel.Work.module_info(:compile)[:source])
      expected = Header.put(".json", Path.relative_to(source, root), body)
      assert File.read!("../targets/json/work.json") == expected
    end
  end

  describe "persistence" do
    test "new → encode → JSON → decode gives the same record" do
      record = record()
      encoded = WorkRecord.encode(record)
      assert {:ok, ^record} = encoded |> JSON.encode!() |> JSON.decode!() |> WorkRecord.decode()
      assert WorkRecord.path(record) == "work/w-1.json"
      assert %Repository{base: nil} = record.request.workspace
      assert [%Attempt{provenance: %Provenance{}}, %Attempt{state: :completed}] = record.attempts
    end

    test "a selection's options are stored as objects and decoded as structs" do
      encoded = WorkRecord.encode(record())
      selection = hd(encoded["attempts"])["provenance"]["selection"]
      assert selection["option"] == %{"provider" => "p", "harness" => "h", "model" => "model-a"}

      assert [%{"option" => %{"provider" => "p2", "harness" => "h2", "model" => "model-b"}}] =
               selection["skipped"]

      {:ok, decoded} = WorkRecord.decode(encoded)
      selection = hd(decoded.attempts).provenance.selection
      assert %Option{provider: "p", harness: "h", model: "model-a"} = selection.option
      assert [%{option: %Option{model: "model-b"}}] = selection.skipped
    end

    test "the persisted form: string keys, format_version, enums as strings, one_of by kind" do
      encoded = WorkRecord.encode(record())
      assert encoded["format_version"] == 1
      assert encoded["request"]["workspace"]["kind"] == "repository"
      assert encoded["request"]["cost_class"] == "standard"
      [first, second] = encoded["attempts"]
      assert first["cancel_reason"] == "superseded"
      assert first["timestamps"]["started_at"] == "2026-11-16T09:00:05.250000Z"
      refute Map.has_key?(second, "cancel_stage")
      refute Map.has_key?(encoded, "state")
    end

    # A released slot (§13.1 Q8): who and when stay on the private attempt.
    test "an attempt with released_by and released_at round-trips" do
      [first, second] = record().attempts
      released = %{second | released_by: "local:op", released_at: @t2}
      record = WorkRecord.new!(%{record() | attempts: [first, released]})
      encoded = WorkRecord.encode(record)

      assert %{"released_by" => "local:op", "released_at" => "2026-11-16T09:42:10.000000Z"} =
               List.last(encoded["attempts"])

      assert {:ok, ^record} = encoded |> JSON.encode!() |> JSON.decode!() |> WorkRecord.decode()
    end

    # P15: an absent optional field is left out, so a record without a release is written
    # as before and a file from before decodes; format_version stays 1.
    test "an attempt without the release fields is written and read as before" do
      encoded = WorkRecord.encode(record())
      assert encoded["format_version"] == 1

      for attempt <- encoded["attempts"] do
        refute Map.has_key?(attempt, "released_by")
        refute Map.has_key?(attempt, "released_at")
      end

      assert {:ok, decoded} = WorkRecord.decode(encoded)
      assert Enum.all?(decoded.attempts, &(&1.released_by == nil and &1.released_at == nil))
      assert decoded == record()
    end

    test "a folder workspace round-trips as the other variant" do
      folder = %Folder{path: "/f", permissions: :materialized_folder}
      record = %{record() | request: %{record().request | workspace: folder}}
      encoded = WorkRecord.encode(record)

      assert encoded["request"]["workspace"] == %{
               "kind" => "folder",
               "path" => "/f",
               "permissions" => "materialized_folder"
             }

      assert {:ok, ^record} = WorkRecord.decode(encoded)
    end

    test "the key index: one file, tombstones kept" do
      entries = [
        KeyIndexEntry.new!(client: "c", client_key: "k1", work_id: "w-1", pruned: false),
        KeyIndexEntry.new!(
          client: "c",
          client_key: "k0",
          work_id: "w-0",
          final_kind: :completed,
          pruned: true
        )
      ]

      file = KeyIndexEntry.encode_file(entries)
      assert KeyIndexEntry.path() == "work/index.json"
      assert %{"format_version" => 1, "entries" => [_, %{"final_kind" => "completed"}]} = file

      assert {:ok, ^entries} =
               file |> JSON.encode!() |> JSON.decode!() |> KeyIndexEntry.decode_file()
    end

    test "a datetime in another zone is stored in UTC and the record round-trips" do
      plus_two = %DateTime{
        year: 2026,
        month: 11,
        day: 16,
        hour: 11,
        minute: 0,
        second: 0,
        microsecond: {0, 6},
        utc_offset: 7200,
        std_offset: 0,
        zone_abbr: "+02",
        time_zone: "Etc/GMT-2"
      }

      [attempt | rest] = record().attempts
      changed = %{record() | attempts: [put_in(attempt.timestamps.received_at, plus_two) | rest]}
      {:ok, record} = WorkRecord.new(changed)
      assert hd(record.attempts).timestamps.received_at == @t0

      assert {:ok, ^record} =
               record
               |> WorkRecord.encode()
               |> JSON.encode!()
               |> JSON.decode!()
               |> WorkRecord.decode()
    end

    # Rules across entries are the store's (moduledoc of AtlasRuntimeModel.Work); the
    # collection codec checks each entry and the file, not those rules.
    test "the index has no single-entry encode/decode: entries live in the one file" do
      # function_exported?/3 is false for a module not loaded yet, whatever ran first.
      Code.ensure_loaded!(KeyIndexEntry)
      refute function_exported?(KeyIndexEntry, :encode, 1)
      refute function_exported?(KeyIndexEntry, :decode, 1)
      assert function_exported?(KeyIndexEntry, :encode_file, 1)
    end
  end

  describe "refusals" do
    test "another or no format version is an error, never a silent migration" do
      encoded = WorkRecord.encode(record())

      assert {:error, {:format_version, 2}} =
               WorkRecord.decode(%{encoded | "format_version" => 2})

      assert {:error, {:format_version, 0}} =
               WorkRecord.decode(%{encoded | "format_version" => 0})

      assert {:error, {:format_version, nil}} =
               WorkRecord.decode(Map.delete(encoded, "format_version"))

      index = KeyIndexEntry.encode_file([])

      assert {:error, {:format_version, 2}} =
               KeyIndexEntry.decode_file(%{index | "format_version" => 2})
    end

    test "an unknown field anywhere is an error" do
      encoded = WorkRecord.encode(record())

      assert {:error, {:unknown_field, "work_record.state"}} =
               WorkRecord.decode(Map.put(encoded, "state", "completed"))

      [first, second] = encoded["attempts"]

      assert {:error, {:unknown_field, "work_record.attempts[1].result.artifacts"}} =
               WorkRecord.decode(%{
                 encoded
                 | "attempts" => [first, put_in(second, ["result", "artifacts"], [])]
               })

      assert {:error, {:unknown_field, "key_index_entry[0].note"}} =
               KeyIndexEntry.decode_file(%{
                 "format_version" => 1,
                 "entries" => [
                   %{
                     "client" => "c",
                     "client_key" => "k",
                     "work_id" => "w",
                     "pruned" => false,
                     "note" => 1
                   }
                 ]
               })
    end

    test "a missing field or a wrong value is an error" do
      encoded = WorkRecord.encode(record())

      assert {:error, {:missing_field, "work_record.request"}} =
               WorkRecord.decode(Map.delete(encoded, "request"))

      [first, second] = encoded["attempts"]

      assert {:error, {:invalid, "work_record.attempts[1].state", _}} =
               WorkRecord.decode(%{
                 encoded
                 | "attempts" => [first, %{second | "state" => "lost"}]
               })

      assert {:error, {:invalid, "work_record.request.workspace.kind", _}} =
               WorkRecord.decode(put_in(encoded, ["request", "workspace", "kind"], "packet"))

      assert {:error, {:invalid, "work_record.revision", "an integer"}} =
               WorkRecord.decode(%{encoded | "revision" => "7"})

      assert {:error, {:missing_field, "work_record.attempts[0].quiescent"}} =
               WorkRecord.new(%{
                 Map.from_struct(record())
                 | attempts: [Map.delete(Map.from_struct(hd(record().attempts)), :quiescent)]
               })
    end

    test "an option that is a string, or lacks a part, is refused" do
      encoded = WorkRecord.encode(record())
      at = ["attempts", Access.at(0), "provenance", "selection"]
      path = "work_record.attempts[0].provenance.selection"

      assert {:error, {:invalid, ^path <> ".option", "an object"}} =
               WorkRecord.decode(put_in(encoded, at ++ ["option"], "o1"))

      assert {:error, {:missing_field, ^path <> ".option.model"}} =
               WorkRecord.decode(update_in(encoded, at ++ ["option"], &Map.delete(&1, "model")))

      assert {:error, {:unknown_field, ^path <> ".skipped[0].option.slot"}} =
               WorkRecord.decode(
                 update_in(
                   encoded,
                   at ++ ["skipped", Access.at(0), "option"],
                   &Map.put(&1, "slot", "s")
                 )
               )

      assert {:error, {:invalid, _, _}} =
               WorkRecord.new(
                 put_in(Map.from_struct(record()), [:attempts], [
                   put_in(hd(record().attempts).provenance.selection.option, "o1")
                 ])
               )
    end

    test "a work id that is no file name has no path" do
      assert_raise ArgumentError, ~r/no file name/, fn -> WorkRecord.path(%{work_id: "../x"}) end
    end
  end

  defp type?(t, _names) when t in [:string, :integer, :boolean, :datetime], do: true
  defp type?({:enum, values}, _names), do: values != [] and Enum.all?(values, &is_atom/1)
  defp type?({:one_of, variants}, names), do: Enum.all?(variants, &(&1 in names))
  defp type?({:list, inner}, names), do: type?(inner, names)
  defp type?(t, names), do: t in names
end
