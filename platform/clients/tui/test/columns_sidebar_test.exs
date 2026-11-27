defmodule AtlasTui.ColumnsSidebarTest do
  @moduledoc """
  From 290 cells the top-level tabs stand in a sidebar; filters stay on the list.
  """
  use ExUnit.Case, async: true

  alias AtlasTui.{Columns, ConsoleProjectionFixture, Model, View}

  @tabs [
    %{"id" => "assigned", "label" => "Assigned to you", "to" => "/", "count" => 3},
    %{
      "id" => "supervised",
      "label" => "Supervised by you",
      "to" => "/_supervised",
      "count" => 5,
      "groups" => [
        %{"label" => "Decisions", "to" => "/_supervised/decide/open", "count" => 2},
        %{"label" => "To-Dos", "to" => "/_supervised/todo/open", "count" => 3}
      ]
    },
    %{"id" => "kinds", "label" => "Widgets", "to" => "/k/widget", "section" => "browse"}
  ]

  defp list(path, title, keys) do
    rows =
      for key <- keys, do: %{"label" => "Widget #{key}", "id" => key, "to" => "/k/widget/#{key}"}

    %{
      "op" => "page",
      "path" => path,
      "title" => title,
      "reason" => "open",
      "blocks" => [%{"id" => "list", "type" => "list", "props" => %{"rows" => rows}}]
    }
  end

  defp widget(key) do
    %{
      "op" => "page",
      "path" => "/k/widget/#{key}",
      "title" => "Widget #{key}",
      "reason" => "open",
      "blocks" => [
        %{
          "id" => "item",
          "type" => "item",
          "props" => %{"title" => "Widget #{key}", "fields" => []}
        }
      ]
    }
  end

  # The assigned list at `width`, its first row's page open beside it.
  defp wide(width) do
    model = Model.new("test")

    model = %{
      model
      | connected: true,
        console: %{
          model.console
          | phase: :ready,
            stale: false,
            viewport: {width, 40},
            shell: %{"revision" => "fixture", "title" => "Atlas Console", "tabs" => @tabs}
        }
    }

    {model, [{:send, %{"op" => "open", "to" => "/k/widget/W-1"}}]} =
      ConsoleProjectionFixture.receive(model, list("/", "Assigned to you", ["W-1", "W-2"]))

    {model, []} = ConsoleProjectionFixture.receive(model, widget("W-1"))
    model
  end

  defp screen(model, width), do: model |> View.render(width, 40, 5) |> View.plain()

  defp lit(model, width) do
    for line <- View.render(model, width, 40, 5), {:lit, text} <- line, do: text
  end

  # A list arrives; the page of its first row, which it opens at once, too.
  defp open_list(model, path, title, [first | _] = keys) do
    {model, [{:send, %{"op" => "open"}}]} =
      ConsoleProjectionFixture.receive(model, list(path, title, keys))

    {model, []} = ConsoleProjectionFixture.receive(model, widget(first))
    model
  end

  test "from 290 the tabs stand in a sidebar left of the list, and the tab bar goes" do
    model = wide(300)
    assert Columns.sidebar?(model)
    text = screen(model, 300)

    refute text =~ "▸ Assigned to you"
    refute text =~ "┌"

    # Only top-level destinations appear in the sidebar.
    assert text =~ ~r/^  Work +│/mu
    assert text =~ ~r/^  › Assigned to you +3 ?│/mu
    assert text =~ ~r/^    Supervised by you +5 ?│/mu
    refute text =~ "Decisions"
    assert text =~ ~r/^  Browse +│/mu
    assert text =~ ~r/^    Widgets +│/mu

    # Narrower, the sidebar gives way first: the tab bar is back.
    model = put_in(model.console.viewport, {289, 40})
    refute Columns.sidebar?(model)
    assert screen(model, 289) =~ "▸ Assigned to you"
  end

  test "← from the list focuses the sidebar, where ↑/↓ open a tab at once and → goes back" do
    model = wide(300)
    {model, []} = Model.key(model, :left)
    assert Columns.focus(model) == :sidebar
    assert lit(model, 300) == ["Tabs"]
    assert screen(model, 300) =~ ~r/\n ↑↓ Choose · → List · \? Keys\n/u

    {model, [{:send, %{"op" => "open", "to" => "/_supervised"}}]} = Model.key(model, :down)
    model = open_list(model, "/_supervised", "Supervised by you", ["W-3"])
    assert model.columns.list == "/_supervised"
    assert Columns.focus(model) == :sidebar
    assert screen(model, 300) =~ ~r/^  › Supervised by you +5 ?│/mu

    {model, []} = Model.key(model, :right)
    assert Columns.focus(model) == :list
  end

  # The supervised list as Control sends it: its groups line, then a titled list.
  defp grouped(model) do
    groups = [
      %{"label" => "Decisions", "count" => 2, "to" => "/_supervised/decide/open"},
      %{"label" => "To-Dos", "count" => 3, "to" => "/_supervised/todo/open"}
    ]

    rows = [%{"label" => "Widget W-3", "id" => "W-3", "to" => "/k/widget/W-3"}]

    page = %{
      list("/_supervised", "Supervised by you", ["W-3"])
      | "blocks" => [
          %{
            "id" => "groups",
            "type" => "groups",
            "props" => %{
              "groups" => groups,
              "actions" => [
                %{"key" => "]", "label" => "Next group", "to" => "/_supervised/decide/open"},
                %{"key" => "[", "label" => "Previous group", "to" => "/_supervised/todo/open"}
              ]
            }
          },
          %{"id" => "list", "type" => "list", "props" => %{"title" => "Design", "rows" => rows}}
        ]
    }

    {model, [{:send, %{"op" => "open"}}]} = ConsoleProjectionFixture.receive(model, page)
    {model, []} = ConsoleProjectionFixture.receive(model, widget("W-3"))
    model
  end

  test "filters appear once in the list at every column width" do
    for width <- [160, 220, 250, 300] do
      model = wide(width)
      {model, [{:send, %{"op" => "open", "to" => "/_supervised"}}]} = Model.key(model, :tab)
      text = screen(grouped(model), width)
      assert length(Regex.scan(~r/\[Decisions 2\]/u, text)) == 1
      assert text =~ "[To-Dos 3]"
    end
  end

  test "group bindings work from the list beside an open page at each column width" do
    for width <- [160, 220, 300],
        {key, to} <- [
          {"]", "/_supervised/decide/open"},
          {"[", "/_supervised/todo/open"}
        ] do
      model = wide(width)
      {model, [{:send, %{"op" => "open", "to" => "/_supervised"}}]} = Model.key(model, :tab)
      model = grouped(model)
      assert Columns.focus(model) == :list
      assert {_, [{:send, %{"op" => "open", "to" => ^to}}]} = Model.key(model, {:char, key})
    end
  end

  test "a list's group heading is plain: bold title, dim count, no box lines" do
    model = wide(250)
    {model, [{:send, %{"op" => "open", "to" => "/_supervised"}}]} = Model.key(model, :tab)
    rows = View.render(grouped(model), 250, 40, 5)

    [heading] = Enum.filter(rows, &Enum.member?(&1, {:bold, "Design"}))
    assert Enum.member?(heading, {:dim, " · 1"})
    [before | _] = String.split(View.plain([heading]), "Design")
    refute before =~ ~r/[┌┐└┘─│]/u
    refute View.plain(rows) =~ ~r/[┌└]─* ?Design/u
  end
end
