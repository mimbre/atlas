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
      "decline" => "passed",
      "superseded" => "replaced",
      "replaceable" => ["taken", "replaced"]
    },
    "adopt" => %{"rule" => "dish", "consequences" => "effects"},
    "content" => ["name", "dish"],
    "content_links" => ["after"],
    "legacy_fingerprint" => %{"fields" => ["name"], "relations" => []},
    "errors" =>
      Map.new(~w(invalid not_json removed unselected changed selection), &{&1, "no #{&1}"})
  }

  @text JSON.encode!(%{
          "question" => "Which?",
          "rationale" => "Soup is warm",
          "recommended" => "soup",
          "options" => [
            %{
              "id" => "soup",
              "text" => "Soup",
              "details" => "Warm",
              "effect" => "adopt",
              "rule" => "Serve soup",
              "consequences" => "Bowls"
            },
            %{
              "id" => "none",
              "text" => "None",
              "details" => "Skip",
              "effect" => "decline",
              "rule" => "",
              "consequences" => ""
            }
          ]
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

    passed = answer("none")
    assert passed["state"] == "passed"
    refute Map.has_key?(passed, "dish")
    assert [] == Options.check(@rule, "change", fact(), answer("soup"), %{})
    assert [] == Options.check(@rule, "change", fact(), passed, %{})

    assert [%{"self" => "picked_by"} | _] =
             Enum.map(Options.answers(@rule, fact()), & &1["change"])
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
