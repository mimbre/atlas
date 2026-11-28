defmodule AtlasBFF.FixtureCombinationsTest do
  use ExUnit.Case, async: true
  alias AtlasBFF.Targets.FixtureCombinations

  defp field(name, type, required \\ false), do: %{name: name, type: type, required: required}

  test "nested models, optional masks and list members combine independently and lazily" do
    leaf = %{name: :leaf, fields: [field(:note, :string), field(:flag, :boolean)]}

    block = %{
      name: :sample,
      fields: [
        field(:child, :leaf, true),
        field(:label, :string),
        field(:children, {:list, :leaf})
      ]
    }

    schema = %{blocks: [block], models: [leaf], markup: []}
    stream = FixtureCombinations.stream(schema, :block, :sample)
    assert Enum.count(stream) == 6 * 2 * (1 + 1 + 6 + 6 * 6 * 6)

    example =
      Enum.find(stream, fn sample ->
        p = sample["props"]

        p["label"] && p["child"]["note"] && p["child"]["flag"] == false &&
          match?([%{"note" => _, "flag" => true}], p["children"])
      end)

    assert example["props"]["child"]["flag"] == false
    assert example["props"]["children"] |> hd() |> Map.fetch!("flag")

    varied =
      Enum.find(stream, fn sample ->
        match?([%{"flag" => false}, %{"flag" => true}, _], sample["props"]["children"])
      end)

    assert varied
  end

  test "taking a prefix does not materialize the optional-field cross-product" do
    fields = for n <- 1..50, do: field(:"field_#{n}", :boolean)
    schema = %{blocks: [%{name: :sample, fields: fields}], models: [], markup: []}
    assert length(schema |> FixtureCombinations.stream(:block, :sample) |> Enum.take(2)) == 2
  end

  test "recursive models are finite at a selected depth" do
    node = %{name: :node, fields: [field(:next, :node)]}

    schema = %{
      blocks: [%{name: :sample, fields: [field(:root, :node, true)]}],
      models: [node],
      markup: []
    }

    assert Enum.count(FixtureCombinations.stream(schema, :block, :sample, max_depth: 2)) == 2
    assert Enum.empty?(FixtureCombinations.stream(schema, :block, :sample, max_depth: 0))
  end
end
