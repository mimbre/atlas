defmodule AtlasTui.ColumnsSidebarTest do
  @moduledoc """
  From 290 cells the tabs leave the bar for a sidebar column left of the list; from 210 the
  tab bar has a row of the active tab's groups (docs/design/apple-clients.md, Layout).
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

    assert text =~ ~r/^  Tabs +│ Assigned to you +│ Widget W-1/mu
    refute text =~ "▸ Assigned to you"
    refute text =~ "┌"

    # Per section its tabs, each with its count, its groups indented under it.
    assert text =~ ~r/^  Work +│/mu
    assert text =~ ~r/^  › Assigned to you +3 ?│/mu
    assert text =~ ~r/^    Supervised by you +5 ?│/mu
    assert text =~ ~r/^      Decisions +2 ?│/mu
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

    # A group opens as its tab does, and becomes the list.
    {model, [{:send, %{"op" => "open", "to" => "/_supervised/decide/open"}}]} =
      Model.key(model, :down)

    model = open_list(model, "/_supervised/decide/open", "Decisions", ["W-3"])
    assert model.columns.list == "/_supervised/decide/open"
    assert screen(model, 300) =~ ~r/^  ›   Decisions +2 ?│/mu

    {model, []} = Model.key(model, :right)
    assert Columns.focus(model) == :list
  end

  test "from 210 to 289 the tab bar has a row of the active tab's groups, with their counts" do
    model = wide(220)
    {model, [{:send, %{"op" => "open", "to" => "/_supervised"}}]} = Model.key(model, :tab)
    model = open_list(model, "/_supervised", "Supervised by you", ["W-3"])

    assert screen(model, 220) =~ ~r/│   Decisions 2 · To-Dos 3 +│\n└/u
    model = put_in(model.console.viewport, {209, 40})
    refute screen(model, 209) =~ "Decisions 2"
  end
end
