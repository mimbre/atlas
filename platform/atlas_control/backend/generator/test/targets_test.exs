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
    test "the contract as JSON, the same as the golden file" do
      assert [{"blocks.json", body}] =
               AtlasBFF.Targets.Json.files(AtlasBFF.Example.__schema__())

      assert body == File.read!("test/golden/blocks.json")
    end
  end

  defp compile(call) do
    Code.compile_string("""
    defmodule Caller#{System.unique_integer([:positive])} do
      require AtlasBFF.Example.Server, as: Server
      def page, do: #{call}
    end
    """)
  end
end
