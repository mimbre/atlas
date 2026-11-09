defmodule RelaDSL.Facts.ReviewTest do
  use ExUnit.Case, async: true

  alias RelaDSL.Facts.Derived

  # Made-up kinds: a label is printed from a template, which may be replaced.
  @d %{
    "entities" => %{
      "label" => %{},
      "template" => %{"plural" => "templates"},
      "note" => %{}
    },
    "relations" => %{
      "printed_from" => %{
        "from" => ["label"],
        "to" => ["template"],
        "review" => %{
          "field" => "status",
          "value" => "replaced",
          "label" => "Review: its template was replaced"
        }
      }
    }
  }

  defp fact(key, values, links \\ %{}), do: %{key: key, properties: values, links: links}

  test "ordered review rules flag unverified anchors, clear on confirmation and prioritize replacement" do
    rule = @d["relations"]["printed_from"]["review"]

    d =
      put_in(@d, ["relations", "printed_from", "review"], [
        rule,
        %{"field" => "unverified", "value" => true, "label" => "Unverified template"}
      ])

    label = fact("L-1", %{}, %{"printed_from" => ["T-1"]})

    for {status, flag, expected} <- [
          {"used", true, "Unverified template"},
          {"used", false, nil},
          {"replaced", false, rule["label"]}
        ] do
      lists = %{"template" => [fact("T-1", %{"status" => status, "unverified" => flag})]}
      assert (Derived.review_of(d, lists, "label", label) || %{})["label"] == expected
    end

    assert Derived.review_needs(d, "label") == ["template"]
  end

  test "an own-field flag is visible only while it holds" do
    d =
      Map.put(@d, "flow_runtime", %{
        "flags" => %{
          "template" => %{"field" => "unverified", "value" => true, "label" => "Red flag"}
        }
      })

    assert {:ok, [%{review: %{"label" => "Red flag"}}]} =
             Derived.review(d, "template", [fact("T-1", %{"unverified" => true})], fn _ ->
               flunk("no reads")
             end)

    assert {:ok, [%{review: nil}]} =
             Derived.review(d, "template", [fact("T-1", %{"unverified" => false})], fn _ ->
               flunk("no reads")
             end)
  end

  test "to be reviewed while a fact it points at has the value; why is said" do
    lists = %{
      "template" => [fact("T-1", %{"status" => "replaced"}), fact("T-2", %{"status" => "used"})]
    }

    assert Derived.review_of(
             @d,
             lists,
             "label",
             fact("L-1", %{}, %{"printed_from" => ["T-2", "T-1"]})
           ) ==
             %{
               "label" => "Review: its template was replaced",
               "through" => "printed_from",
               "key" => "T-1",
               "field" => "status",
               "value" => "replaced"
             }

    assert Derived.review_of(@d, lists, "label", fact("L-2", %{}, %{"printed_from" => ["T-2"]})) ==
             nil

    assert Derived.review_of(@d, lists, "label", fact("L-3", %{})) == nil
  end

  test "a kind without a rule reads nothing and is left as it is" do
    assert Derived.review_needs(@d, "label") == ["template"]
    assert Derived.review_needs(@d, "note") == []
    facts = [fact("N-1", %{})]
    assert Derived.review(@d, "note", facts, fn _ -> flunk("read") end) == {:ok, facts}
  end

  test "annotate reads what the rule needs once; a failed read is returned as it is" do
    list = fn "template" -> {:ok, [fact("T-1", %{"status" => "replaced"})]} end
    linked = fact("L-1", %{}, %{"printed_from" => ["T-1"]})
    assert {:ok, [%{review: %{"key" => "T-1"}}]} = Derived.review(@d, "label", [linked], list)

    assert Derived.review(@d, "label", [linked], fn _ -> {:error, :unavailable} end) ==
             {:error, :unavailable}
  end
end
