defmodule RelaDSL.Control.ModelTest do
  use ExUnit.Case, async: true

  alias RelaDSL.Control.Rules
  alias RelaDSL.Office

  defp kind(name), do: Enum.find(Office.kinds(), &(&1.name == name))

  describe "the kinds" do
    test "every kind once, sorted, with its names and its id" do
      assert Enum.map(Office.kinds(), & &1.name) == Enum.sort(Enum.map(Office.kinds(), & &1.name))
      letter = kind("letter")
      assert %{label: "Letter", plural: "Letters", top: true, newest_first: true} = letter
      assert %{prefix: "LE-", digits: 2, from: nil, prefixes: ["LE-"]} = letter.id
      assert %{from: "name", prefixes: []} = kind("clerk").id
      refute kind("clerk").top
    end

    test "a kind without a primary field is named by the one rela gives it" do
      # A required text field: title, else name, else the first by name.
      assert kind("desk").primary == "of"
      assert kind("letter").primary == "title"
      # None required: rela names none; a kind whose id is made from a field, by that.
      assert kind("run").primary == nil
      assert kind("clerk").primary == "name"
    end

    test "fields in the order pages show them: the primary first, then choices and flags" do
      [first, second | _] = kind("letter").fields
      assert first.name == "title" and first.required
      assert second.name == "state" and second.values == ["draft", "sent", "lost"]
      assert second.labels["sent"] == "Sent"
      assert Enum.find(kind("letter").fields, &(&1.name == "code")).url
      refute Enum.find(kind("letter").fields, &(&1.name == "gate_result")).settable
    end

    test "field formats pass through from the declaration" do
      assert Enum.find(kind("letter").fields, &(&1.name == "body")).format == "markdown"
      assert Enum.find(kind("letter").fields, &(&1.name == "title")).format == nil
    end

    test "the relations that start at a kind, and the fields a flow keeps to itself" do
      assert Enum.map(kind("letter").relations, & &1.name) == ["desk", "replies_to", "written_by"]
      desk = Enum.find(kind("letter").relations, &(&1.name == "desk"))
      assert desk.component["key"] == "DK-{key}" and desk.one

      assert %{error: "only the writer sets it"} =
               Enum.find(kind("letter").relations, &(&1.name == "written_by")).only_target

      # The selected subflow presents letters on their desk (its projection keeps only the
      # state there); what is expected, Facts' presentation says.
      assert kind("desk").hidden == ["flow_state"]
      refute Map.has_key?(kind("letter"), :expected)
    end
  end

  test "forms: a create asks its rule's fields; a change never the field the id is made from" do
    assert %{ask: ["title", "body"], defaults: %{"state" => "draft"}} =
             Office.form("letter", :create)

    assert %{ask: ask, made_from: "name"} = Office.form("clerk", :edit)
    refute "name" in ask
    refute "away" in ask
    assert Office.form("nothing", :create) == nil
  end

  test "a key made from a field, the same for the same value; else why not" do
    assert Office.key("clerk", %{"name" => " ada "}) == {:ok, "ada"}
    assert Office.key("clerk", %{"name" => "Ada Lovelace"}) == {:error, "a name"}
    assert {:error, _} = Office.key("letter", %{"title" => "x"})

    lower = %{
      "from" => "name",
      "pattern" => "^\\s*([A-Za-z]+)",
      "template" => "{1}",
      "lower" => true
    }

    assert Rules.key(lower, %{"name" => " Ada Lovelace"}) == {:ok, "ada"}
  end

  test "actions: what a kind offers by hand, and a fact's own while its values allow" do
    assert Office.actions("letter", nil, nil) == [:create, :update]
    assert Office.actions("run", nil, nil) == []
    sent = %{"key" => "LE-01", "values" => %{"state" => "sent"}}
    assert [%{op: :update}, %{key: "x", to: "agent:lose"}] = Office.actions("letter", sent, %{})

    assert [%{op: :update}] =
             Office.actions("letter", put_in(sent, ["values", "state"], "draft"), %{})
  end

  test "the start page and the shell, with the tabs the environment adds" do
    assert %{assigned: %{relation: "held_by", count: "{count} yours"}, open: nil} =
             Office.start_page()

    assert [%{kind: "desk", key: "d"}, %{kind: "letter", key: "l"}] = Office.start_page().actions
    tab = %{"id" => "workers", "label" => "Workers", "to" => "/workers"}
    assert %{"title" => "Office", "tabs" => [_, ^tab]} = Office.shell(%{"tabs" => [tab]})
  end

  test "the start page's greeting: its words reach the assigned entry; only text is taken" do
    assert Office.start_page().assigned.greeting == "Good day, {name}."

    # The office's own start entry, as its atlas.json holds it, with one value changed.
    start = Office.__rela__(:description).extension["start"]
    greeting = fn value -> put_in(start, ["assigned", "greeting"], value) end

    refused = fn value ->
      for {path, problem} <- RelaDSL.Description.Check.check(%{}, %{"start" => greeting.(value)}),
          RelaDSL.Problem.key(problem) == {:greeting_text, []},
          do: path
    end

    assert refused.("Good day, {name}.") == []
    assert refused.(nil) == []

    for value <- [3, ["Good day"], "  ", %{"text" => "Good day"}],
        do: assert(refused.(value) == [["start", "assigned", "greeting"]], inspect(value))
  end

  test "what to do is only its owner's, in a state that says so" do
    letter = %{"key" => "LE-01", "values" => %{}, "links" => %{"desk" => ["DK-LE-01"]}}

    desk = %{
      "key" => "DK-LE-01",
      "values" => %{"flow_state" => "stuck", "expected" => "Decide"},
      "links" => %{"held_by" => ["ada"]}
    }

    # The subflow's stuck state shows nothing to do; nobody else is the owner.
    assert Office.todo("letter", letter, %{"desk" => desk}, %{key: "ada"}) == nil
    assert Office.todo("letter", letter, %{"desk" => desk}, %{key: "bob"}) == nil

    assert {:refuse, _} =
             Office.answer("letter", "a", %{"fact" => letter, "parts" => %{"desk" => desk}}, %{
               key: "ada"
             })
  end

  test "an agent that assists the owner answers on their behalf, never with a self answer" do
    flow = %{on: nil, on_kind: nil, owner_relation: "held_by", words: %{title: "Letter"}}

    answers = [
      %{"key" => "a", "label" => "Accept", "change" => %{"values" => %{"verdict" => "accept"}}},
      %{"key" => "s", "label" => "Sign", "change" => %{"self" => "signed_by", "values" => %{}}}
    ]

    letter = %{
      "key" => "LE-01",
      "values" => %{},
      "presentation" => %{
        "owner" => ["ada"],
        "actionable" => true,
        "todo" => %{"answers" => answers}
      }
    }

    item = %{"fact" => letter, "parts" => %{}}
    agent = %{key: "clerk", kind: "agent", assists: "ada"}

    assert Enum.map(Rules.todo(flow, letter, %{}, %{key: "ada"}).answers, & &1.key) == ~w(a s)
    assert Enum.map(Rules.todo(flow, letter, %{}, agent).answers, & &1.key) == ~w(a)
    assert Rules.todo(flow, letter, %{}, %{agent | assists: "bob"}) == nil

    assert {:write, %{"on_behalf" => "ada", "values" => %{"verdict" => "accept"}}} =
             Rules.answer(flow, "a", item, agent)

    assert {:write, %{"on_behalf" => nil}} = Rules.answer(flow, "a", item, %{key: "ada"})
    assert {:refuse, _} = Rules.answer(flow, "s", item, agent)
  end

  test "each answer weighs main, no or other: as the model says, else the first and the first other note" do
    flow = %{on: nil, on_kind: nil, owner_relation: "held_by", words: %{title: "Letter"}}
    change = %{"values" => %{"verdict" => "x"}}

    weights = fn answers ->
      letter = %{
        "key" => "LE-01",
        "values" => %{},
        "presentation" => %{
          "owner" => ["ada"],
          "actionable" => true,
          "todo" => %{"answers" => answers}
        }
      }

      for a <- Rules.todo(flow, letter, %{}, %{key: "ada"}).answers, do: {a.label, a.weight}
    end

    # Not declared: Done (the first, though it asks a note) main, Won't do no, Later other.
    assert weights.([
             %{"key" => "x", "label" => "Done", "note" => true, "change" => change},
             %{"key" => "n", "label" => "Won't do", "note" => true, "change" => change},
             %{"key" => "l", "label" => "Later", "change" => change}
           ]) == [{"Done", "main"}, {"Won't do", "decline"}, {"Later", "other"}]

    # Declared: a no without a note, and the main one after it.
    assert weights.([
             %{"key" => "c", "label" => "Close it", "weight" => "decline", "change" => change},
             %{"key" => "p", "label" => "Publish", "change" => change},
             %{"key" => "r", "label" => "Retry", "weight" => "main", "change" => change}
           ]) == [{"Close it", "decline"}, {"Publish", "other"}, {"Retry", "main"}]
  end

  test "a section shows the part of a field under its heading, or all of it under a label" do
    flow = %{on: nil, on_kind: nil, owner_relation: "held_by", words: %{title: "Letter"}}

    fact = fn section, body ->
      %{
        "key" => "LE-01",
        "values" => %{"body" => body},
        "presentation" => %{
          "owner" => ["ada"],
          "actionable" => true,
          "expected" => "Write it",
          "todo" => %{"section" => section}
        }
      }
    end

    todo = &Rules.todo(flow, &1, %{}, %{key: "ada"})
    body = "Open it.\n## Then\nLook."
    labelled = %{"field" => "body", "label" => "Body"}

    assert todo.(fact.(labelled, body)).section == %{heading: "Body", text: body}

    assert todo.(fact.(%{"field" => "body", "heading" => "Then"}, body)).section ==
             %{heading: "Then", text: "Look."}

    # Nothing to show: no section.
    assert todo.(fact.(labelled, "  ")).section == nil
    assert todo.(fact.(labelled, nil)).section == nil
  end

  test "the section a heading names: to the next heading" do
    assert Rules.section("Ada can test: open it.\nThen look.", "Ada can test") ==
             "open it.\nThen look."

    assert Rules.section("x\n## Ada can test\none\n\ntwo\n## Next\nthree", "ada can test") ==
             "one\n\ntwo"

    assert Rules.section("nothing here", "Ada can test") == nil
    assert Rules.section(nil, "Ada can test") == nil
  end
end
