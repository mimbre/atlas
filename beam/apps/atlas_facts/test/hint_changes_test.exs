defmodule AtlasFacts.HintChangesTest do
  # What a `stored` hint says the write changed (docs/design/page-freshness.md §1.2): one
  # entry per fact, what the write brought along (components, replaced facts) included.
  use ExUnit.Case, async: false

  alias AtlasBus.Envelope
  alias AtlasFacts.FakeRela

  defmodule Changing do
    @moduledoc """
    The workshop, where a widget has a tag made and deleted with it (a component) and a
    dark widget that succeeds others lights them in the same write.
    """
    use AtlasFacts.TestModel,
      description:
        AtlasFacts.Workshop.Description.with(%{
          "entities" => %{
            "tag" => %{"plural" => "tags", "properties" => %{"title" => %{"type" => "string"}}},
            "widget" => %{
              "replaces" => %{
                "relation" => "succeeds",
                "when" => %{"shade" => ["dark"]},
                "of" => %{"shade" => ["dark", "light"]},
                "set" => %{"shade" => "light"},
                "error" => "{key} is not dark"
              }
            }
          },
          "relations" => %{
            "succeeds" => %{"from" => ["widget"], "to" => ["widget"]},
            "tagged" => %{
              "from" => ["widget"],
              "to" => ["tag"],
              "max_outgoing" => 1,
              "component" => %{"key" => "T-{key}", "values" => %{"title" => "{key}"}}
            }
          }
        })
  end

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    Application.put_env(:atlas_bus, :store, "hint-changes-#{System.unique_integer([:positive])}")
    rela = FakeRela.start(Changing)
    start_supervised!({AtlasFacts.Server, rela: {FakeRela, rela}, data_dir: dir, model: Changing})
    :ok = AtlasBus.attach("tester-#{System.unique_integer([:positive])}")
    %{rela: rela}
  end

  defp fact(kind, op, key, values, opts \\ []) do
    envelope = Envelope.new("fact", kind, Keyword.take(opts, [:id]))
    content = %{"op" => op, "key" => key, "values" => values}
    content = if opts[:links], do: Map.put(content, "links", opts[:links]), else: content
    :ok = AtlasBus.send(envelope, content)
    id = envelope.id
    assert_receive {:atlas_bus, %Envelope{id: ^id, class: class}, answer}, 1_000
    {class, answer}
  end

  defp changes(kind, op, key, values, opts \\ []) do
    {"stored", answer} = fact(kind, op, key, values, opts)
    answer["changes"]
  end

  defp entry(kind, key, op, fields, relinked \\ [], links \\ %{}),
    do: %{
      "kind" => kind,
      "key" => key,
      "op" => op,
      "fields" => fields,
      "relinked" => relinked,
      "links" => links
    }

  test "a create names the fields it sets and the links it makes" do
    assert changes("widget", "create", "W-0", %{"title" => "Zero", "shade" => ""}) ==
             [
               entry("widget", "W-0", "create", ["title"], ["tagged"], %{"tagged" => ["T-W-0"]}),
               entry("tag", "T-W-0", "create", ["title"])
             ]

    assert [part] =
             changes("part", "create", "P-1", %{"title" => "One"},
               links: %{"of_widget" => ["W-0"]}
             )

    assert part ==
             entry("part", "P-1", "create", ["title"], ["of_widget"], %{"of_widget" => ["W-0"]})
  end

  test "a change names only what differs; its links say what it hangs under, before ∪ after" do
    changes("widget", "create", "W-0", %{"title" => "Zero"})
    changes("widget", "create", "W-1", %{"title" => "One"})
    changes("part", "create", "P-1", %{"title" => "Part"}, links: %{"of_widget" => ["W-0"]})

    # Its own field only: the parent it hangs under is still named, so the parent's page
    # that lists its children sees the change.
    assert changes("part", "change", "P-1", %{"title" => "Renamed"}) ==
             [entry("part", "P-1", "change", ["title"], [], %{"of_widget" => ["W-0"]})]

    # Set to what it is, and something else: only what differs.
    assert changes("widget", "change", "W-0", %{"title" => "Zero", "shade" => "light"}) ==
             [entry("widget", "W-0", "change", ["shade"], [], %{"tagged" => ["T-W-0"]})]

    # Moved: relinked, with the old parent and the new one.
    assert changes("part", "change", "P-1", %{}, links: %{"of_widget" => ["W-1"]}) ==
             [
               entry("part", "P-1", "change", [], ["of_widget"], %{
                 "of_widget" => ["W-0", "W-1"]
               })
             ]

    # Nothing differs: nothing changed.
    assert changes("part", "change", "P-1", %{"title" => "Renamed"}) == []
  end

  test "a write that replaces facts names each fact it set, after its own" do
    changes("widget", "create", "W-1", %{"title" => "Old", "shade" => "dark"})

    assert changes("widget", "create", "W-2", %{"title" => "New", "shade" => "dark"},
             links: %{"succeeds" => ["W-1"]}
           ) == [
             entry("widget", "W-2", "create", ["shade", "title"], ["succeeds", "tagged"], %{
               "succeeds" => ["W-1"],
               "tagged" => ["T-W-2"]
             }),
             entry("tag", "T-W-2", "create", ["title"]),
             entry("widget", "W-1", "change", ["shade"], [], %{"tagged" => ["T-W-1"]})
           ]
  end

  test "a delete names the fact it removed and its components" do
    changes("widget", "create", "W-5", %{"title" => "Five"})

    assert changes("widget", "delete", "W-5", %{}) == [
             entry("widget", "W-5", "delete", ["title"], ["tagged"], %{"tagged" => ["T-W-5"]}),
             entry("tag", "T-W-5", "delete", ["title"])
           ]

    # Gone already: nothing removed now.
    assert changes("widget", "delete", "W-5", %{}) == []
  end

  test "a resent id gets the same changes again; a refusal names none" do
    id = "resent-#{System.unique_integer([:positive])}"
    first = changes("widget", "create", "W-7", %{"title" => "Seven"}, id: id)
    assert [%{"key" => "W-7"}, %{"key" => "T-W-7"}] = first
    assert changes("widget", "create", "W-7", %{"title" => "Seven"}, id: id) == first

    assert {"refused", refusal} = fact("widget", "create", "X-1", %{"title" => "Bad prefix"})
    refute Map.has_key?(refusal, "changes")
  end
end
