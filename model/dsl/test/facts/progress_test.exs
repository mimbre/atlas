defmodule RelaDSL.Facts.ProgressTest do
  use ExUnit.Case, async: true

  alias RelaDSL.Facts.Derived

  # Made-up kinds, two levels: a box holds crates, a crate holds jars. A jar says how far it
  # is in `phase`; a crate and a box in `group` while nothing is under them. A jar is
  # completed when a label that points at it says it is sent; a crate or a box when
  # someone signed it (an association).
  @description %{
    "progress" => %{
      "order" => ["draft", "agreed", "packing", "sealed", "check"],
      "done_label" => "Shipped",
      "to_test" => %{"value" => "check", "label" => "Check"}
    },
    "entities" => %{
      "box" => %{
        "plural" => "boxes",
        "progress" => %{"over" => "in_box", "own" => "group"},
        "completion" => %{"by" => "signed_by"},
        "properties" => %{"group" => %{"labels" => %{"draft" => "Draft", "agreed" => "Agreed"}}}
      },
      "crate" => %{
        "plural" => "crates",
        "progress" => %{"over" => "in_crate", "field" => "phase", "own" => "group"},
        "completion" => %{"by" => "signed_by"},
        "properties" => %{"group" => %{"labels" => %{"draft" => "Draft", "agreed" => "Agreed"}}}
      },
      "label" => %{"plural" => "labels"},
      "jar" => %{
        "plural" => "jars",
        "completion" => [
          %{"over" => "on_jar", "field" => "state", "value" => "sent"},
          %{"through" => "also_on", "field" => "state", "value" => "sent"}
        ],
        "properties" => %{
          "phase" => %{"labels" => %{"packing" => "Packing", "sealed" => "Sealed"}}
        }
      }
    },
    "relations" => %{
      "in_box" => %{"from" => ["crate"], "to" => ["box"]},
      "in_crate" => %{"from" => ["jar"], "to" => ["crate"]},
      "signed_by" => %{"from" => ["box", "crate"], "to" => ["clerk"]},
      "on_jar" => %{"from" => ["label"], "to" => ["jar"]},
      "also_on" => %{"from" => ["jar"], "to" => ["label"]}
    }
  }

  defp fact(key, properties, links \\ %{}),
    do: %{key: key, properties: properties, links: links, version: nil}

  defp plain_progress(kind, facts, lists) do
    {:ok, annotated} =
      Derived.annotate(@description, kind, facts, fn of -> {:ok, lists[of] || []} end)

    Enum.map(annotated, & &1.progress)
  end

  # A shipped jar has a label pointing at it that says it was sent.
  defp jar(key, crate, phase, shipped \\ false) do
    links = %{"in_crate" => [crate]}
    jar = fact(key, %{"phase" => phase}, links)
    if shipped, do: Map.put(jar, :shipped, true), else: jar
  end

  defp labels(jars),
    do:
      for(
        %{shipped: true} = jar <- jars,
        do: fact("L-" <> jar.key, %{"state" => "sent"}, %{"on_jar" => [jar.key]})
      )

  defp progress(kind, facts, lists) do
    jars = lists["jar"] || []
    lists = Map.update(lists, "label", labels(jars), &(&1 ++ labels(jars)))
    plain_progress(kind, facts, lists)
  end

  test "the least far child wins, with how many are that far, of all of them" do
    jars = [
      jar("J-1", "C-1", "sealed"),
      jar("J-2", "C-1", "packing"),
      jar("J-3", "C-1", "sealed")
    ]

    assert [%{"value" => "packing", "label" => "Packing", "count" => 1, "of" => 3}] =
             progress("crate", [fact("C-1", %{"group" => "agreed"})], %{"jar" => jars})

    jars = [jar("J-1", "C-1", "sealed"), jar("J-2", "C-1", "sealed")]

    assert [%{"value" => "sealed", "count" => 2, "of" => 2}] =
             progress("crate", [fact("C-1", %{"group" => "agreed"})], %{"jar" => jars})
  end

  test "every child done: to test, until it is completed itself; then done" do
    jars = [jar("J-1", "C-1", "sealed", true), jar("J-2", "C-1", "packing", true)]

    assert [%{"value" => "check", "label" => "Check", "count" => 2, "of" => 2} = to_test] =
             progress("crate", [fact("C-1", %{})], %{"jar" => jars})

    refute Map.has_key?(to_test, "done")
    signed = fact("C-1", %{}, %{"signed_by" => ["K-1"]})

    assert [%{"done" => true, "label" => "Shipped", "count" => 2, "of" => 2}] =
             progress("crate", [signed], %{"jar" => jars})

    jars = [jar("J-1", "C-1", "sealed", true), jar("J-2", "C-1", "packing")]

    assert [%{"value" => "packing", "count" => 1, "of" => 2}] =
             progress("crate", [fact("C-1", %{})], %{"jar" => jars})
  end

  test "without children: its own value, without a count; or nothing" do
    assert [%{"value" => "agreed", "label" => "Agreed"} = own, nil, %{"done" => true}] =
             progress(
               "crate",
               [
                 fact("C-1", %{"group" => "agreed"}),
                 fact("C-2", %{}),
                 fact("C-3", %{}, %{"signed_by" => ["K-1"]})
               ],
               %{"jar" => [jar("J-1", "C-9", "sealed")]}
             )

    refute Map.has_key?(own, "count")
  end

  test "a parent rolls up its children's progress, which rolls up theirs" do
    crates = [
      fact("C-1", %{"group" => "agreed"}, %{"in_box" => ["B-1"]}),
      fact("C-2", %{"group" => "draft"}, %{"in_box" => ["B-1"]}),
      fact("C-3", %{"group" => "draft"}, %{"in_box" => ["B-2"]})
    ]

    jars = [jar("J-1", "C-1", "sealed"), jar("J-2", "C-3", "packing")]
    boxes = [fact("B-1", %{}), fact("B-2", %{"group" => "draft"})]

    # C-2 has no jars, so it is only as far as its own group: draft, before any phase.
    assert [
             %{"value" => "draft", "label" => "Draft", "count" => 1, "of" => 2},
             %{"value" => "packing", "count" => 1, "of" => 1}
           ] = progress("box", boxes, %{"crate" => crates, "jar" => jars})
  end

  test "a parent is never completed because its children are" do
    jars = [jar("J-1", "C-1", "sealed", true)]
    crates = [fact("C-1", %{}, %{"in_box" => ["B-1"]})]

    # The crate's jars are all shipped: the crate is to test, the box only as far as it.
    assert [%{"value" => "check", "count" => 1, "of" => 1}] =
             progress("box", [fact("B-1", %{})], %{"crate" => crates, "jar" => jars})

    signed = [fact("C-1", %{}, %{"in_box" => ["B-1"], "signed_by" => ["K-1"]})]

    assert [%{"value" => "check", "count" => 1, "of" => 1}] =
             progress("box", [fact("B-1", %{})], %{"crate" => signed, "jar" => jars})
  end

  test "completion: why a fact is completed, by a link, a fact pointing at it, or one it points at" do
    sent = fact("L-1", %{"state" => "sent"}, %{"on_jar" => ["J-1"]})
    draft = fact("L-2", %{"state" => "draft"}, %{"on_jar" => ["J-2"]})
    other = fact("L-3", %{"state" => "sent"})

    jars = [
      fact("J-1", %{}),
      fact("J-2", %{}),
      fact("J-3", %{}, %{"also_on" => ["L-3"]})
    ]

    {:ok, annotated} =
      Derived.annotate(@description, "jar", jars, fn
        "label" -> {:ok, [sent, draft, other]}
        _ -> {:ok, []}
      end)

    assert [
             %{"over" => "on_jar", "key" => "L-1", "value" => "sent"},
             nil,
             %{"through" => "also_on", "key" => "L-3"}
           ] = Enum.map(annotated, & &1.completion)

    refute Map.has_key?(hd(annotated), :progress)

    {:ok, [crate]} =
      Derived.annotate(@description, "crate", [fact("C-1", %{}, %{"signed_by" => ["K-1"]})], fn
        _ -> {:ok, []}
      end)

    assert crate.completion == %{"done" => true, "by" => "signed_by", "keys" => ["K-1"]}
  end

  test "while a label on it is pending, a jar shows packing; nothing stored, why said" do
    description =
      put_in(@description, ["entities", "jar", "progress"], %{
        "own" => "phase",
        "while" => [
          %{"over" => "on_jar", "field" => "state", "value" => "pending", "shows" => "packing"}
        ]
      })

    pending = fact("L-1", %{"state" => "pending"}, %{"on_jar" => ["J-1"]})
    dropped = fact("L-2", %{"state" => "dropped"}, %{"on_jar" => ["J-2"]})
    jars = [fact("J-1", %{"phase" => "draft"}), fact("J-2", %{"phase" => "draft"})]

    {:ok, [one, two]} =
      Derived.annotate(description, "jar", jars, fn
        "label" -> {:ok, [pending, dropped]}
        _ -> {:ok, []}
      end)

    assert %{
             "value" => "packing",
             "label" => "Packing",
             "while" => %{"over" => "on_jar", "key" => "L-1"}
           } =
             one.progress

    # A label no longer pending does not count: its own phase again.
    assert two.progress == %{"value" => "draft", "label" => "draft"}

    # A crate rolls up what its jars show.
    jars = [fact("J-1", %{"phase" => "draft"}, %{"in_crate" => ["C-1"]})]

    {:ok, [crate]} =
      Derived.annotate(description, "crate", [fact("C-1", %{})], fn
        "label" -> {:ok, [pending]}
        "jar" -> {:ok, jars}
        _ -> {:ok, []}
      end)

    assert %{"value" => "packing", "count" => 1, "of" => 1} = crate.progress
  end

  test "a kind without a rule is left as it is, and nothing is read" do
    facts = [fact("L-1", %{"state" => "sent"})]

    assert {:ok, ^facts} =
             Derived.annotate(@description, "label", facts, fn _ -> raise "read" end)
  end

  test "when the children cannot be read, neither can the progress" do
    assert {:error, :unavailable} =
             Derived.annotate(@description, "crate", [fact("C-1", %{})], fn _ ->
               {:error, :unavailable}
             end)
  end

  # A review in an item shows what the item is doing while it is open, a merged one
  # completes it, and the box rolls up its items; the rule shapes are those of
  # `rela/atlas.json`, with neutral kinds.
  @reviewed %{
    "progress" => %{
      "order" => [
        "refine",
        "ready_to_pick_up",
        "specification",
        "design",
        "development",
        "to_test"
      ],
      "done_label" => "Done",
      "to_test" => %{"value" => "to_test", "label" => "To test"}
    },
    "entities" => %{
      "box" => %{
        "plural" => "boxes",
        "progress" => %{"over" => "in_box", "field" => "stage", "own" => "status"},
        "completion" => %{"by" => "approved_by"}
      },
      "item" => %{
        "plural" => "items",
        "progress" => %{
          "own" => "stage",
          "while" => [
            %{
              "over" => "in_item",
              "field" => "state",
              "value" => "open",
              "shows" => "development"
            }
          ]
        },
        "completion" => [
          %{"over" => "in_item", "field" => "state", "value" => "merged"},
          %{"through" => "done_in", "field" => "state", "value" => "merged"}
        ],
        "properties" => %{
          "stage" => %{
            "labels" => %{
              "specification" => "Specification",
              "design" => "Design",
              "development" => "Development"
            }
          }
        }
      },
      "review" => %{"plural" => "reviews"}
    },
    "relations" => %{
      "in_box" => %{"from" => ["item"], "to" => ["box"]},
      "in_item" => %{"from" => ["review"], "to" => ["item"]},
      "done_in" => %{"from" => ["item"], "to" => ["review"]},
      "approved_by" => %{"from" => ["box"], "to" => ["member"]}
    }
  }

  # `fact` of `kind`, with I-1 (specification, in B-1) and one review in it, in
  # `review_state`.
  defp reviewed(kind, fact, review_state) do
    review = fact("R-12", %{"state" => review_state}, %{"in_item" => ["I-1"]})

    {:ok, [annotated]} =
      Derived.annotate(@reviewed, kind, [fact], fn
        "item" -> {:ok, [item()]}
        "review" -> {:ok, [review]}
        _ -> {:ok, []}
      end)

    annotated
  end

  defp item, do: fact("I-1", %{"stage" => "specification"}, %{"in_box" => ["B-1"]})
  defp box, do: fact("B-1", %{"status" => "refine"})

  test "an open review shows its item in development, naming the review; stage kept" do
    open = reviewed("item", item(), "open")

    assert %{
             "value" => "development",
             "label" => "Development",
             "while" => %{"over" => "in_item", "key" => "R-12", "value" => "open"}
           } = open.progress

    assert open.completion == nil
    assert open.properties["stage"] == "specification"

    assert %{"value" => "development", "count" => 1, "of" => 1} =
             reviewed("box", box(), "open").progress
  end

  test "a review closed unmerged gives the item back its own stage" do
    closed = reviewed("item", item(), "closed")

    assert closed.progress == %{"value" => "specification", "label" => "Specification"}
    assert closed.completion == nil
  end

  test "a merged review makes the item done, naming it; the box to test 1/1" do
    merged = reviewed("item", item(), "merged")

    assert %{"done" => true, "label" => "Done"} = merged.progress

    assert %{"over" => "in_item", "key" => "R-12", "value" => "merged"} = merged.completion

    box = reviewed("box", box(), "merged")

    assert %{"value" => "to_test", "label" => "To test", "count" => 1, "of" => 1} =
             box.progress

    refute Map.has_key?(box.progress, "done")
    assert box.completion == nil
  end
end
