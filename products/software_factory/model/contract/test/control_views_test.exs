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

  defp plan_page(values, viewer, proposal \\ true) do
    m = AtlasControl.Model.catalog(Model.AtlasEyra)
    route = {:item, "use_case", "UC-1"}

    fact = %{
      "key" => "UC-1",
      "values" => Map.merge(%{"title" => "A use case", "phase" => "break_down"}, values),
      "links" => %{"produced_by" => ["ada"], "in_scene" => ["SC-1"]}
    }

    assignment = %{
      "key" => "AS-UC-1",
      "values" => %{"flow_state" => "accepting", "expected" => "Accept it"},
      "links" => %{"assigned_to" => ["ada"]}
    }

    run = %{
      "key" => "R-1",
      "flow" => "break_down_use_case",
      "generation" => 1,
      "status" => "active",
      "state" => "accepting"
    }

    presenter = Enum.find(Model.AtlasEyra.presentation(), &(&1["subject"] == "use_case"))
    shown = AtlasFacts.Presentation.view(presenter, assignment, fact, [run], fn -> false end)
    assignment = Map.put(assignment, "presentation", shown)
    task = %{"key" => "TK-1", "values" => %{"kind" => "plan", "title" => "Plan"}}

    answers =
      for {{kind, query}, index} <- Enum.with_index(AtlasControl.Pages.reads(route, m)) do
        cond do
          index == 0 ->
            %{"fact" => fact}

          kind == "assignment" and Map.has_key?(query, "key") ->
            %{"fact" => assignment}

          kind == "task" and get_in(query, ["linked", "task_of"]) == "UC-1" ->
            %{"facts" => if(proposal, do: [task], else: [])}

          true ->
            %{"facts" => []}
        end
      end

    AtlasControl.Pages.render(route, m, answers, %{by: viewer, by_kind: "person"})
  end

  test "Plan acceptance groups existing details without changing its proposal or answers" do
    page =
      plan_page(
        %{
          "description" => "Behaviour",
          "design" => "Construction",
          "note" => "Choice",
          "supervisor_note" => "Try again",
          "questions" => "Question?",
          "answers" => "Answer",
          "status" => "refine",
          "children" => 2,
          "open_children" => 1,
          "verdict" => "none",
          "flux_id" => "123"
        },
        "ada"
      )

    blocks = Map.new(page.blocks, &{&1["id"], &1})
    ids = Enum.map(page.blocks, & &1["id"])

    assert Enum.find_index(ids, &(&1 == "panel")) <
             Enum.find_index(ids, &(&1 == "page-detail-0"))

    assert Enum.filter(ids, &String.starts_with?(&1, "page-detail-")) ==
             ~w(page-detail-0 page-detail-1 page-detail-2 page-detail-3)

    fields = fn id -> blocks[id]["props"]["fields"] end

    for value <- ["Behaviour", "Construction", "Choice"],
        do: assert(Enum.any?(fields.("page-detail-0"), &(&1["value"] == value)))

    for value <- ["Try again", "Question?", "Answer"],
        do: assert(Enum.any?(fields.("page-detail-1"), &(&1["value"] == value)))

    assert Enum.any?(
             fields.("page-detail-2"),
             &(&1["label"] == "Produced by" and &1["value"] == "ada")
           )

    assert Enum.any?(fields.("page-detail-3"), &(&1["label"] == "Phase"))
    assert Enum.any?(fields.("item"), &(&1["value"] == "123"))
    assert Enum.any?(page.blocks, &(&1["id"] == "parent:in_scene"))
    assert Enum.any?(blocks["panel"]["props"]["actions"], &(&1["to"] == "/k/task/TK-1"))

    assert Enum.map(blocks["panel"]["props"]["answers"], & &1["label"]) == [
             "Accept",
             "Not accepted"
           ]

    assert Enum.any?(page.markup, &(&1["kind"] == "part" and &1["props"]["role"] == "details"))
  end

  test "sparse Plan acceptance and a non-owner retain their existing behavior" do
    sparse = plan_page(%{}, "ada", false)
    ids = Enum.map(sparse.blocks, & &1["id"])
    assert "panel" in ids
    refute "page-detail-0" in ids
    refute "page-detail-1" in ids
    assert "item" in ids
    panel = Enum.find(sparse.blocks, &(&1["id"] == "panel"))["props"]
    assert panel["actions"] == []
    assert length(panel["answers"]) == 2

    other = plan_page(%{"description" => "Behaviour"}, "bob")
    refute Enum.any?(other.blocks, &String.starts_with?(&1["id"], "page-detail-"))
    refute Enum.any?(other.blocks, &(&1["id"] == "panel"))
  end

  test "a scene's page and row are named by its title" do
    m = AtlasControl.Model.catalog(Model.AtlasEyra)
    scene = %{"key" => "SC-Atlas-01", "values" => %{"title" => "Write the first scene"}}
    reads = AtlasControl.Pages.reads({:item, "scene", "SC-Atlas-01"}, m)
    answers = [%{"fact" => scene} | for(_ <- tl(reads), do: %{"facts" => []})]
    page = AtlasControl.Pages.render({:item, "scene", "SC-Atlas-01"}, m, answers)
    header = Enum.find(page.blocks, &(&1["id"] == "header"))["props"]
    assert header["title"] == "Write the first scene"

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

    fields =
      for block <- page.blocks,
          block["type"] == "item",
          pair <- block["props"]["fields"],
          do: pair

    refute Enum.any?(
             fields,
             &(&1["value"] in [
                 scene["values"]["title"],
                 scene["values"]["description"],
                 "What happens next?",
                 "The producer answered."
               ])
           )

    assert Enum.any?(fields, &(&1["value"] == "123"))
  end

  test "scene related lists have one heading, including when empty" do
    m = AtlasControl.Model.catalog(Model.AtlasEyra)
    route = {:item, "scene", "SC-Atlas-01"}
    scene = %{"key" => "SC-Atlas-01", "values" => %{"title" => "A scene"}}

    answers = [
      %{"fact" => scene} | for(_ <- tl(AtlasControl.Pages.reads(route, m)), do: %{"facts" => []})
    ]

    page = AtlasControl.Pages.render(route, m, answers)
    lists = Map.new(page.blocks, &{&1["id"], &1})
    sections = Enum.filter(page.markup, &(&1["kind"] == "section"))

    assert Enum.any?(sections, &(get_in(&1, ["props", "title"]) == "Gate verdicts"))
    assert Enum.any?(sections, &(get_in(&1, ["props", "title"]) == "Tasks"))

    for section <- sections, block = lists[section["start"]], block && block["type"] == "list" do
      refute Map.has_key?(block["props"], "title")
    end

    assert Enum.any?(page.blocks, fn block ->
             block["type"] == "list" and get_in(block, ["props", "title"]) == "Use cases"
           end)
  end

  test "scene details are ordered separate blocks and retain relation origins and other pairs" do
    m = AtlasControl.Model.catalog(Model.AtlasEyra)
    route = {:item, "scene", "SC-Atlas-01"}

    scene = %{
      "key" => "SC-Atlas-01",
      "values" => %{
        "title" => "People can read the plan",
        "questions" => "Who reads it?",
        "answers" => "New team members",
        "phase" => "break_down",
        "children" => 2,
        "flux_id" => "123"
      },
      "links" => %{"produced_by" => ["ada"]},
      "origins" => %{"produced_by" => %{"by" => "ada", "cause" => "Created"}}
    }

    answers = [
      %{"fact" => scene} | for(_ <- tl(AtlasControl.Pages.reads(route, m)), do: %{"facts" => []})
    ]

    page = AtlasControl.Pages.render(route, m, answers)
    details = Enum.filter(page.blocks, &String.starts_with?(&1["id"], "page-detail-"))
    assert Enum.map(details, & &1["props"]["title"]) == ["People", "Progress", "Scene"]
    people = Enum.at(details, 0)["props"]["fields"]
    assert Enum.any?(people, &(&1["value"] == "ada" and &1["origin"]["cause"] == "Created"))
    assert Enum.any?(Enum.at(details, 1)["props"]["fields"], &(&1["value"] == "2"))
    assert Enum.any?(Enum.at(details, 2)["props"]["fields"], &(&1["value"] == "123"))

    assert Enum.any?(
             page.blocks,
             &(&1["id"] == "item" and &1["props"]["title"] == "Other details")
           )

    assert Enum.any?(page.markup, fn mark ->
             mark["kind"] == "part" and mark["start"] == hd(details)["id"] and
               get_in(mark, ["props", "role"]) == "details"
           end)

    refute Enum.any?(page.markup, &(get_in(&1, ["props", "collapsible"]) == true))
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

  test "a To-Do owner's step page groups details without losing pairs, answers or references" do
    m = AtlasControl.Model.catalog(Model.AtlasEyra)
    route = {:item, "to_do", "TD-01"}
    flow = Enum.find(Model.AtlasEyra.subflows(:test), &(&1.name() == "to_do"))

    fact = %{
      "key" => "TD-01",
      "values" => %{
        "title" => "Rotate the key",
        "instructions" => "Why: leaked\n\n1. Rotate it",
        "status" => "open",
        "note" => "Kept for context",
        "evidence" => "Vault record"
      },
      "links" => %{"based_on" => ["D-0001"]}
    }

    presentation =
      flow.present("open", fact["values"])
      |> Map.merge(%{"owner" => ["ada"], "actionable" => true})

    assignment = %{
      "key" => "AS-TD-01",
      "values" => %{},
      "links" => %{"assigned_to" => ["ada"]},
      "origins" => %{"assigned_to" => %{"by" => "flow", "cause" => "Assigned"}},
      "presentation" => presentation
    }

    answers =
      for {{kind, _}, i} <- Enum.with_index(AtlasControl.Pages.reads(route, m)) do
        cond do
          i == 0 -> %{"fact" => fact}
          kind == "assignment" -> %{"fact" => assignment}
          true -> %{"facts" => []}
        end
      end

    page = AtlasControl.Pages.render(route, m, answers, %{by: "ada", by_kind: "person"})
    blocks = Map.new(page.blocks, &{&1["id"], &1})
    detail = for b <- page.blocks, b["type"] == "item", do: b["props"]
    assert Enum.map(detail, & &1["title"]) == ["Status", "Outcome", "Assignment", "Other details"]
    pairs = for group <- detail, pair <- group["fields"], into: %{}, do: {pair["label"], pair}
    assert pairs["Status"]["value"] == "Open"
    assert pairs["Note"]["value"] == "Kept for context"
    assert pairs["Evidence"]["value"] == "Vault record"
    assert pairs["Assigned to"]["value"] == "ada"
    assert pairs["Assigned to"]["origin"]["cause"] == "Assigned"
    assert pairs["Based on"]["value"] == "D-0001"
    assert Enum.any?(List.last(detail)["fields"], &(&1["label"] == "Based on"))
    refute Map.has_key?(pairs, "Instructions")
    assert Enum.all?(detail, &(&1["actions"] in [nil, []]))

    assert Enum.any?(
             blocks["answers"]["props"]["answers"],
             &(&1["to"] == "/k/to_do/TD-01/answer/x")
           )

    assert [%{"id" => "D-0001", "to" => "/k/decision/D-0001"}] =
             blocks["parent:based_on"]["props"]["rows"]

    assert Enum.any?(page.markup, &(&1["kind"] == "part" and &1["props"]["role"] == "details"))

    sparse = put_in(fact, ["values"], %{"title" => "Rotate the key", "instructions" => "Tidy it"})
    sparse = put_in(sparse, ["links"], %{})
    sparse_answers = List.replace_at(answers, 0, %{"fact" => sparse})

    sparse_answers =
      Enum.map(sparse_answers, fn
        %{"fact" => %{"key" => "AS-TD-01"} = part} ->
          %{"fact" => part |> Map.put("links", %{}) |> Map.put("origins", %{})}

        answer ->
          answer
      end)

    sparse_page =
      AtlasControl.Pages.render(route, m, sparse_answers, %{by: "ada", by_kind: "person"})

    refute Enum.any?(sparse_page.blocks, &(&1["type"] == "item"))
    assert Enum.any?(sparse_page.blocks, &(&1["id"] == "step-1"))

    other = AtlasControl.Pages.render(route, m, answers, %{by: "bob", by_kind: "person"})
    refute Enum.any?(other.blocks, &(&1["type"] == "instruction"))
    refute Enum.any?(other.blocks, &(&1["id"] == "page-detail-1"))
  end

  test "an issue's merge page groups its details without changing the panel or references" do
    values = %{
      "title" => "Build the feature",
      "description" => "The requested behavior",
      "stage" => "development",
      "order" => 4,
      "flux_ref" => "NEXT-42",
      "pr_url" => "https://github.com/mimbre/atlas/pull/42",
      "pr_state" => "open",
      "pr_checks" => "success",
      "pr_checks_head" => "checked-revision",
      "pr_head" => "published-revision",
      "pr_mergeable" => "clean",
      "ci_fixes" => "one",
      "pass_result" => "delivered"
    }

    page = merge_issue_page(values, "ada")
    ids = Enum.map(page.blocks, & &1["id"])
    assert Enum.find_index(ids, &(&1 == "panel")) < Enum.find_index(ids, &(&1 == "page-detail-0"))

    assert Enum.filter(ids, &(&1 in ~w(page-detail-0 page-detail-1 page-detail-2 item))) ==
             ~w(page-detail-0 page-detail-1 page-detail-2 item)

    groups = Map.new(page.blocks, &{&1["id"], &1["props"]})
    assert groups["page-detail-0"]["title"] == "Issue"
    assert groups["page-detail-1"]["title"] == "Pull request"
    assert groups["page-detail-2"]["title"] == "Build and checks"

    assert Enum.any?(
             groups["page-detail-0"]["fields"],
             &(&1["value"] == "The requested behavior")
           )

    assert Enum.any?(groups["page-detail-1"]["fields"], &(&1["value"] == "checked-revision"))
    assert Enum.any?(groups["page-detail-2"]["fields"], &(&1["value"] == "delivered"))

    panel = groups["panel"]
    assert panel["heading"] == "TO MERGE"
    assert Enum.any?(panel["links"], &(&1["key"] == "o"))
    assert Enum.any?(panel["actions"], &(&1["key"] == "r"))
    assert Enum.map(panel["checks"], & &1["label"]) == ~w(CI Review GitHub)
    assert Enum.any?(page.blocks, &(&1["type"] == "list"))
    refute Enum.any?(page.markup, &(get_in(&1, ["props", "collapsible"]) == true))

    pairs =
      for id <- ~w(page-detail-0 page-detail-1 page-detail-2 item),
          pair <- groups[id]["fields"],
          do: pair

    for value <- [
          "The requested behavior",
          "NEXT-42",
          "checked-revision",
          "published-revision",
          "delivered",
          "one"
        ] do
      assert Enum.count(pairs, &(&1["value"] == value)) == 1
    end
  end

  test "sparse merge details and another viewer keep their existing behavior" do
    values = %{"title" => "Sparse"}
    owner = merge_issue_page(values, "ada")
    assert Enum.any?(owner.blocks, &(&1["id"] == "panel"))
    refute Enum.any?(owner.blocks, &(&1["id"] in ~w(page-detail-0 page-detail-1 page-detail-2)))
    assert Enum.any?(owner.blocks, &(&1["id"] == "item"))

    other = merge_issue_page(values, "other")
    refute Enum.any?(other.blocks, &(&1["id"] == "panel"))
    refute Enum.any?(other.blocks, &(&1["id"] in ~w(page-detail-0 page-detail-1 page-detail-2)))
  end

  defp merge_issue_page(values, viewer) do
    m = AtlasControl.Model.catalog(Model.AtlasEyra)
    flow = Enum.find(Model.AtlasEyra.subflows(:test), &(&1.name() == "issue"))

    presentation =
      flow.present("merging", values)
      |> Map.merge(%{"state" => "merging", "owner" => ["ada"], "actionable" => true})

    issue = %{"key" => "IS-Atlas-01", "values" => values, "links" => %{}}
    assignment = %{"key" => "AS-IS-Atlas-01", "values" => %{}, "presentation" => presentation}

    review = %{
      "key" => "TK-review",
      "values" => %{"kind" => "review", "verdict" => "approved"},
      "links" => %{}
    }

    route = {:item, "issue", issue["key"]}

    answers =
      for {{kind, _}, i} <- Enum.with_index(AtlasControl.Pages.reads(route, m)) do
        cond do
          i == 0 -> %{"fact" => issue}
          kind == "assignment" -> %{"fact" => assignment}
          kind == "task" -> %{"facts" => [review]}
          true -> %{"facts" => []}
        end
      end

    AtlasControl.Pages.render(route, m, answers, %{by: viewer, by_kind: "person"})
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
