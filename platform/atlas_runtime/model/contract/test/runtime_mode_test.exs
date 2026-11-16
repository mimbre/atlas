defmodule AtlasRuntimeModel.RuntimeModeTest do
  use ExUnit.Case, async: true

  alias AtlasRuntimeModel.Generator.{Header, Targets.Json}
  alias AtlasRuntimeModel.Test.RuntimeMode.RuntimeMode

  @t0 ~U[2026-11-16 09:00:00.000000Z]

  defp mode(value), do: RuntimeMode.new!(mode: value, changed_at: @t0, changed_by: "local:op")

  defp round_trip(file), do: file |> JSON.encode!() |> JSON.decode!() |> RuntimeMode.decode_file()

  describe "schema" do
    test "one record, runtime_mode, in mode.json at format version 1" do
      schema = AtlasRuntimeModel.RuntimeMode.__schema__()
      assert [%{name: :runtime_mode, persistence: persistence}] = schema.entities
      assert persistence == %{form: :json_file, path: "mode.json", format_version: 1}
      assert RuntimeMode.path() == "mode.json"
    end

    test "targets/json/runtime_mode.json is what the contract generates (golden)" do
      schema = AtlasRuntimeModel.RuntimeMode.__schema__()
      [{"runtime_mode.json", body}] = Json.files(:runtime_mode, schema)
      root = Path.expand("../../../..", File.cwd!())
      source = List.to_string(AtlasRuntimeModel.RuntimeMode.module_info(:compile)[:source])
      expected = Header.put(".json", Path.relative_to(source, root), body)
      assert File.read!("../targets/json/runtime_mode.json") == expected
    end
  end

  describe "persistence" do
    test "each persisted mode round-trips through mode.json" do
      for value <- [:open, :paused, :draining] do
        record = mode(value)
        file = RuntimeMode.encode_file([record])

        assert %{
                 "format_version" => 1,
                 "entries" => [
                   %{
                     "mode" => _,
                     "changed_at" => "2026-11-16T09:00:00.000000Z",
                     "changed_by" => "local:op"
                   }
                 ]
               } = file

        assert hd(file["entries"])["mode"] == Atom.to_string(value)
        assert {:ok, [^record]} = round_trip(file)
      end
    end
  end

  describe "refusals" do
    # stopping is never persisted (§13.1 Q6): a file that says so is refused, not read.
    test "stopping is no persisted mode" do
      file = RuntimeMode.encode_file([mode(:paused)])
      stopping = put_in(file, ["entries", Access.at(0), "mode"], "stopping")

      assert {:error, {:invalid, "runtime_mode[0].mode", _}} = round_trip(stopping)

      assert {:error, {:invalid, "runtime_mode.mode", _}} =
               RuntimeMode.new(mode: :stopping, changed_at: @t0, changed_by: "local:op")
    end

    test "a mode without when or by whom, or in another format version, is refused" do
      file = RuntimeMode.encode_file([mode(:draining)])

      for field <- ["changed_at", "changed_by"] do
        missing = update_in(file, ["entries", Access.at(0)], &Map.delete(&1, field))
        assert {:error, {:missing_field, "runtime_mode[0]." <> ^field}} = round_trip(missing)
      end

      assert {:error, {:format_version, 2}} = round_trip(%{file | "format_version" => 2})
    end
  end
end
