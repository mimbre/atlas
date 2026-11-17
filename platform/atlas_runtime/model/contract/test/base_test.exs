defmodule AtlasRuntimeModel.BaseTest do
  use ExUnit.Case, async: true

  alias AtlasRuntimeModel.Base, as: Contract
  alias AtlasRuntimeModel.Generator.{Header, Targets.Json}
  alias AtlasRuntimeModel.Test.Base.{BaseRoot, StoredBase}

  @t0 ~U[2026-11-17 09:00:00.000000Z]
  @t1 ~U[2026-11-18 10:30:00.000000Z]
  @t2 ~U[2026-12-19 11:00:00.000000Z]
  @client "tcp:flow"
  @base_id "flow.run-42:atlas"
  @digest "sha256:" <> String.duplicate("d", 64)
  @baseline "sha256:" <> String.duplicate("e", 64)

  defp live(fields \\ []) do
    StoredBase.new!(
      Keyword.merge(
        [
          key: Contract.key(@client, @base_id),
          client_id: @client,
          base_id: @base_id,
          state: :live,
          manifest_digest: @digest,
          baseline_id: @baseline,
          roots: [
            %{root: "atlas", files: 3, bytes: 1200},
            %{root: "other", files: 0, bytes: 0}
          ],
          files: 3,
          bytes: 1200,
          stored_at: @t0,
          put_at: @t1
        ],
        fields
      )
    )
  end

  # Retention (B12): the tombstone keeps who, which and the digest, and when it was pruned.
  defp tombstone(record \\ live()) do
    StoredBase.new!(%{
      key: record.key,
      client_id: record.client_id,
      base_id: record.base_id,
      state: :pruned,
      manifest_digest: record.manifest_digest,
      pruned_at: @t2
    })
  end

  defp round_trip(record),
    do: record |> StoredBase.encode() |> JSON.encode!() |> JSON.decode!() |> StoredBase.decode()

  # What the store does on a read: decode, then the state rule.
  defp read(map) do
    with {:ok, record} <- StoredBase.decode(map), :ok <- Contract.check(record), do: {:ok, record}
  end

  describe "schema" do
    test "one record, stored_base, in bases/{key}.json at format version 1" do
      schema = Contract.__schema__()
      assert schema.version == "0.1.0"
      assert Enum.map(schema.entities, & &1.name) == [:base_root, :stored_base]
      records = for %{persistence: %{}} = e <- schema.entities, do: e
      assert [%{name: :stored_base, persistence: persistence, fields: fields}] = records

      assert persistence == %{form: :json_file, path: "bases/{key}.json", format_version: 1}

      assert Enum.map(fields, &{&1.name, &1.type, &1.required}) == [
               {:key, :string, true},
               {:client_id, :string, true},
               {:base_id, :string, true},
               {:state, {:enum, [:live, :pruned]}, true},
               {:manifest_digest, :string, true},
               {:baseline_id, :string, false},
               {:roots, {:list, :base_root}, false},
               {:files, :integer, false},
               {:bytes, :integer, false},
               {:stored_at, :datetime, false},
               {:put_at, :datetime, false},
               {:pruned_at, :datetime, false}
             ]

      assert Contract.live_fields() == [:baseline_id, :roots, :files, :bytes, :stored_at, :put_at]
      assert Contract.pruned_fields() == [:pruned_at]
    end

    test "a root has exactly root, files and bytes" do
      [root | _] = Contract.__schema__().entities

      assert Enum.map(root.fields, &{&1.name, &1.type, &1.required}) == [
               {:root, :string, true},
               {:files, :integer, true},
               {:bytes, :integer, true}
             ]
    end

    test "the model target has the contract's __schema__/0" do
      alias AtlasRuntimeModel.Test.Base, as: Target
      assert Target.__schema__() == Contract.__schema__()
      assert Enum.map(Target.records(), &elem(&1, 0)) == [:stored_base]
    end

    test "targets/json/base.json is what the contract generates (golden)" do
      schema = Contract.__schema__()
      [{"base.json", body}] = Json.files(:base, schema)
      root = Path.expand("../../../..", File.cwd!())
      source = List.to_string(Contract.module_info(:compile)[:source])
      expected = Header.put(".json", Path.relative_to(source, root), body)
      assert File.read!("../targets/json/base.json") == expected
    end

    test "the generator writes base.json with the other model files" do
      assert Application.fetch_env!(:atlas_runtime_model_generator, :contracts)[:base] ==
               Contract
    end
  end

  describe "the key" do
    test "is the lowercase hex sha256 of client_id, a zero byte and base_id" do
      expected =
        :crypto.hash(:sha256, @client <> <<0>> <> @base_id) |> Base.encode16(case: :lower)

      assert Contract.key(@client, @base_id) == expected
      assert Contract.key(@client, @base_id) =~ ~r/\A[0-9a-f]{64}\z/
    end

    test "two clients' bases of the same id have different keys and files" do
      other = "local:someone"
      assert Contract.key(@client, @base_id) != Contract.key(other, @base_id)

      a = live()
      b = live(client_id: other, key: Contract.key(other, @base_id))
      assert :ok = Contract.check(b)
      assert StoredBase.path(a) != StoredBase.path(b)
    end

    test "the zero byte keeps (client, id) pairs apart that concatenate alike" do
      assert Contract.key("ab", "c") != Contract.key("a", "bc")
    end

    test "the path is bases/<key>.json and never holds the base id" do
      record = live()
      assert StoredBase.path(record) == "bases/" <> Contract.key(@client, @base_id) <> ".json"
      refute StoredBase.path(record) =~ @base_id
    end
  end

  describe "persistence" do
    test "a live base: new → encode → JSON → decode gives the same record, and it checks" do
      record = live()
      assert :ok = Contract.check(record)
      assert {:ok, ^record} = round_trip(record)

      assert [%BaseRoot{root: "atlas", files: 3}, %BaseRoot{root: "other", files: 0}] =
               record.roots

      encoded = StoredBase.encode(record)
      assert encoded["format_version"] == 1
      assert encoded["state"] == "live"
      assert encoded["put_at"] == "2026-11-18T10:30:00.000000Z"
      refute Map.has_key?(encoded, "pruned_at")
      assert {:ok, ^record} = read(encoded)
    end

    test "a tombstone keeps client_id, base_id and manifest_digest only, and round-trips" do
      record = tombstone()
      assert :ok = Contract.check(record)
      assert {:ok, ^record} = round_trip(record)

      assert StoredBase.encode(record) == %{
               "format_version" => 1,
               "key" => Contract.key(@client, @base_id),
               "client_id" => @client,
               "base_id" => @base_id,
               "state" => "pruned",
               "manifest_digest" => @digest,
               "pruned_at" => "2026-12-19T11:00:00.000000Z"
             }

      # Same file as the live base it replaces.
      assert StoredBase.path(record) == StoredBase.path(live())
    end
  end

  describe "refusals" do
    test "a pruned record with baseline_id, or with any live field, is an error" do
      encoded = StoredBase.encode(tombstone())

      assert {:error, {:invalid, "stored_base.baseline_id", _}} =
               read(Map.put(encoded, "baseline_id", @baseline))

      live = StoredBase.encode(live())

      for field <- Contract.live_fields(), name = Atom.to_string(field) do
        assert {:error, {:invalid, "stored_base." <> ^name, _}} =
                 read(Map.put(encoded, name, live[name]))
      end
    end

    test "a live record without baseline_id, or without any live field, is an error" do
      encoded = StoredBase.encode(live())

      assert {:error, {:missing_field, "stored_base.baseline_id"}} =
               read(Map.delete(encoded, "baseline_id"))

      for field <- Contract.live_fields(), name = Atom.to_string(field) do
        assert {:error, {:missing_field, "stored_base." <> ^name}} =
                 read(Map.delete(encoded, name))
      end
    end

    test "a live record with pruned_at, or a pruned one without it, is an error" do
      assert {:error, {:invalid, "stored_base.pruned_at", _}} =
               read(Map.put(StoredBase.encode(live()), "pruned_at", "2026-12-19T11:00:00Z"))

      assert {:error, {:missing_field, "stored_base.pruned_at"}} =
               read(Map.delete(StoredBase.encode(tombstone()), "pruned_at"))
    end

    test "a tombstone without manifest_digest, client_id or base_id is refused" do
      encoded = StoredBase.encode(tombstone())

      for field <- ["manifest_digest", "client_id", "base_id"] do
        assert {:error, {:missing_field, "stored_base." <> ^field}} =
                 StoredBase.decode(Map.delete(encoded, field))
      end

      assert_raise ArgumentError, ~r/missing_field/, fn ->
        StoredBase.new!(Map.delete(Map.from_struct(tombstone()), :manifest_digest))
      end
    end

    test "a record under another (client, id)'s key is an error" do
      record = live(key: Contract.key("local:someone", @base_id))
      assert {:error, {:invalid, "stored_base.key", _}} = Contract.check(record)
    end

    test "another format version, an unknown field or a wrong value is an error" do
      encoded = StoredBase.encode(live())

      assert {:error, {:format_version, 2}} =
               StoredBase.decode(%{encoded | "format_version" => 2})

      assert {:error, {:format_version, nil}} =
               StoredBase.decode(Map.delete(encoded, "format_version"))

      assert {:error, {:unknown_field, "stored_base.tree"}} =
               StoredBase.decode(Map.put(encoded, "tree", "x"))

      assert {:error, {:unknown_field, "stored_base.roots[0].sha256"}} =
               StoredBase.decode(put_in(encoded, ["roots", Access.at(0), "sha256"], "x"))

      assert {:error, {:invalid, "stored_base.state", _}} =
               StoredBase.decode(%{encoded | "state" => "deleted"})

      assert {:error, {:invalid, "stored_base.files", _}} =
               StoredBase.decode(%{encoded | "files" => "3"})
    end
  end
end
