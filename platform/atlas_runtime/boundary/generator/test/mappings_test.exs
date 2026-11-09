defmodule AtlasRuntimeBoundary.Generator.MappingsTest do
  use ExUnit.Case, async: true

  alias AtlasRuntimeBoundary.Generator.{Catalogue, CatalogueMappings}

  test "__mappings__/0 holds the mappings in order, as atoms only (and each line)" do
    assert [copy, shelf, branch, hold, ledger] = CatalogueMappings.__mappings__()

    assert %{
             model: :copy_record,
             boundary: :copy,
             direction: :both,
             rename: [copy_id: :id, wear: :condition, location: :place],
             drop: [:lent_count, :scan_path],
             values: [wear: [badly_worn: :"badly-worn"]],
             supply: [:status, :notes]
           } = copy

    assert %{model: :shelf_spot, boundary: :shelf, rename: [], drop: [], supply: []} = shelf
    assert %{model: :branch_spot, boundary: :branch} = branch
    assert %{model: :hold, drop: [:desk_note]} = hold
    assert %{model: :ledger_entry, direction: :from_model} = ledger

    for mapping <- CatalogueMappings.__mappings__() do
      assert is_integer(mapping.line)
      assert mapping |> Map.delete(:line) |> atoms_only?(), inspect(mapping)
    end
  end

  test "mappings are no part of the contract's schema" do
    schema = inspect(Catalogue.__schema__())

    for name <- ["copy_record", "ledger_entry", "scan_path", "lent_count", "desk_note", "mapping"],
        do: refute(schema =~ name, name)
  end

  describe "a mistake fails compilation, at its line" do
    test "names that are no snake_case atoms" do
      assert_raise CompileError, ~r/nofile:3: defmapping: the model entity "a" is no snake/, fn ->
        mappings(~s(defmapping "a", :b))
      end

      assert_raise CompileError, ~r/the boundary model B is no snake_case atom/, fn ->
        mappings("defmapping :a, B")
      end

      assert_raise CompileError, ~r/a -> b: rename: is \[model_field: boundary_field\]/, fn ->
        mappings(~s(defmapping :a, :b, rename: [x: "y"]))
      end

      assert_raise CompileError, ~r/a -> b: drop: is \[model_field\]/, fn ->
        mappings("defmapping :a, :b, drop: :x")
      end

      assert_raise CompileError, ~r/a -> b: supply: is \[boundary_field\]/, fn ->
        mappings("defmapping :a, :b, supply: [X]")
      end

      assert_raise CompileError,
                   ~r/values: is \[model_field: \[model_value: boundary_value\]\]/,
                   fn -> mappings("defmapping :a, :b, values: [x: [y: nil]]") end
    end

    test "an unknown option or direction" do
      assert_raise CompileError,
                   ~r/the options are direction:, rename:, drop:, values: and supply:/,
                   fn -> mappings("defmapping :a, :b, derive: [x: :y]") end

      assert_raise CompileError, ~r/direction: is :both or :from_model, got :to_model/, fn ->
        mappings("defmapping :a, :b, direction: :to_model")
      end
    end

    test "a name given twice, or renamed and dropped" do
      assert_raise CompileError, ~r/drop: names :x twice/, fn ->
        mappings("defmapping :a, :b, drop: [:x, :x]")
      end

      assert_raise CompileError, ~r/rename: names boundary field :y twice/, fn ->
        mappings("defmapping :a, :b, rename: [x: :y, z: :y]")
      end

      assert_raise CompileError, ~r/:x is both renamed and dropped/, fn ->
        mappings("defmapping :a, :b, rename: [x: :y], drop: [:x]")
      end

      assert_raise CompileError, ~r/:x is dropped, so it has no values to rename/, fn ->
        mappings("defmapping :a, :b, drop: [:x], values: [x: [p: :q]]")
      end

      assert_raise CompileError, ~r/values: for :x names boundary value :q twice/, fn ->
        mappings("defmapping :a, :b, values: [x: [p: :q, r: :q]]")
      end
    end

    test "a model entity mapped twice" do
      assert_raise CompileError, ~r/nofile:4: defmapping: model entity :a is mapped twice/, fn ->
        mappings("defmapping :a, :b\ndefmapping :a, :c")
      end
    end
  end

  defp mappings(body) do
    Code.compile_string("""
    defmodule Mappings#{System.unique_integer([:positive])} do
      use AtlasRuntimeBoundary.Generator.Mappings
    #{body}
    end
    """)
  end

  defp atoms_only?(value) when is_map(value),
    do: Enum.all?(value, fn {k, v} -> atoms_only?(k) and atoms_only?(v) end)

  defp atoms_only?(value) when is_list(value), do: Enum.all?(value, &atoms_only?/1)
  defp atoms_only?({k, v}), do: atoms_only?(k) and atoms_only?(v)
  defp atoms_only?(value), do: is_atom(value)
end
