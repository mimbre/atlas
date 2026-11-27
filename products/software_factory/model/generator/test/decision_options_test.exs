defmodule RelaDSL.DecisionOptionsTest do
  use ExUnit.Case, async: true
  alias RelaDSL.DecisionOptions, as: Options

  # A neutral kind: every field name and refusal comes from its annotation.
  @rule %{
    "definition" => "menu",
    "selected" => "picked",
    "snapshot" => "picked_menu",
    "revision" => "picked_revision",
    "history" => "menu_history",
    "answered_at" => "picked_at",
    "answered_by" => "picked_by",
    "status" => %{
      "field" => "state",
      "open" => "open",
      "adopt" => "taken",
      "superseded" => "replaced",
      "replaceable" => ["taken", "replaced"]
    },
    "adopt" => %{"rule" => "dish", "consequences" => "effects"},
    "content" => ["name", "dish"],
    "content_links" => ["after"],
    "legacy_fingerprint" => %{"fields" => ["name"], "relations" => []},
    "errors" =>
      Map.new(
        ~w(invalid no_option not_json removed unselected changed selection),
        &{&1, "no #{&1}"}
      )
  }

  @soup %{
    "id" => "soup",
    "text" => "Soup",
    "details" => "Warm",
    "effect" => "adopt",
    "rule" => "Serve soup",
    "consequences" => "Bowls"
  }

  @bread %{
    "id" => "bread",
    "text" => "Bread",
    "details" => "Quick",
    "effect" => "adopt",
    "rule" => "Serve bread",
    "consequences" => "Crumbs"
  }

  # A "no" option, as definitions held one before Decline was always offered (D-0106).
  @none %{
    "id" => "none",
    "text" => "None",
    "details" => "Skip",
    "effect" => "decline",
    "rule" => "",
    "consequences" => ""
  }

  defp menu(options),
    do:
      JSON.encode!(%{
        "question" => "Which?",
        "rationale" => "Soup is warm",
        "recommended" => "soup",
        "options" => options
      })

  @text JSON.encode!(%{
          "question" => "Which?",
          "rationale" => "Soup is warm",
          "recommended" => "soup",
          "options" => [@soup, @bread]
        })

  defp fact(values \\ %{}),
    do: %{
      "values" => Map.merge(%{"name" => "Lunch", "menu" => @text, "state" => "open"}, values),
      "links" => %{}
    }

  defp answer(id) do
    {:ok, definition} = Options.decode(@rule, @text)
    option = Enum.find(definition["options"], &(&1["id"] == id))
    Options.values(@rule, @text, option, fact()) |> Map.put("picked_at", "2026-11-16T12:00:00Z")
  end

  test "an answer sets the annotation's fields and statuses" do
    assert %{"picked" => "soup", "state" => "taken", "dish" => "Serve soup", "effects" => "Bowls"} =
             answer("soup")

    assert %{"picked" => "bread", "state" => "taken", "dish" => "Serve bread"} = answer("bread")
    assert [] == Options.check(@rule, "change", fact(), answer("soup"), %{})
    assert [] == Options.check(@rule, "change", fact(), answer("bread"), %{})

    assert [%{"self" => "picked_by"}, %{"self" => "picked_by"}] =
             Enum.map(Options.answers(@rule, fact()), & &1["change"])
  end

  test "a definition holds alternatives only: a no option is refused, Decline is always there" do
    assert {:error, "no no_option"} = Options.decode(@rule, menu([@soup, @none]))
    assert {:error, "no invalid"} = Options.decode(@rule, menu([]))

    assert ["no no_option"] ==
             Options.check(@rule, "change", fact(), %{"menu" => menu([@soup, @none])}, %{})

    # An open record whose stored definition still has one takes a definition without it.
    old = fact(%{"menu" => menu([@soup, @none])})
    assert [] == Options.check(@rule, "change", old, %{"menu" => menu([@soup])}, %{})
    assert Options.answers(@rule, old) == []
  end

  test "refusals are the annotation's" do
    assert {:error, "no not_json"} = Options.decode(@rule, nil)
    assert {:error, "no invalid"} = Options.decode(@rule, "{}")

    assert ["no selection"] ==
             Options.check(@rule, "change", fact(), Map.put(answer("soup"), "dish", "X"), %{})

    assert ["no unselected"] == Options.check(@rule, "change", fact(), %{"state" => "taken"}, %{})

    # A rule that words none of them still refuses with a reason.
    assert [why] =
             Options.check(
               Map.delete(@rule, "errors"),
               "change",
               fact(),
               %{"state" => "taken"},
               %{}
             )

    assert is_binary(why)
  end

  test "the offer revision covers the annotation's content and links only" do
    base = Options.revision(@rule, @text, fact())
    assert base != Options.revision(@rule, @text, fact(%{"dish" => "Bread"}))
    assert base == Options.revision(@rule, @text, fact(%{"other" => "ignored"}))
    assert base != Options.revision(@rule, @text, put_in(fact(), ["links", "after"], ["X-1"]))
  end

  test "records without options keep the annotation's legacy fingerprint" do
    spec = %{"fields" => ["name", "menu"]}
    plain = %{"values" => %{"name" => "Lunch"}, "links" => %{}}

    assert [^spec, %{"fields" => ["name"]}] =
             Options.fingerprint_specs(@rule, plain, plain, spec)

    assert [^spec] = Options.fingerprint_specs(@rule, fact(), fact(), spec)
  end
end
