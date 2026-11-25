defmodule AtlasRuntimeModel.FrozenResultTest do
  use ExUnit.Case, async: true

  alias AtlasRuntimeModel.Test.FrozenResult.{ChangeEntry, FrozenResult, FrozenRoot}

  @t0 ~U[2026-11-17 09:00:00.000000Z]
  @base "sha256:" <> String.duplicate("b", 64)
  @sha String.duplicate("a", 64)

  defp fingerprint(c), do: "csf_" <> String.duplicate(c, 64)

  defp frozen(fields \\ []) do
    FrozenResult.new!(
      Keyword.merge(
        [
          frozen_id: "work-0123456789abcdef.2",
          work_id: "work-0123456789abcdef",
          attempt: 2,
          base: @base,
          frozen_at: @t0,
          pruned: false,
          roots: [
            %{
              root: "atlas",
              fingerprint: fingerprint("1"),
              entries: [
                %{
                  path: "a b/é.txt",
                  op: :write,
                  kind: :file,
                  mode: "100644",
                  size: 12,
                  sha256: @sha
                },
                %{
                  path: "bin/run",
                  op: :write,
                  kind: :file,
                  mode: "100755",
                  size: 0,
                  sha256: @sha
                },
                %{
                  path: "link",
                  op: :write,
                  kind: :symlink,
                  mode: "120000",
                  size: 6,
                  sha256: @sha,
                  target: "a b/é.txt"
                },
                %{path: "gone.md", op: :delete}
              ]
            },
            # A root with no change is listed, with no entries (B11).
            %{root: "other", fingerprint: fingerprint("2"), entries: []}
          ]
        ],
        fields
      )
    )
  end

  defp round_trip(record),
    do:
      record |> FrozenResult.encode() |> JSON.encode!() |> JSON.decode!() |> FrozenResult.decode()

  # Retention (B12): a pruned result keeps each root and its fingerprint, not its entries.
  defp tombstone(record) do
    roots = for root <- record.roots, do: %{root | entries: []}
    FrozenResult.new!(%{record | pruned: true, roots: roots})
  end

  describe "schema" do
    test "one record, frozen_result, in frozen/{frozen_id}.json at format version 1" do
      schema = AtlasRuntimeModel.FrozenResult.__schema__()
      assert schema.version == "0.1.0"
      assert Enum.map(schema.entities, & &1.name) == [:change_entry, :frozen_root, :frozen_result]
      records = for %{persistence: %{}} = e <- schema.entities, do: e
      assert [%{name: :frozen_result, persistence: persistence, fields: fields}] = records

      assert persistence == %{
               form: :json_file,
               path: "frozen/{frozen_id}.json",
               format_version: 1
             }

      assert Enum.map(fields, &{&1.name, &1.type, &1.required}) == [
               {:frozen_id, :string, true},
               {:work_id, :string, true},
               {:attempt, :integer, true},
               {:base, :string, true},
               {:frozen_at, :datetime, true},
               {:pruned, :boolean, true},
               {:roots, {:list, :frozen_root}, true}
             ]
    end

    test "a root and a change entry have exactly the planned fields" do
      entities = Map.new(AtlasRuntimeModel.FrozenResult.__schema__().entities, &{&1.name, &1})
      shape = fn name -> Enum.map(entities[name].fields, &{&1.name, &1.type, &1.required}) end

      assert shape.(:frozen_root) == [
               {:root, :string, true},
               {:fingerprint, :string, true},
               {:entries, {:list, :change_entry}, true}
             ]

      # A delete has path and op only, so everything else is optional.
      assert shape.(:change_entry) == [
               {:path, :string, true},
               {:op, {:enum, [:write, :delete]}, true},
               {:kind, {:enum, [:file, :symlink]}, false},
               {:mode, :string, false},
               {:size, :integer, false},
               {:sha256, :string, false},
               {:target, :string, false}
             ]
    end

    test "the model target has the contract's __schema__/0" do
      alias AtlasRuntimeModel.Test.FrozenResult, as: Target
      assert Target.__schema__() == AtlasRuntimeModel.FrozenResult.__schema__()
      assert Enum.map(Target.records(), &elem(&1, 0)) == [:frozen_result]
    end
  end

  describe "persistence" do
    test "new → encode → JSON → decode gives the same frozen result" do
      record = frozen()
      assert {:ok, ^record} = round_trip(record)
      assert [%FrozenRoot{entries: [%ChangeEntry{} | _]}, %FrozenRoot{entries: []}] = record.roots
    end

    test "the persisted form: string keys, enums as strings, a delete with path and op only" do
      encoded = FrozenResult.encode(frozen())
      assert encoded["format_version"] == 1
      assert encoded["pruned"] == false
      assert encoded["frozen_at"] == "2026-11-17T09:00:00.000000Z"
      [atlas, other] = encoded["roots"]
      assert other == %{"root" => "other", "fingerprint" => fingerprint("2"), "entries" => []}
      [file, _exe, link, delete] = atlas["entries"]

      assert file == %{
               "path" => "a b/é.txt",
               "op" => "write",
               "kind" => "file",
               "mode" => "100644",
               "size" => 12,
               "sha256" => @sha
             }

      assert link["target"] == "a b/é.txt" and link["kind"] == "symlink"
      assert delete == %{"path" => "gone.md", "op" => "delete"}
    end

    test "a tombstone keeps roots and fingerprints, drops entries, and round-trips" do
      record = tombstone(frozen())
      assert record.pruned == true
      assert {:ok, ^record} = round_trip(record)
      encoded = FrozenResult.encode(record)
      assert encoded["pruned"] == true

      assert encoded["roots"] == [
               %{"root" => "atlas", "fingerprint" => fingerprint("1"), "entries" => []},
               %{"root" => "other", "fingerprint" => fingerprint("2"), "entries" => []}
             ]
    end

    test "its path is frozen/<work_id>.<attempt>.json" do
      assert FrozenResult.path(frozen()) == "frozen/work-0123456789abcdef.2.json"

      assert_raise ArgumentError, ~r/no file name/, fn ->
        FrozenResult.path(%{frozen_id: "../work-x.1"})
      end
    end
  end

  describe "refusals" do
    test "another format version, an unknown field or a wrong value is an error" do
      encoded = FrozenResult.encode(frozen())

      assert {:error, {:format_version, 2}} =
               FrozenResult.decode(%{encoded | "format_version" => 2})

      assert {:error, {:unknown_field, "frozen_result.blobs"}} =
               FrozenResult.decode(Map.put(encoded, "blobs", []))

      at = ["roots", Access.at(0), "entries", Access.at(0)]

      assert {:error, {:invalid, "frozen_result.roots[0].entries[0].op", _}} =
               FrozenResult.decode(put_in(encoded, at ++ ["op"], "rename"))

      assert {:error, {:invalid, "frozen_result.roots[0].entries[0].kind", _}} =
               FrozenResult.decode(put_in(encoded, at ++ ["kind"], "directory"))
    end

    test "a root without fingerprint or entries, or a record without pruned, is refused" do
      encoded = FrozenResult.encode(frozen())
      root = ["roots", Access.at(1)]

      for field <- ["fingerprint", "entries"] do
        assert {:error, {:missing_field, "frozen_result.roots[1]." <> ^field}} =
                 FrozenResult.decode(update_in(encoded, root, &Map.delete(&1, field)))
      end

      assert {:error, {:missing_field, "frozen_result.pruned"}} =
               FrozenResult.decode(Map.delete(encoded, "pruned"))
    end
  end
end
