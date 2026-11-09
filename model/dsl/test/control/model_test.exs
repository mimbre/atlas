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

    test "fields in the order pages show them: the primary first, then choices and flags" do
      [first, second | _] = kind("letter").fields
      assert first.name == "title" and first.required
      assert second.name == "state" and second.values == ["draft", "sent", "lost"]
      assert second.labels["sent"] == "Sent"
      assert Enum.find(kind("letter").fields, &(&1.name == "code")).url
      refute Enum.find(kind("letter").fields, &(&1.name == "gate_result")).settable
    end

    test "the relations that start at a kind, and the fields a flow keeps to itself" do
      assert Enum.map(kind("letter").relations, & &1.name) == ["desk", "replies_to", "written_by"]
      desk = Enum.find(kind("letter").relations, &(&1.name == "desk"))
      assert desk.component["key"] == "DK-{key}" and desk.one

      assert %{error: "only the writer sets it"} =
               Enum.find(kind("letter").relations, &(&1.name == "written_by")).only_target

      assert kind("desk").hidden == ["flow_state", "handover"]
      assert kind("letter").expected == [%{field: "expected", on_component: true}]
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

  test "the section a heading names: to the next heading" do
    assert Rules.section("Ada can test: open it.\nThen look.", "Ada can test") ==
             "open it.\nThen look."

    assert Rules.section("x\n## Ada can test\none\n\ntwo\n## Next\nthree", "ada can test") ==
             "one\n\ntwo"

    assert Rules.section("nothing here", "Ada can test") == nil
    assert Rules.section(nil, "Ada can test") == nil
  end
end
