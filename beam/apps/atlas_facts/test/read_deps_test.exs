defmodule AtlasFacts.ReadDepsTest do
  # What a read answer says it depended on (`deps`) and when a value in it changes by time
  # alone (`until`): docs/design/page-freshness.md §1.1.
  use ExUnit.Case, async: false

  alias AtlasBus.Envelope

  defmodule Reading do
    @moduledoc """
    The workshop, where how far a widget is comes from its parts and a widget with
    something to do is late once its due time has passed.
    """
    use AtlasFacts.TestModel,
      description:
        AtlasFacts.Workshop.Description.with(%{
          "progress" => %{"order" => ["rough", "fine"]},
          "entities" => %{
            "part" => %{"properties" => %{"phase" => %{"type" => "string"}}},
            "widget" => %{
              "progress" => %{"over" => "of_widget", "field" => "phase"},
              "late" => %{"after" => "due", "while" => "todo"},
              "properties" => %{"due" => %{"type" => "string"}, "todo" => %{"type" => "string"}}
            }
          }
        })
  end

  # rela with a few facts of each kind, read only.
  defmodule Store do
    @facts %{
      "widgets" => [
        # Not late yet: it turns late just after its due time.
        %{
          key: "W-1",
          properties: %{"title" => "One", "due" => "2999-01-01T00:00:00Z", "todo" => "Fix"},
          links: %{}
        },
        %{
          key: "W-2",
          properties: %{"title" => "Two", "due" => "2000-01-01T00:00:00Z", "todo" => ""},
          links: %{"made_by" => ["M-1"]}
        },
        # Late already: time alone changes nothing any more.
        %{
          key: "W-3",
          properties: %{"title" => "Three", "due" => "2000-01-01T00:00:00Z", "todo" => "Fix"},
          links: %{}
        }
      ],
      "parts" => [
        %{key: "P-1", properties: %{"phase" => "rough"}, links: %{"of_widget" => ["W-1"]}},
        %{key: "P-2", properties: %{"phase" => "fine"}, links: %{"of_widget" => ["W-2"]}}
      ],
      "makers" => [%{key: "M-1", properties: %{"title" => "Mia"}, links: %{}}]
    }

    def description(up),
      do: if(Agent.get(up, & &1), do: {:ok, Reading.rela_schema()}, else: {:error, :unavailable})

    def list(up, plural),
      do: answer(up, {:ok, Enum.map(@facts[plural] || [], &Map.put(&1, :version, nil))})

    def get(up, plural, key) do
      case Enum.find(@facts[plural] || [], &(&1.key == key)) do
        nil -> answer(up, {:error, :not_found})
        fact -> answer(up, {:ok, Map.put(fact, :version, "v1")})
      end
    end

    def incoming(up, _plural, key, relation) do
      keys = for {_, facts} <- @facts, f <- facts, key in (f.links[relation] || []), do: f.key
      answer(up, {:ok, keys})
    end

    defp answer(up, result), do: if(Agent.get(up, & &1), do: result, else: {:error, :unavailable})
  end

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    Application.put_env(:atlas_bus, :store, "read-deps-#{System.unique_integer([:positive])}")
    up = start_supervised!({Agent, fn -> true end})

    start_supervised!(
      {AtlasFacts.Server,
       rela: {Store, up}, model: Reading, data_dir: dir, collection_freshness_ms: 0}
    )

    # Page reads are Control's.
    :ok = AtlasBus.attach("control/read-deps-#{System.unique_integer([:positive])}")
    %{up: up}
  end

  defp read(kind, content \\ %{}) do
    envelope = Envelope.new("read", kind)
    :ok = AtlasBus.send(envelope, content)
    id = envelope.id
    assert_receive {:atlas_bus, %Envelope{id: ^id, class: "answer"}, answer}, 1_000
    answer
  end

  test "a whole-kind read depends on the kind, each fact in it, and what its progress reads" do
    answer = read("widget")

    assert answer["deps"] == [
             ["key", "widget", "W-1", "*"],
             ["key", "widget", "W-2", "*"],
             ["key", "widget", "W-3", "*"],
             ["kind", "part"],
             ["kind", "widget"]
           ]

    # W-1 turns late just after its due time; W-2 has nothing to do, W-3 is late already.
    assert answer["until"] == "2999-01-01T00:00:00.000001Z"
  end

  test "a linked read depends on what points at the key, and on each fact it returns" do
    answer = read("part", %{"linked" => %{"of_widget" => "W-1"}})
    assert [%{"key" => "P-1"}] = answer["facts"]
    assert answer["deps"] == [["key", "part", "P-1", "*"], ["linked", "of_widget", "W-1", "*"]]
    refute Map.has_key?(answer, "until")

    # One step on: the parts of the widgets that M-1 made. Which widgets those are is
    # what points at M-1; which parts, what points at each of them.
    answer = read("part", %{"linked" => %{"of_widget" => %{"made_by" => "M-1"}}})
    assert [%{"key" => "P-2"}] = answer["facts"]

    assert answer["deps"] == [
             ["key", "part", "P-2", "*"],
             ["linked", "made_by", "M-1", "*"],
             ["linked", "of_widget", "W-2", "*"]
           ]
  end

  test "one fact depends on itself, what points at it and what its progress reads" do
    answer = read("widget", %{"key" => "W-1"})
    assert answer["incoming"] == %{"of_widget" => ["P-1"]}

    assert answer["deps"] == [
             ["key", "widget", "W-1", "*"],
             ["kind", "part"],
             ["linked", "of_widget", "W-1", "*"]
           ]

    assert answer["until"] == "2999-01-01T00:00:00.000001Z"
    assert read("widget", %{"key" => "W-3"})["until"] == nil

    # A plain read: the fact only. One not found depends on it too: a later create
    # is a change of it.
    assert read("part", %{"key" => "P-1", "plain" => true})["deps"] == [
             ["key", "part", "P-1", "*"]
           ]

    assert %{"fact" => nil, "deps" => [["key", "widget", "W-9", "*"]]} =
             read("widget", %{"key" => "W-9", "plain" => true})
  end

  test "a page has one position, and each of its answers says what it depended on" do
    page = read("_page", %{"reads" => [["widget", %{}], ["part", %{}]]})
    [widgets, parts] = page["answers"]
    assert widgets == read("widget")
    assert parts == read("part")
    assert widgets["position"] == parts["position"] and parts["position"] == page["position"]
    assert ["kind", "widget"] in widgets["deps"]

    assert parts["deps"] == [
             ["key", "part", "P-1", "*"],
             ["key", "part", "P-2", "*"],
             ["kind", "part"]
           ]

    assert widgets["until"] == "2999-01-01T00:00:00.000001Z"
    refute Map.has_key?(parts, "until")
  end

  test "a page of mixed reads answers each as it alone would, in order, at one position" do
    reads = [
      ["widget", %{"key" => "W-1"}],
      ["part", %{"linked" => %{"of_widget" => "W-1"}}],
      ["maker", %{}],
      ["part", %{"key" => "P-2", "plain" => true}]
    ]

    page = read("_page", %{"reads" => reads})
    alone = for [kind, content] <- reads, do: read(kind, content)
    assert page["answers"] == alone
    assert [p] = page["answers"] |> Enum.map(& &1["position"]) |> Enum.uniq()
    assert p == page["position"]

    assert Enum.at(page["answers"], 1)["deps"] == [
             ["key", "part", "P-1", "*"],
             ["linked", "of_widget", "W-1", "*"]
           ]
  end

  test "the description and an answer that is an error depend on nothing", %{up: up} do
    refute Map.has_key?(read("_description"), "deps")
    Agent.update(up, fn _ -> false end)
    answer = read("part", %{"key" => "P-1", "plain" => true})
    assert answer["error_kind"] == "unreachable"
    refute Map.has_key?(answer, "deps")
  end
end
