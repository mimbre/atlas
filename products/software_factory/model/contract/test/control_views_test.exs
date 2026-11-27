defmodule Model.ControlViewsTest do
  @moduledoc """
  The pages Control serves are made from the compiled model (`AtlasControl.Model`), never
  from rela's description. They must still name and show a fact as they did when Control
  read the description rela serves, with Atlas's additions merged in: rela gives a kind
  without a primary field one of its own, carries a type's values and labels on each
  property, and serves id prefixes as a list. The fixture is what the pinned rela
  (26.11.9) serves for `products/software_factory/model/targets/rela/` at `GET /api/v1/_schema`; regenerate it from a running
  rela when the model's kinds change.
  """
  use ExUnit.Case, async: true

  @served Model.AtlasEyra.rela_schema()
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

  # SC-Atlas-09: a use case Design made shows its producer, set by Flow and never in a form.
  test "a use case's page shows who produced it" do
    m = AtlasControl.Model.catalog(Model.AtlasEyra)

    use_case = %{
      "key" => "UC-Atlas-01",
      "values" => %{"title" => "Read the README"},
      "links" => %{"produced_by" => ["ada"]},
      "origins" => %{"produced_by" => %{"by" => "flow", "cause" => "For ada: proposed"}}
    }

    reads = AtlasControl.Pages.reads({:item, "use_case", "UC-Atlas-01"}, m)
    answers = [%{"fact" => use_case} | for(_ <- tl(reads), do: %{"facts" => []})]
    page = AtlasControl.Pages.render({:item, "use_case", "UC-Atlas-01"}, m, answers)

    assert [%{"value" => "ada", "origin" => %{"by" => "flow"}}] =
             for(
               b <- page.blocks,
               pair <-
                 List.wrap(get_in(b, ["props", "fields"])) ++
                   List.wrap(get_in(b, ["props", "links"])),
               is_map(pair) and pair["label"] == "Produced by",
               do: pair
             )

    refute AtlasControl.Pages.settable_relation?(m, "produced_by", "ada")
  end

  test "a scene's page and row are named by its title" do
    m = AtlasControl.Model.catalog(Model.AtlasEyra)
    scene = %{"key" => "SC-Atlas-01", "values" => %{"title" => "Write the first scene"}}
    reads = AtlasControl.Pages.reads({:item, "scene", "SC-Atlas-01"}, m)
    answers = [%{"fact" => scene} | for(_ <- tl(reads), do: %{"facts" => []})]
    page = AtlasControl.Pages.render({:item, "scene", "SC-Atlas-01"}, m, answers)
    header = Enum.find(page.blocks, &(&1["id"] == "header"))["props"]
    assert header["title"] == "Write the first scene"
    item = Enum.find(page.blocks, &(&1["id"] == "item"))["props"]
    assert item["title"] == ""
    assert [_id, %{"label" => "Title"} | _] = item["fields"]

    %{blocks: [%{"props" => list}]} =
      AtlasControl.Pages.render({:list, "scene"}, m, [%{"facts" => [scene]}])

    assert [%{"label" => "Write the first scene"}] = list["rows"]
  end

  test "a scene's block page keeps its description, questions and other fields" do
    m = AtlasControl.Model.catalog(Model.AtlasEyra)
    route = {:item, "scene", "SC-Atlas-01"}

    scene = %{
      "key" => "SC-Atlas-01",
      "values" => %{
        "title" => "A scene",
        "description" => "First line\n\nAlready built: Existing work\n\n# Next\nMore",
        "questions" => "What happens next?",
        "answers" => "The producer answered.",
        "flux_id" => "123"
      }
    }

    answers = [
      %{"fact" => scene} | for(_ <- tl(AtlasControl.Pages.reads(route, m)), do: %{"facts" => []})
    ]

    page = AtlasControl.Pages.render(route, m, answers)

    assert Enum.find(page.blocks, &(&1["id"] == "intro"))["props"]["text"] ==
             scene["values"]["description"]

    assert Enum.find(page.blocks, &(&1["id"] == "intro"))["props"]["format"] == "markdown"

    refute Map.has_key?(
             Enum.find(page.blocks, &(&1["id"] == "section-questions"))["props"],
             "format"
           )

    assert Enum.find(page.blocks, &(&1["id"] == "section-questions"))["props"]["text"] ==
             "What happens next?"

    assert Enum.find(page.blocks, &(&1["id"] == "section-answers"))["props"]["text"] ==
             "The producer answered."

    fields = Enum.find(page.blocks, &(&1["id"] == "item"))["props"]["fields"]
    assert Enum.any?(fields, &(&1["value"] == "What happens next?"))
    assert Enum.any?(fields, &(&1["value"] == "The producer answered."))
    assert Enum.any?(fields, &(&1["value"] == "123"))
  end

  test "a failed use case read is shown on the scene page" do
    m = AtlasControl.Model.catalog(Model.AtlasEyra)
    route = {:item, "scene", "SC-Atlas-01"}
    scene = %{"key" => "SC-Atlas-01", "values" => %{"title" => "A scene"}}

    answers =
      for {{kind, _}, i} <- Enum.with_index(AtlasControl.Pages.reads(route, m)) do
        cond do
          i == 0 -> %{"fact" => scene}
          kind == "use_case" -> %{"error" => "Use cases unavailable"}
          true -> %{"facts" => []}
        end
      end

    page = AtlasControl.Pages.render(route, m, answers)

    assert Enum.any?(page.blocks, fn block ->
             block["type"] == "list" and
               get_in(block, ["props", "empty"]) == "Use cases unavailable."
           end)
  end

  # Every action and answer a page offers explains itself (`help`, a client's tooltip):
  # the model's words for its own, Control's for the rest. A to-do's page, an item's page
  # and a list (the decisions' pages: Model.DecisionOptionsTest).
  test "every action and answer on a to-do, an item and a list explains itself" do
    m = AtlasControl.Model.catalog(Model.AtlasEyra)
    form = %{by: "ada", by_kind: "person"}
    to_do_flow = Enum.find(Model.AtlasEyra.subflows(:test), &(&1.name() == "to_do"))

    to_do = %{
      "key" => "TD-01",
      "values" => %{"title" => "Rotate the key", "instructions" => "1. Rotate it"},
      "links" => %{}
    }

    open =
      to_do_flow.present("open", to_do["values"])
      |> Map.merge(%{"owner" => ["ada"], "actionable" => true})

    issue = %{"key" => "IS-Atlas-01", "values" => %{"title" => "Build it"}, "links" => %{}}

    for {route, fact, presentation} <- [
          {{:item, "to_do", "TD-01"}, to_do, open},
          {{:item, "issue", "IS-Atlas-01"}, issue, nil}
        ] do
      answers =
        for {{kind, _}, i} <- Enum.with_index(AtlasControl.Pages.reads(route, m)) do
          cond do
            i == 0 ->
              %{"fact" => fact}

            kind == "assignment" and presentation != nil ->
              %{"fact" => %{"key" => "AS-" <> fact["key"], "presentation" => presentation}}

            true ->
              %{"facts" => []}
          end
        end

      blocks = AtlasControl.Pages.render(route, m, answers, form).blocks
      assert Model.Offered.all(blocks) != [], inspect(route)
      assert Model.Offered.unexplained(blocks) == [], inspect(route)
    end

    list = AtlasControl.Pages.render({:list, "decision"}, m, [%{"facts" => []}], form).blocks
    assert Model.Offered.all(list) != []
    assert Model.Offered.unexplained(list) == []
  end
end
