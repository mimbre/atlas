defmodule AtlasFacts.ReviewTest do
  use ExUnit.Case, async: true

  alias AtlasFacts.Review

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

  test "to be reviewed while a fact it points at has the value; why is said" do
    lists = %{
      "template" => [fact("T-1", %{"status" => "replaced"}), fact("T-2", %{"status" => "used"})]
    }

    assert Review.of(@d, lists, "label", fact("L-1", %{}, %{"printed_from" => ["T-2", "T-1"]})) ==
             %{
               "label" => "Review: its template was replaced",
               "through" => "printed_from",
               "key" => "T-1",
               "field" => "status",
               "value" => "replaced"
             }

    assert Review.of(@d, lists, "label", fact("L-2", %{}, %{"printed_from" => ["T-2"]})) == nil
    assert Review.of(@d, lists, "label", fact("L-3", %{})) == nil
  end

  test "a kind without a rule reads nothing and is left as it is" do
    assert Review.needs(@d, "label") == ["template"]
    assert Review.needs(@d, "note") == []
    facts = [fact("N-1", %{})]
    assert Review.annotate(@d, "note", facts, fn _ -> flunk("read") end) == {:ok, facts}
  end

  test "annotate reads what the rule needs once; a failed read is returned as it is" do
    list = fn "template" -> {:ok, [fact("T-1", %{"status" => "replaced"})]} end
    linked = fact("L-1", %{}, %{"printed_from" => ["T-1"]})
    assert {:ok, [%{review: %{"key" => "T-1"}}]} = Review.annotate(@d, "label", [linked], list)

    assert Review.annotate(@d, "label", [linked], fn _ -> {:error, :unavailable} end) ==
             {:error, :unavailable}
  end
end
