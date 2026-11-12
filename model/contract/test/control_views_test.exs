defmodule Model.ControlViewsTest do
  @moduledoc """
  The pages Control serves are made from the compiled model (`AtlasControl.Model`), never
  from rela's description. They must still name and show a fact as they did when Control
  read the description rela serves, with Atlas's additions merged in: rela gives a kind
  without a primary field one of its own, carries a type's values and labels on each
  property, and serves id prefixes as a list. The fixture is what the pinned rela
  (26.11.2) serves for `rela/` at `GET /api/v1/_schema`; regenerate it from a running
  rela when the model's kinds change.
  """
  use ExUnit.Case, async: true

  @served "test/fixtures/rela-served-schema.json" |> File.read!() |> JSON.decode!()
  @additions Model.AtlasEyra.__rela__(:description).extension
  @kinds Map.new(Model.AtlasEyra.kinds(), &{&1.name, &1})

  # A kind as Control read it before: rela's, with Atlas's additions over it.
  defp described(kind) do
    Map.merge(@served["entities"][kind], @additions["entities"][kind] || %{}, fn
      _, served, added when is_map(served) and is_map(added) ->
        Map.merge(served, added, fn _, s, a -> if is_map(s), do: Map.merge(s, a), else: a end)

      _, _, added ->
        added
    end)
  end

  test "the model's kinds are the ones rela serves" do
    assert Enum.sort(Map.keys(@kinds)) == Enum.sort(Map.keys(@served["entities"]))
  end

  test "each kind is named by the field rela, or Atlas, says names it" do
    for {kind, view} <- @kinds do
      spec = described(kind)
      made_from = get_in(spec, ["create", "id", "from"])
      assert view.primary == (spec["primary"] || made_from), "#{kind}: primary"
    end

    assert @kinds["scene"].primary == "title"
    assert @kinds["turn"].primary == "machine"
  end

  test "each field as rela serves it: its values, their labels, whether it is required" do
    for {kind, view} <- @kinds, field <- view.fields do
      served = @served["entities"][kind]["properties"][field.name]
      assert served, "#{kind}.#{field.name} is not served"
      assert field.values == served["values"], "#{kind}.#{field.name}: values"
      assert field.labels == (served["labels"] || %{}), "#{kind}.#{field.name}: labels"
      assert field.required == (served["required"] == true), "#{kind}.#{field.name}: required"
      assert field.type == served["type"], "#{kind}.#{field.name}: type"
    end

    for {kind, spec} <- @served["entities"],
        do:
          assert(
            Enum.sort(Enum.map(@kinds[kind].fields, & &1.name)) ==
              Enum.sort(Map.keys(spec["properties"])),
            "#{kind}: fields"
          )
  end

  test "fields in the order pages showed them: the primary first, then choices, then flags" do
    for {kind, view} <- @kinds do
      spec = described(kind)
      primary = spec["primary"] || get_in(spec, ["create", "id", "from"])

      expected =
        spec["properties"]
        |> Enum.sort_by(fn {name, prop} ->
          {cond do
             name == primary -> 0
             is_list(prop["values"]) -> 1
             prop["type"] == "boolean" -> 2
             true -> 3
           end, name}
        end)
        |> Enum.map(&elem(&1, 0))

      assert Enum.map(view.fields, & &1.name) == expected, "#{kind}: order"
    end
  end

  test "a key's kind by the id prefixes rela serves" do
    for {kind, view} <- @kinds do
      spec = described(kind)
      created = get_in(spec, ["create", "id", "prefix"]) || List.first(spec["id_prefixes"] || [])

      assert view.id.prefixes ==
               Enum.uniq(
                 for p <- [created | spec["id_prefixes"] || []], p not in [nil, ""], do: p
               ),
             "#{kind}: prefixes"
    end
  end

  test "a scene's page and row are named by its title" do
    m = AtlasControl.Model.catalog(Model.AtlasEyra)
    scene = %{"key" => "SC-Atlas-01", "values" => %{"title" => "Write the first scene"}}
    reads = AtlasControl.Pages.reads({:item, "scene", "SC-Atlas-01"}, m)
    answers = [%{"fact" => scene} | for(_ <- tl(reads), do: %{"facts" => []})]
    page = AtlasControl.Pages.render({:item, "scene", "SC-Atlas-01"}, m, answers)
    item = Enum.find(page.blocks, &(&1["id"] == "item"))["props"]
    assert item["title"] == "Scene SC-Atlas-01: Write the first scene"
    assert [_id, %{"label" => "Title"} | _] = item["fields"]

    %{blocks: [%{"props" => list}]} =
      AtlasControl.Pages.render({:list, "scene"}, m, [%{"facts" => [scene]}])

    assert [%{"label" => "Write the first scene"}] = list["rows"]
  end
end
