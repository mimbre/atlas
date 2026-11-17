defmodule AtlasRuntimeModel.WorkTest do
  use ExUnit.Case, async: true

  alias AtlasRuntimeModel.Generator.{Header, Targets.Json}
  alias AtlasRuntimeModel.Test.Work
  alias Work.{Attempt, Folder, KeyIndexEntry, Option, Provenance, Repository, WorkRecord}
  alias Work.{Base, CheckResult, FromWork, Source}

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

      assert %{type: {:one_of, [:repository, :folder, :base, :from_work]}} =
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

    # S5a (I-M5): the new entities and fields, with their types and whether required.
    test "the S5a additions have exactly the planned shape" do
      entities = Map.new(AtlasRuntimeModel.Work.__schema__().entities, &{&1.name, &1})
      shape = fn name -> Enum.map(entities[name].fields, &{&1.name, &1.type, &1.required}) end
      access = {:enum, [:read_only, :workspace_write]}
      fingerprints = {:list, :root_fingerprint}
      # helper_failed: I-H3 amendment (c), 2026-11-17 (s5a P10a).
      errors = {:enum, [:sandbox_unavailable, :leaves_folder, :not_found, :helper_failed]}

      assert shape.(:base) == [{:base_id, :string, true}, {:permissions, access, true}]

      assert shape.(:from_work) == [
               {:work_id, :string, true},
               {:attempt, :integer, false},
               {:permissions, access, true}
             ]

      assert shape.(:after_check) == [
               {:command, {:list, :string}, true},
               {:timeout, :integer, false}
             ]

      assert shape.(:root_fingerprint) == [{:root, :string, true}, {:fingerprint, :string, true}]
      assert shape.(:frozen_ref) == [{:base, :string, true}, {:fingerprints, fingerprints, true}]

      assert shape.(:based_on) == [
               {:work_id, :string, true},
               {:attempt, :integer, true},
               {:fingerprints, fingerprints, true}
             ]

      assert shape.(:check_output) == [{:tail, :string, true}, {:complete, :boolean, true}]

      assert shape.(:check_result) == [
               {:command, {:list, :string}, true},
               {:exit_status, :integer, false},
               {:signal, :string, false},
               {:error, errors, false},
               {:timed_out, :boolean, true},
               {:cancelled, :boolean, true},
               {:interrupted, :boolean, true},
               {:duration_ms, :integer, true},
               {:output, :check_output, true}
             ]

      assert shape.(:source) == [{:work_id, :string, true}, {:attempt, :integer, true}]
      assert {:after_check, :after_check, false} in shape.(:request)

      assert Enum.take(shape.(:timestamps), -2) == [
               {:check_started_at, :datetime, false},
               {:check_ended_at, :datetime, false}
             ]

      assert Enum.take(shape.(:work_product), -3) == [
               {:frozen, :frozen_ref, false},
               {:based_on, :based_on, false},
               {:check, :check_result, false}
             ]

      assert Enum.take(shape.(:attempt), -5) == [
               {:checking, :boolean, false},
               {:check_pgid, :integer, false},
               {:folder, :string, false},
               {:preparing, :boolean, false},
               {:prepare_pid, :integer, false}
             ]

      assert Enum.take(shape.(:work_record), -3) == [
               {:source, :source, false},
               {:base_owner, :string, false},
               {:baseline_id, :string, false}
             ]

      # r2's folder.base_id is not added (r3, G1).
      assert Enum.map(entities.folder.fields, & &1.name) == [:path, :permissions]
      assert entities.work_record.persistence.format_version == 1
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

  describe "S5a additions (I-M5)" do
    @fixture Path.expand("support/fixtures/work.pre_s5a.json", __DIR__)
    @s5a_attempt ~w(checking check_pgid folder preparing prepare_pid)
    @s5a_timestamps ~w(check_started_at check_ended_at)
    @s5a_product ~w(frozen based_on check)

    defp round_trip(record),
      do: record |> WorkRecord.encode() |> JSON.encode!() |> JSON.decode!() |> WorkRecord.decode()

    defp with_workspace(workspace),
      do: WorkRecord.new!(%{record() | request: %{record().request | workspace: workspace}})

    defp check(fields) do
      Map.merge(
        %{
          command: ["mix", "test"],
          exit_status: 0,
          timed_out: false,
          cancelled: false,
          interrupted: false,
          duration_ms: 1500,
          output: %{tail: "ok\n", complete: true}
        },
        Map.new(fields)
      )
    end

    defp fingerprints, do: [%{root: "atlas", fingerprint: "csf_" <> String.duplicate("a", 64)}]

    # Every new optional field set, on a base work (a work's workspace is one form).
    defp full do
      [first, second] = record().attempts

      second = %{
        Map.from_struct(second)
        | timestamps: %{
            Map.from_struct(second.timestamps)
            | check_started_at: @t1,
              check_ended_at: @t2
          },
          checking: false,
          check_pgid: 4242,
          folder: "/home/workers/work-work-0123456789abcdef",
          preparing: false,
          prepare_pid: 4241,
          result: %{
            Map.from_struct(second.result)
            | work_product: %{
                workspace: %{path: "/w", changed: true},
                frozen: %{
                  base: "sha256:" <> String.duplicate("b", 64),
                  fingerprints: fingerprints()
                },
                based_on: %{
                  work_id: "work-fedcba9876543210",
                  attempt: 3,
                  fingerprints: fingerprints()
                },
                check: check(signal: "SIGINT", exit_status: nil, cancelled: true)
              }
          }
      }

      WorkRecord.new!(%{
        Map.from_struct(record())
        | request: %{
            Map.from_struct(record().request)
            | workspace: %{
                kind: :base,
                base_id: "sha256:" <> String.duplicate("b", 64),
                permissions: :workspace_write
              },
              after_check: %{command: ["mix", "test"], timeout: 120}
          },
          attempts: [first, second],
          source: %{work_id: "work-fedcba9876543210", attempt: 3}
      })
    end

    test "a record with every new optional field set round-trips" do
      record = full()
      assert {:ok, ^record} = round_trip(record)
      encoded = WorkRecord.encode(record)
      assert encoded["format_version"] == 1
      assert encoded["source"] == %{"work_id" => "work-fedcba9876543210", "attempt" => 3}

      assert encoded["request"]["after_check"] == %{
               "command" => ["mix", "test"],
               "timeout" => 120
             }

      last = List.last(encoded["attempts"])
      assert Map.take(last, @s5a_attempt) |> Map.keys() |> Enum.sort() == Enum.sort(@s5a_attempt)
      assert last["checking"] == false and last["preparing"] == false
      assert last["timestamps"]["check_ended_at"] == "2026-11-16T09:42:10.000000Z"
      product = last["result"]["work_product"]

      assert product["frozen"]["fingerprints"] == [
               %{"root" => "atlas", "fingerprint" => "csf_" <> String.duplicate("a", 64)}
             ]

      assert product["based_on"]["attempt"] == 3

      assert %{"signal" => "SIGINT", "cancelled" => true, "output" => %{"complete" => true}} =
               product["check"]

      refute Map.has_key?(product["check"], "exit_status")
      refute Map.has_key?(product["check"], "error")
    end

    # format_version stays 1 (P3's finding): an absent optional field is left out, so a
    # record without any S5a field is written exactly as before S5a.
    test "a record with none of the new fields is written as before (format_version 1)" do
      encoded = WorkRecord.encode(record())
      assert encoded["format_version"] == 1
      refute Map.has_key?(encoded, "source")
      refute Map.has_key?(encoded["request"], "after_check")

      for attempt <- encoded["attempts"] do
        assert Map.take(attempt, @s5a_attempt) == %{}
        assert Map.take(attempt["timestamps"], @s5a_timestamps) == %{}
        assert Map.take(get_in(attempt, ["result", "work_product"]) || %{}, @s5a_product) == %{}
      end

      assert {:ok, decoded} = round_trip(record())
      assert decoded == record() and decoded.source == nil
      assert Enum.all?(decoded.attempts, &(&1.checking == nil and &1.preparing == nil))
    end

    test "a pre-S5a work file (develop's encode) decodes, and is written back unchanged" do
      file = @fixture |> File.read!() |> JSON.decode!()
      assert file["format_version"] == 1
      assert {:ok, %WorkRecord{source: nil} = record} = WorkRecord.decode(file)
      assert %Folder{path: "/f", permissions: :materialized_folder} = record.request.workspace
      assert record.request.after_check == nil

      for attempt <- record.attempts do
        assert {attempt.checking, attempt.check_pgid, attempt.folder} == {nil, nil, nil}
        assert {attempt.preparing, attempt.prepare_pid} == {nil, nil}

        assert {attempt.timestamps.check_started_at, attempt.timestamps.check_ended_at} ==
                 {nil, nil}
      end

      assert %{frozen: nil, based_on: nil, check: nil} =
               List.last(record.attempts).result.work_product

      assert WorkRecord.encode(record) == file
    end

    test "a base request round-trips, stored with kind base" do
      record =
        with_workspace(%Base{
          base_id: "sha256:" <> String.duplicate("c", 64),
          permissions: :read_only
        })

      assert {:ok, ^record} = round_trip(record)

      assert WorkRecord.encode(record)["request"]["workspace"] == %{
               "kind" => "base",
               "base_id" => "sha256:" <> String.duplicate("c", 64),
               "permissions" => "read_only"
             }
    end

    test "a from_work request round-trips, with its attempt and with it absent" do
      for attempt <- [2, nil] do
        workspace = %{
          kind: :from_work,
          work_id: "work-fedcba9876543210",
          attempt: attempt,
          permissions: :workspace_write
        }

        record = with_workspace(workspace)
        assert %FromWork{attempt: ^attempt} = record.request.workspace
        assert {:ok, ^record} = round_trip(record)
        encoded = WorkRecord.encode(record)["request"]["workspace"]
        assert encoded["kind"] == "from_work"
        assert Map.has_key?(encoded, "attempt") == (attempt != nil)
      end
    end

    test "a check without error round-trips, and one that did not run carries its error" do
      [first, second] = record().attempts

      for {fields, error} <- [
            {[], nil},
            {[
               exit_status: nil,
               duration_ms: 0,
               output: %{tail: "", complete: true},
               error: :sandbox_unavailable
             ], :sandbox_unavailable},
            {[
               exit_status: nil,
               duration_ms: 0,
               output: %{tail: "", complete: true},
               error: :leaves_folder
             ], :leaves_folder},
            {[
               exit_status: nil,
               duration_ms: 0,
               output: %{tail: "", complete: true},
               error: :not_found
             ], :not_found},
            {[
               exit_status: nil,
               duration_ms: 0,
               output: %{tail: "", complete: true},
               error: :helper_failed
             ], :helper_failed}
          ] do
        product = %{workspace: %{path: "/w", changed: false}, check: check(fields)}

        second =
          put_in(Map.from_struct(second), [:result], %{
            Map.from_struct(second.result)
            | work_product: product
          })

        record = WorkRecord.new!(%{record() | attempts: [first, second]})
        assert %CheckResult{error: ^error} = List.last(record.attempts).result.work_product.check
        assert {:ok, ^record} = round_trip(record)
      end
    end

    test "the private additions hold what the core keeps: source, checking, folder, preparer" do
      record = full()
      assert %Source{work_id: "work-fedcba9876543210", attempt: 3} = record.source

      assert %Attempt{checking: false, check_pgid: 4242, preparing: false, prepare_pid: 4241} =
               List.last(record.attempts)

      [first, second] = record.attempts
      preparing = %{second | checking: nil, preparing: true, result: nil, state: :starting}
      checking = %{second | checking: true, preparing: nil, result: nil, state: :running}

      for attempt <- [preparing, checking] do
        changed = WorkRecord.new!(%{record | attempts: [first, attempt]})
        assert {:ok, ^changed} = round_trip(changed)
      end
    end

    test "new values outside their enum, or a check without its booleans, are refused" do
      encoded = WorkRecord.encode(full())
      ws = ["request", "workspace"]

      assert {:error, {:invalid, "work_record.request.workspace.permissions", _}} =
               WorkRecord.decode(put_in(encoded, ws ++ ["permissions"], "materialized_folder"))

      assert {:error, {:missing_field, "work_record.request.workspace.base_id"}} =
               WorkRecord.decode(update_in(encoded, ws, &Map.delete(&1, "base_id")))

      at = ["attempts", Access.at(1), "result", "work_product", "check"]
      path = "work_record.attempts[1].result.work_product.check"

      assert {:error, {:invalid, ^path <> ".error", _}} =
               WorkRecord.decode(put_in(encoded, at ++ ["error"], "crashed"))

      assert {:error, {:missing_field, ^path <> ".timed_out"}} =
               WorkRecord.decode(update_in(encoded, at, &Map.delete(&1, "timed_out")))

      assert {:error, {:missing_field, "work_record.source.attempt"}} =
               WorkRecord.decode(update_in(encoded, ["source"], &Map.delete(&1, "attempt")))
    end
  end

  # S5c P3 (B10, B11): the private base references, optional so S5a-era records decode.
  describe "S5c additions" do
    @s5a_fixture Path.expand("support/fixtures/work.s5a.json", __DIR__)
    @baseline "sha256:" <> String.duplicate("e", 64)

    defp base_record(fields) do
      base = %{kind: :base, base_id: "flow.run-42:atlas", permissions: :workspace_write}

      WorkRecord.new!(
        Map.merge(%{record() | request: %{record().request | workspace: base}}, fields)
      )
    end

    test "a base work with base_owner and baseline_id round-trips, stored at the top level" do
      record = base_record(%{base_owner: "tcp:flow", baseline_id: @baseline})
      encoded = WorkRecord.encode(record)
      assert encoded["format_version"] == 1
      assert {encoded["base_owner"], encoded["baseline_id"]} == {"tcp:flow", @baseline}
      assert {:ok, ^record} = encoded |> JSON.encode!() |> JSON.decode!() |> WorkRecord.decode()
    end

    test "without them a record is written as before" do
      encoded = WorkRecord.encode(record())
      refute Map.has_key?(encoded, "base_owner") or Map.has_key?(encoded, "baseline_id")
    end

    test "an S5a-era work file (a base work, S5a's encode) decodes, and is written back unchanged" do
      file = @s5a_fixture |> File.read!() |> JSON.decode!()
      assert file["format_version"] == 1
      assert %{"kind" => "base"} = file["request"]["workspace"]

      assert {:ok, %WorkRecord{base_owner: nil, baseline_id: nil} = record} =
               WorkRecord.decode(file)

      assert %Base{permissions: :workspace_write} = record.request.workspace
      assert %Source{attempt: 3} = record.source
      assert WorkRecord.encode(record) == file
    end

    test "a pre-S5a work file decodes without them too" do
      file = @fixture |> File.read!() |> JSON.decode!()
      assert {:ok, %WorkRecord{base_owner: nil, baseline_id: nil}} = WorkRecord.decode(file)
    end

    test "a base reference of the wrong type is refused" do
      encoded = WorkRecord.encode(base_record(%{base_owner: "tcp:flow", baseline_id: @baseline}))

      assert {:error, {:invalid, "work_record.baseline_id", _}} =
               WorkRecord.decode(%{encoded | "baseline_id" => 1})

      assert {:error, {:invalid, "work_record.base_owner", _}} =
               WorkRecord.decode(%{encoded | "base_owner" => %{"client" => "x"}})
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
