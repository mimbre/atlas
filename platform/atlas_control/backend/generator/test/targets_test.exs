defmodule AtlasBFF.TargetsTest do
  use ExUnit.Case, async: true

  require AtlasBFF.Example.Server, as: Server
  alias AtlasBFF.Example.Client

  describe "server (compile time)" do
    test "builders check blocks and models; an optional prop without a value is left out" do
      assert %{"type" => "card", "props" => props} =
               Server.card(title: "T", count: nil, links: [Server.link(label: "a", to: "/a")])

      assert props == %{"title" => "T", "links" => [%{"label" => "a", "to" => "/a"}]}

      # Props only known at run time are checked when the block is built.
      missing = [count: 1]
      assert_raise ArgumentError, ~r/card.title is required/, fn -> Server.card(missing) end
      assert_raise ArgumentError, ~r/card.title is required/, fn -> Server.card(title: nil) end

      assert_raise ArgumentError, ~r/must be "integer"/, fn ->
        Server.card(title: "T", count: "1")
      end

      unknown = [text: "x", colour: "red"]
      assert_raise ArgumentError, ~r/no field/, fn -> Server.note(unknown) end
    end

    test "markup builders take a stretch, props and a group" do
      assert %{"kind" => "group", "start" => "a", "end" => "b", "props" => %{"title" => "T"}} =
               Server.group("a", "b", title: "T")

      assert %{"group" => "g", "props" => %{"shade" => "x"}} =
               Server.tint("a", "a", shade: "x", group: "g")

      refute Map.has_key?(Server.tint("a", "a"), "group")
    end

    test "a view model gives each block its id and refuses markup that does not nest" do
      note = Server.note(text: "x")
      two = [{"a", note}, {"b", note}]

      assert %{blocks: [%{"id" => "a", "type" => "note"}, %{"id" => "b"}], markup: [_]} =
               Server.view_model(two, [Server.tint("a", "b")])

      assert_raise ArgumentError, ~r/cross; markup must nest/, fn ->
        Server.view_model(two ++ [{"c", note}], [
          Server.group("a", "b", title: "x"),
          Server.tint("b", "c")
        ])
      end

      assert_raise ArgumentError, ~r/used twice/, fn ->
        Server.view_model([{"a", note}, {"a", note}])
      end
    end

    test "a builder call with a missing or unknown prop fails at compile time" do
      assert_raise CompileError, ~r/card.title is required/, fn ->
        compile("Server.card(count: 1)")
      end

      assert_raise CompileError, ~r/note has no field\(s\) \["colour"\]/, fn ->
        compile(~s|Server.note(text: "x", colour: "red")|)
      end

      assert_raise CompileError, ~r/group.title is required/, fn ->
        compile(~s|Server.group("a", "a", group: "g")|)
      end

      assert_raise CompileError, ~r/link.to is required/, fn ->
        compile("Enum.map([1], &Server.link(label: &1))")
      end
    end

    test "the version is the contract's" do
      assert Server.version() == "1.0.0"
    end
  end

  describe "client (compile time)" do
    test "blocks decode into structs; unknown keys are ignored" do
      assert %Client.Card{title: "T", links: [%Client.Link{label: "a", to: "/a"}]} =
               Client.decode(%{
                 "type" => "card",
                 "props" => %{
                   "title" => "T",
                   "links" => [%{"label" => "a", "to" => "/a"}],
                   "new" => 1
                 }
               })
    end

    test "an unknown or broken block becomes a fallback" do
      assert %Client.Fallback{type: "chart", reason: "unknown block"} =
               Client.decode(%{"type" => "chart"})

      assert %Client.Fallback{reason: "card.title is missing"} =
               Client.decode(%{"type" => "card", "props" => %{}})

      assert %Client.Fallback{reason: "card.count has the wrong type"} =
               Client.decode(%{"type" => "card", "props" => %{"title" => "T", "count" => "1"}})

      assert %Client.Fallback{reason: "not a block"} = Client.decode(nil)
    end

    test "a view model: ids, and markup with its props decoded; bad markup is left out" do
      page = %{
        "blocks" => [
          %{"id" => "a", "type" => "note", "props" => %{"text" => "x"}},
          %{"type" => "note"}
        ],
        "markup" => [
          %{"kind" => "group", "start" => "a", "end" => "#1", "props" => %{"title" => "G"}},
          %{"kind" => "sparkle", "start" => "a", "end" => "a"},
          %{"kind" => "group", "start" => "a", "end" => "a", "props" => %{}}
        ]
      }

      assert {[%Client.Note{text: "x"}, %Client.Fallback{}], ["a", "#1"], [entry]} =
               Client.view_model(page)

      assert %{"kind" => "group", "value" => %Client.Group{title: "G"}} = entry

      crossing = %{
        page
        | "blocks" => page["blocks"] ++ [%{"id" => "c", "type" => "note"}],
          "markup" => [
            %{"kind" => "group", "start" => "a", "end" => "#1", "props" => %{"title" => "G"}},
            %{"kind" => "tint", "start" => "#1", "end" => "c"}
          ]
      }

      assert {_, _, []} = Client.view_model(crossing)
    end
  end

  describe "json (a file target)" do
    defp blocks_json do
      assert [{"blocks.json", body}] =
               AtlasBFF.Targets.Json.files(AtlasBFF.Example.__schema__())

      body
    end

    test "keys sorted, indented by two, one trailing newline" do
      body = blocks_json()
      assert body == layout(JSON.decode!(body))
    end

    test "the version, the wire notes and every model, block and kind of markup with its typed fields" do
      json = JSON.decode!(blocks_json())
      schema = AtlasBFF.Example.__schema__()

      assert json["version"] == schema.version
      assert json["protocol"] == []
      assert Map.keys(json["wire"]) |> Enum.sort() == ["block", "markup", "props", "view_model"]

      for {section, entries} <- [
            models: schema.models,
            blocks: schema.blocks,
            markup: schema.markup
          ] do
        assert Enum.map(json[Atom.to_string(section)], & &1["name"]) ==
                 Enum.map(entries, &Atom.to_string(&1.name))
      end

      [link, greeting] = json["models"]
      assert hd(link["fields"]) == %{"name" => "label", "required" => true, "type" => "string"}

      assert List.last(greeting["fields"]) ==
               %{"name" => "tags", "required" => false, "type" => "map of string"}

      card = hd(json["blocks"])

      assert Enum.map(card["fields"], &{&1["name"], &1["type"], &1["required"]}) == [
               {"title", "string", true},
               {"count", "integer", false},
               {"links", "list of link", false}
             ]
    end

    test "pages with their paths and params, and every endpoint with its call and replies" do
      json = JSON.decode!(blocks_json())

      assert json["pages"] == [
               %{
                 "name" => "card",
                 "params" => ["id"],
                 "path" => "/cards/:id",
                 "returns" => "view model"
               },
               %{
                 "name" => "new_card",
                 "params" => [],
                 "path" => "/cards/new",
                 "returns" => "view model"
               },
               %{"name" => "home", "params" => [], "path" => "/", "returns" => "view model"}
             ]

      by = Map.new(json["endpoints"], &{&1["name"], &1})

      assert Enum.map(json["endpoints"], & &1["name"]) == [
               "card",
               "new_card",
               "home",
               "save_card",
               "greet"
             ]

      # A page's open endpoint names its page; a submit takes the form's values.
      assert %{
               "call" => "open",
               "page" => "card",
               "wire" => "open",
               "replies" => %{"page" => "view model"}
             } =
               by["card"]

      assert by["save_card"] == %{
               "call" => "submit",
               "name" => "save_card",
               "params" => ["id"],
               "path" => "/cards/:id",
               "replies" => %{"refused" => "view model", "saved" => "view model"},
               "takes" => "values",
               "wire" => nil
             }

      assert %{
               "call" => "greet",
               "path" => "",
               "takes" => "greeting",
               "replies" => %{"hi" => "greeting"}
             } =
               by["greet"]

      refute Map.has_key?(by["greet"], "page")
    end
  end

  # The layout the file target promises: keys sorted, two spaces per level, a newline at the end.
  defp layout(value), do: IO.iodata_to_binary(layout(value, "")) <> "\n"

  defp layout(map, at) when is_map(map) and map_size(map) > 0 do
    inner =
      for {k, v} <- Enum.sort(map), do: [at, "  ", JSON.encode!(k), ": ", layout(v, at <> "  ")]

    ["{\n", Enum.intersperse(inner, ",\n"), "\n", at, "}"]
  end

  defp layout(list, at) when is_list(list) and list != [] do
    inner = for v <- list, do: [at, "  ", layout(v, at <> "  ")]
    ["[\n", Enum.intersperse(inner, ",\n"), "\n", at, "]"]
  end

  defp layout(value, _at), do: JSON.encode!(value)

  defp compile(call) do
    Code.compile_string("""
    defmodule Caller#{System.unique_integer([:positive])} do
      require AtlasBFF.Example.Server, as: Server
      def page, do: #{call}
    end
    """)
  end
end
