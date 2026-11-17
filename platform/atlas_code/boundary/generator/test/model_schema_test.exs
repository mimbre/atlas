defmodule AtlasCodeBoundary.Generator.ModelSchemaTest do
  # The model schema shape is the one thing this generator shares with a model generator
  # (D36). The fixture is a copy of that shape; these tests fail when the fixture, or the
  # shape the Boundary target accepts, drifts.
  use ExUnit.Case, async: true

  alias AtlasCodeBoundary.Generator.ModelSchema

  @fixture Path.expand("fixtures/model_schema.exs", __DIR__)

  setup_all do
    {schema, _binding} = Code.eval_file(@fixture)
    %{schema: schema}
  end

  test "the fixture has the model schema shape", %{schema: schema} do
    assert ModelSchema.validate(schema) == :ok
  end

  test "the fixture has exactly the shape's keys, at every level", %{schema: schema} do
    assert schema |> Map.keys() |> Enum.sort() == [:entities, :version]

    for entity <- schema.entities do
      assert entity |> Map.keys() |> Enum.sort() == [:fields, :name, :persistence]

      for field <- entity.fields,
          do: assert(field |> Map.keys() |> Enum.sort() == [:name, :required, :type])

      if entity.persistence,
        do:
          assert(
            entity.persistence |> Map.keys() |> Enum.sort() == [:form, :format_version, :path]
          )
    end
  end

  test "the fixture covers both kinds of entity and every kind of type", %{schema: schema} do
    {records, held} = Enum.split_with(schema.entities, & &1.persistence)
    assert records != [] and held != []
    assert Enum.any?(records, &(&1.persistence.path =~ "{")), "a record with one file each"
    refute Enum.all?(records, &(&1.persistence.path =~ "{")), "a record in one shared file"

    kinds =
      for entity <- schema.entities, field <- entity.fields, uniq: true, do: kind(field.type)

    assert Enum.sort(kinds) ==
             Enum.sort([
               :string,
               :integer,
               :boolean,
               :datetime,
               :enum,
               :one_of,
               :entity,
               {:list, :enum},
               {:list, :entity}
             ])

    assert Enum.any?(schema.entities, fn e -> Enum.any?(e.fields, & &1.required) end)
    assert Enum.any?(schema.entities, fn e -> Enum.any?(e.fields, &(not &1.required)) end)
  end

  describe "a change of shape is refused" do
    test "a key added, renamed or left out", %{schema: schema} do
      [first | rest] = schema.entities
      [field | fields] = first.fields

      for {changed, pattern} <- [
            {Map.put(schema, :name, "x"), ~r/schema has keys .* \(unknown \[:name\]\)/},
            {Map.delete(schema, :version), ~r/missing \[:version\]/},
            {%{schema | entities: [Map.put(first, :table, "t") | rest]}, ~r/unknown \[:table\]/},
            {%{schema | entities: [Map.delete(first, :persistence) | rest]},
             ~r/missing \[:persistence\]/},
            {%{
               schema
               | entities: [%{first | fields: [Map.delete(field, :required) | fields]} | rest]
             }, ~r/missing \[:required\]/},
            {%{
               schema
               | entities: [
                   %{
                     first
                     | fields: [Map.put(Map.delete(field, :type), :kind, :integer) | fields]
                   }
                   | rest
                 ]
             }, ~r/unknown \[:kind\]/}
          ] do
        assert {:error, reasons} = ModelSchema.validate(changed)
        assert Enum.any?(reasons, &(&1 =~ pattern)), inspect(reasons)
      end
    end

    test "persistence that is neither the form nor nil", %{schema: schema} do
      record = Enum.find(schema.entities, & &1.persistence)

      for {persistence, pattern} <- [
            {%{record.persistence | form: :sqlite}, ~r/form must be :json_file/},
            {%{record.persistence | format_version: 0}, ~r/format_version must be a positive/},
            {Map.delete(record.persistence, :path), ~r/missing \[:path\]/},
            {false, ~r/persistence must be a map or nil/}
          ] do
        changed = %{schema | entities: [%{record | persistence: persistence}]}
        assert {:error, reasons} = ModelSchema.validate(changed)
        assert Enum.any?(reasons, &(&1 =~ pattern)), inspect(reasons)
      end
    end

    test "a type outside the shared vocabulary" do
      for {type, pattern} <- [
            {{:map, :string}, ~r/unknown type \{:map, :string\}/},
            {{:one_of, [:a, :b], tag: :kind}, ~r/unknown type/},
            {{:one_of, [:a]}, ~r/a one_of is/},
            {{:enum, []}, ~r/an enum is/},
            {:nobody, ~r/unknown type :nobody/}
          ] do
        schema = %{
          version: "1",
          entities: [
            %{name: :a, fields: [%{name: :x, type: type, required: true}], persistence: nil},
            %{name: :b, fields: [], persistence: nil}
          ]
        }

        assert {:error, reasons} = ModelSchema.validate(schema)
        assert Enum.any?(reasons, &(&1 =~ pattern)), inspect(reasons)
      end
    end
  end

  test "a model whose __schema__/0 drifts from the shape fails the Boundary target" do
    Code.compile_string("""
    defmodule DriftedModel do
      def __schema__,
        do: %{version: "1", entities: [%{name: :a, fields: [], persistence: nil, table: "a"}]}
    end
    """)

    assert_raise CompileError,
                 ~r/model: DriftedModel.__schema__\/0 is not the model schema shape: .*unknown \[:table\]/,
                 fn ->
                   Code.compile_string("""
                   defmodule DriftedFacade do
                     use AtlasCodeBoundary.Generator.Targets.Boundary,
                       contract: AtlasCodeBoundary.Generator.Catalogue,
                       implementation: Nobody,
                       mappings: AtlasCodeBoundary.Generator.CatalogueMappings,
                       model: DriftedModel
                   end
                   """)
                 end
  end

  defp kind({:list, inner}), do: {:list, kind(inner)}
  defp kind({:enum, _}), do: :enum
  defp kind({:one_of, _}), do: :one_of
  defp kind(type) when type in [:string, :integer, :boolean, :datetime], do: type
  defp kind(_entity), do: :entity
end
