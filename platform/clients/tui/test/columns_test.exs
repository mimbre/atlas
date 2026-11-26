defmodule AtlasTui.ColumnsTest do
  @moduledoc """
  On a wide terminal the TUI shows the tab's list, the page of the row selected in it and
  that page's details as columns (docs/design/apple-clients.md, Columns in the TUI).
  """
  use ExUnit.Case, async: true

  alias AtlasTui.{Columns, ConsoleProjectionFixture, Keys, Model, View}

  @tabs [
    %{"id" => "assigned", "label" => "Assigned to you", "to" => "/", "section" => "work"},
    %{
      "id" => "supervised",
      "label" => "Supervised by you",
      "to" => "/_supervised",
      "section" => "work"
    }
  ]

  defp assigned do
    rows =
      for n <- 1..3,
          do: %{"label" => "Widget #{n}", "id" => "W-#{n}", "to" => "/k/widget/W-#{n}"}

    %{
      "op" => "page",
      "path" => "/",
      "title" => "Assigned to you",
      "reason" => "open",
      "blocks" => [%{"id" => "list", "type" => "list", "props" => %{"rows" => rows}}]
    }
  end

  defp supervised do
    %{
      "op" => "page",
      "path" => "/_supervised",
      "title" => "Supervised by you",
      "reason" => "open",
      "blocks" => [%{"type" => "list", "props" => %{"rows" => []}}]
    }
  end

  # A fact its owner decides on: what to do with it, then its details with what it refers
  # to (`parts`: its related items).
  defp widget(key, parts \\ ["P-1", "P-2"]) do
    %{
      "op" => "page",
      "path" => "/k/widget/#{key}",
      "title" => "Widget #{key}",
      "reason" => "open",
      "blocks" => [
        %{
          "id" => "head",
          "type" => "item",
          "props" => %{
            "title" => "Decide on widget #{key}",
            "fields" => [],
            "actions" => [%{"label" => "Edit", "key" => "e", "to" => "/k/widget/#{key}/edit"}]
          }
        },
        %{
          "id" => "item",
          "type" => "item",
          "props" => %{
            "title" => "Widget #{key}",
            "fields" => [%{"label" => "Key", "value" => key}]
          }
        },
        %{
          "id" => "list:parts",
          "type" => "list",
          "props" => %{
            "rows" =>
              for(p <- parts, do: %{"label" => "Part #{p}", "id" => p, "to" => "/k/part/#{p}"})
          }
        }
      ],
      "markup" => [
        %{
          "kind" => "part",
          "start" => "item",
          "end" => "list:parts",
          "props" => %{"title" => "Details", "role" => "details"}
        },
        %{
          "kind" => "section",
          "start" => "list:parts",
          "end" => "list:parts",
          "props" => %{"title" => "Parts"}
        }
      ]
    }
  end

  defp start(width) do
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

    ConsoleProjectionFixture.receive(model, assigned())
  end

  # The list on a wide screen, with the first row's page open beside it.
  defp wide(width \\ 220, page \\ widget("W-1")) do
    {model, [{:send, %{"op" => "open", "to" => "/k/widget/W-1"}}]} = start(width)
    {model, []} = ConsoleProjectionFixture.receive(model, page)
    model
  end

  defp press(model, keys) when is_list(keys) do
    Enum.reduce(keys, {model, []}, fn key, {model, effects} ->
      {model, more} = Model.key(model, key)
      {model, effects ++ more}
    end)
  end

  defp screen(model, width \\ 220), do: model |> View.render(width, 40, 5) |> View.plain()
  defp selected_to(model), do: Enum.at(Model.rows(model), model.selected).to

  # The lit heading: the one of the column with the focus.
  defp lit(model, width \\ 220) do
    for line <- View.render(model, width, 40, 5), {:lit, text} <- line, do: text
  end

  test "columns by width: four from 290, three from 210, list and page from 144, one below" do
    assert Columns.layout(143) == :one
    assert Columns.layout(144) == :two
    assert Columns.layout(209) == :two
    assert Columns.layout(210) == :three
    assert Columns.layout(289) == :three
    assert Columns.layout(290) == :four

    # One thin line between two columns, and nothing else: no frames.
    three = screen(wide(220))
    assert three =~ ~r/^  Assigned to you +│ Widget W-1 +│ Details\n/mu
    assert three =~ ~r/^   › W-1  Widget 1 .*│  Decide on widget W-1 .*│  Widget W-1/mu
    assert three =~ ~r/│  › P-1  Part P-1\n/u
    refute three =~ ~r/[┌┐└┘]─* ?Assigned/u

    two = screen(wide(160), 160)
    assert two =~ ~r/^  Assigned to you +│ Widget W-1\n/mu
    refute two =~ "│ Details"

    assert two =~
             ~r/│  Decide on widget W-1\n(.*\n)+.*│ +Details\n(.*\n)+.*│ +› P-1  Part P-1/u

    {one, []} = start(143)
    assert one.path == "/"
    refute screen(one, 143) =~ "│ Widget"
  end

  test "the layout rule: columns from the left, one right after the other, the rest at the far right" do
    for width <- [144, 160, 199, 210, 220, 260, 289, 290, 300, 400] do
      columns = Columns.geometry(width)
      [{_, 0, _} | _] = columns

      # Adjacent: each starts where the one before it ends.
      for {{_, x, w}, {_, next, _}} <- Enum.zip(columns, tl(columns)), do: assert(next == x + w)

      {:page, _, page} = List.keyfind(columns, :page, 0)
      assert page <= 100
      # The last column takes the room up to its most (100); what is left is past it.
      {_, x, w} = List.last(columns)
      assert x + w == min(width, x + 100)

      # The details beside the page when there is room, 40 to 100 wide; else under it.
      case List.keyfind(columns, :details, 0) do
        {:details, _, details} -> assert width >= 210 and page == 100 and details in 40..100
        nil -> assert width < 210
      end

      assert Enum.map(columns, &elem(&1, 0)) ==
               if(width >= 290, do: [:sidebar], else: []) ++
                 [:list, :page] ++ if(width >= 210, do: [:details], else: [])
    end

    # One column: the page from the left edge; its details beside it from 140.
    assert Columns.place(120, [:details]) == [{:page, 0, 100}]
    assert Columns.place(150, [:details]) == [{:page, 0, 100}, {:details, 100, 50}]
    assert Columns.place(260, [:details]) == [{:page, 0, 100}, {:details, 100, 100}]
  end

  test "the list follows live: moving in it opens the row's page at once, no Enter" do
    model = wide()

    model =
      put_in(model.console.cache, AtlasTui.PageCache.put(model.console.cache, widget("W-2")))

    {model, effects} = press(model, [:down])
    assert [{:send, %{"op" => "open", "to" => "/k/widget/W-2"}}] = effects
    # The page kept for it shows at once, while Control brings it fresh.
    assert model.path == "/k/widget/W-2"

    assert screen(model) =~
             ~r/^     W-1  Widget 1 .*Decide on widget W-2.*\n   › W-2  Widget 2 /mu

    # Back in one column returns to the list, the row it was on still selected.
    assert [%{path: "/", selection: {"/k/widget/W-2", 1}}] = model.console.history

    # One open at a time on the wire: the newest row is the one asked for next.
    {model, []} = press(model, [:down])
    assert model.console.expected == "/k/widget/W-3"
    assert screen(model) =~ ~r/^     W-2  Widget 2 .*Loading…/mu
    assert screen(model) =~ "   › W-3  Widget 3"
  end

  test "→ and ← move the focus, Enter in the list is →, Esc always goes back to the list" do
    model = wide()
    assert Columns.focus(model) == :list

    {model, []} = press(model, [:right])
    assert Columns.focus(model) == :page
    assert lit(model) == ["Widget W-1"]

    {model, []} = press(model, [:right])
    assert Columns.focus(model) == :details
    assert lit(model) == ["Details"]
    {model, []} = press(model, [:left])
    assert Columns.focus(model) == :page
    {model, []} = press(model, [:left])
    assert Columns.focus(model) == :list
    {model, []} = press(model, [:left])
    assert Columns.focus(model) == :list
    assert lit(model) == ["Assigned to you"]

    {model, []} = press(model, [:enter])
    assert Columns.focus(model) == :page

    {model, []} = press(model, [:right, :esc])
    assert Columns.focus(model) == :list
    assert model.path == "/k/widget/W-1"
  end

  test "the details take the focus only when they have related items" do
    model = wide(220, widget("W-1", []))
    {model, []} = press(model, [:right, :right])
    assert Columns.focus(model) == :page
  end

  test "↑ and ↓ act in the column with the focus only" do
    model = wide()
    {model, [_open]} = press(model, [:down])
    assert model.console.selections["/"] == {"/k/widget/W-2", 1}

    {model, []} = ConsoleProjectionFixture.receive(model, widget("W-2"))
    {model, []} = press(model, [:right, :right])
    assert selected_to(model) == "/k/part/P-1"

    # In the details the arrows choose a related item; the list stays where it was.
    {model, []} = press(model, [:down])
    assert selected_to(model) == "/k/part/P-2"
    assert model.console.selections["/"] == {"/k/widget/W-2", 1}

    # → opens it in the page, the focus with it.
    {model, [{:send, %{"op" => "open", "to" => "/k/part/P-2"}}]} = press(model, [:right])
    assert model.columns.focus == :page
  end

  test "the open item's action keys work from the list" do
    model = wide()
    assert Columns.focus(model) == :list

    assert {_model, [{:send, %{"op" => "open", "to" => "/k/widget/W-1/edit"}}]} =
             press(model, [{:char, "e"}])
  end

  test "Tab still goes to the next work tab, which becomes the list" do
    model = wide()
    {model, [{:send, %{"op" => "open", "to" => "/_supervised"}}]} = press(model, [:tab])
    {model, []} = ConsoleProjectionFixture.receive(model, supervised())

    assert model.columns.list == "/_supervised"
    assert screen(model) =~ ~r/^  Supervised by you +│ Page/mu
    assert screen(model) =~ "Nothing open"
  end

  test "the key line says the keys of the column with the focus" do
    model = wide()
    assert screen(model) =~ ~r/\n ↑↓ Choose · → Page · \? Keys\n/u

    {model, []} = press(model, [:right])
    assert screen(model) =~ ~r/\n ← List · → Related · e Edit · \? Keys\n/u

    {model, []} = press(model, [:right])
    assert screen(model) =~ ~r/\n ↑↓ Choose · → Open · ← Page · Esc List · \? Keys\n/u
  end

  test "a click in a column focuses it" do
    assert {[{:click, 100, 12}], ""} = Keys.parse("\e[<0;100;12M")
    assert {[], ""} = Keys.parse("\e[<0;100;12m")

    model = wide()
    # Columns of 60, 100 and 60 across 220: the page from cell 61.
    {model, []} = Model.key(model, {:click, 100, 12})
    assert Columns.focus(model) == :page
    {model, []} = Model.key(model, {:click, 200, 12})
    assert Columns.focus(model) == :details
    {model, []} = Model.key(model, {:click, 10, 12})
    assert Columns.focus(model) == :list
  end
end
