defmodule AtlasTuiTest do
  use ExUnit.Case, async: true

  alias AtlasTui.{Blocks, ConsoleProjectionFixture, Interactions, Keys, Model, View}

  # Content fixtures are installed with declared Console projections below.
  @list %{
    "op" => "page",
    "path" => "/k/thing",
    "title" => "Things",
    "back" => nil,
    "reason" => "open",
    "at" => "11:00:00",
    "position" => 3,
    "blocks" => [
      %{
        "type" => "list",
        "props" => %{
          "title" => "Things",
          "rows" => [
            %{"label" => "First", "detail" => "T-1", "to" => "/k/thing/T-1"},
            %{"label" => "Second", "detail" => "T-2 · Ready", "to" => "/k/thing/T-2"}
          ],
          "actions" => [%{"label" => "Create thing", "key" => "c", "to" => "/k/thing/new"}]
        }
      }
    ]
  }

  @form %{
    "op" => "page",
    "path" => "/k/thing/new",
    "title" => "Create thing",
    "back" => "/k/thing",
    "reason" => "open",
    "blocks" => [
      %{
        "type" => "form",
        "props" => %{
          "title" => "Create thing",
          "submit_label" => "Create",
          "submit_to" => %{"endpoint" => "create", "params" => %{"kind" => "thing"}},
          "cancel_to" => "/k/thing",
          "inputs" => [
            %{"name" => "_key", "label" => "Id", "kind" => "text", "required" => true},
            %{
              "name" => "state",
              "label" => "State",
              "kind" => "choice",
              "choices" => [
                %{"value" => "", "label" => "—"},
                %{"value" => "a", "label" => "A"},
                %{"value" => "b", "label" => "B"}
              ]
            }
          ]
        }
      }
    ]
  }

  defp model(page), do: ConsoleProjectionFixture.model(page)

  defp press(model, keys) do
    Enum.reduce(keys, {model, []}, fn key, {m, effects} ->
      {m, more} = Model.key(m, key)
      {m, effects ++ more}
    end)
  end

  defp screen(model), do: model |> View.render(90, 20, 5) |> View.plain()
  defp tall(model), do: model |> View.render(90, 30, 5) |> View.plain()

  test "new models always start the Console handshake without local navigation fallbacks" do
    model = Model.new("test")
    assert model.console.phase == :welcome

    for key <- [:tab, :down, :enter, :esc, {:char, "q"}, {:char, ":"}] do
      assert Model.key(model, key) == {model, []}
    end

    assert Model.key(model, :ctrl_c) == {model, [:quit]}
  end

  test "invalid declared destinations fail closed without a legacy block-key fallback" do
    elsewhere =
      update_in(@list, ["blocks", Access.at(0), "props", "actions"], fn _ ->
        [%{"label" => "Somewhere", "key" => "c", "to" => "/nowhere/at/all"}]
      end)

    m = model(elsewhere)
    assert m.console.projection == nil
    assert m.console.action_error != nil
    assert press(m, [{:char, "c"}, :down, :enter]) == {m, []}

    assert {_, [{:send, %{"op" => "open", "to" => "/k/thing/new"}}]} =
             press(model(@list), [{:char, "c"}])

    assert {:ok, :item, %{kind: "thing", key: "T-1"}} = Blocks.match("/k/thing/T-1")
  end

  test "keys: arrows, escape, enter, text" do
    assert Keys.parse("\e[A\e[Bx\r") == {[:up, :down, {:char, "x"}, :enter], ""}
    assert Keys.parse("ab\e") == {[{:char, "a"}, {:char, "b"}], "\e"}
    assert Keys.flush("\e") == [:esc]
    assert Keys.parse(<<127, 19, 3>>) == {[:backspace, :ctrl_s, :ctrl_c], ""}
    assert Keys.parse("é") == {[{:char, "é"}], ""}
    assert Keys.parse("\e[H\e[F\e[1~\e[4~") == {[:home, :end, :home, :end], ""}
  end

  test "an unknown or broken block becomes a fallback, and the rest still renders" do
    assert %Blocks.Fallback{type: "chart"} = Blocks.decode(%{"type" => "chart", "props" => %{}})

    assert %Blocks.Fallback{type: "item"} =
             Blocks.decode(%{"type" => "item", "props" => %{"fields" => []}})

    assert %Blocks.Item{title: "T", fields: []} =
             Blocks.decode(%{
               "type" => "item",
               "props" => %{"title" => "T", "fields" => [], "extra" => 1}
             })

    page = %{@list | "blocks" => [%{"type" => "chart", "props" => %{}} | @list["blocks"]]}
    assert screen(model(page)) =~ "(a chart block this TUI cannot show)"
    assert screen(model(page)) =~ "Second"
  end

  test "a list: move, open a row, run an action from Control's keys" do
    m = model(@list)
    text = screen(m)
    assert text =~ "› First"
    assert Interactions.capture(m, {:char, "c"}) != nil
    assert text =~ "opened at 11:00:00 · position 3"

    assert {_, [{:send, %{"op" => "open", "to" => "/k/thing/T-2"}}]} = press(m, [:down, :enter])
    assert {_, [{:send, %{"op" => "open", "to" => "/k/thing/new"}}]} = press(m, [{:char, "c"}])
    assert {_, [{:send, %{"op" => "refresh"}}]} = press(m, [{:char, "r"}])
    assert {_, [:quit]} = press(m, [{:char, "q"}])
  end

  test "a start page: declared keys open their lists, enter opens a row, esc goes back but not from the start" do
    nothing = "Nothing is assigned to you now."

    start = %{
      "op" => "page",
      "path" => "/",
      "title" => "Atlas",
      "back" => nil,
      "reason" => "open",
      "blocks" => [
        %{
          "type" => "list",
          "props" => %{
            "title" => "Assigned to you",
            "rows" => [],
            "empty" => nothing,
            "actions" => [
              %{"label" => "Widgets", "key" => "s", "to" => "/k/widget"},
              %{"label" => "Makers", "key" => "g", "to" => "/k/maker"},
              %{"label" => "Open work", "key" => "l", "to" => "/k/part"}
            ]
          }
        }
      ]
    }

    m = model(start)
    assert screen(m) =~ nothing

    for {key, to} <- [{"s", "/k/widget"}, {"g", "/k/maker"}, {"l", "/k/part"}] do
      assert {_, [{:send, %{"op" => "open", "to" => ^to}}]} = press(m, [{:char, key}])
    end

    assert press(m, [:esc]) == {m, []}
    assert press(m, [:enter]) == {m, []}

    widgets = %{
      "op" => "page",
      "path" => "/k/widget",
      "title" => "Widgets",
      "back" => "/",
      "reason" => "open",
      "blocks" => [
        %{
          "type" => "list",
          "props" => %{
            "title" => "Widgets",
            "rows" => [
              %{"label" => "Ask", "detail" => "W-1", "to" => "/k/widget/W-1"},
              %{"label" => "Plan", "detail" => "W-2", "to" => "/k/widget/W-2"}
            ]
          }
        }
      ]
    }

    m = model(widgets)
    assert screen(m) =~ "Widgets · 2"
    assert {_, [{:send, %{"op" => "open", "to" => "/k/widget/W-2"}}]} = press(m, [:down, :enter])
    assert {_, [{:send, %{"op" => "open", "to" => "/"}}]} = press(m, [:esc])
  end

  test "a link opens its web address: the item's, and the selected row's" do
    url = "https://example.org/things/2"
    link = %{"label" => "Open in browser", "key" => "o", "url" => url}
    [list] = @list["blocks"]
    rows = List.update_at(list["props"]["rows"], 1, &Map.put(&1, "links", [link]))
    m = model(%{@list | "blocks" => [put_in(list["props"]["rows"], rows)]})

    # Only the selected row's link: none on the first row.
    assert Interactions.capture(m, {:char, "o"}) == nil
    assert {_, []} = press(m, [{:char, "o"}])

    {m, _} = press(m, [:down])
    assert Interactions.capture(m, {:char, "o"}) != nil
    {m, effects} = press(m, [{:char, "o"}])
    assert effects == [{:open_url, url}]
    assert screen(m) =~ "i Opened #{url} in the browser"

    item = %{
      "type" => "item",
      "props" => %{"title" => "Thing T-2", "fields" => [], "links" => [link]}
    }

    assert {_, [{:open_url, ^url}]} =
             press(model(%{@list | "blocks" => [item]}), [{:char, "o"}])

    # Anything but http and https is never opened.
    for bad <- ["file:///etc/passwd", "javascript:alert(1)", "https://", "https://a b"] do
      assert Model.openable?(bad) == false
      assert {_, []} = Model.external(model(@list), bad)
    end

    assert AtlasTui.Browser.open("file:///etc/passwd", %{}) == {:error, :not_http}
    assert AtlasTui.Browser.command(%{"browser" => "/tmp/stand-in"}) == "/tmp/stand-in"
    assert AtlasTui.Browser.command(%{}) in ["open", "xdg-open"]
  end

  # A page in two parts, as Control sends an item's page: its main part (the content) and
  # its related part (two lists).
  defp parted(lines), do: lines |> parted_page() |> model()

  defp parted_page(lines) do
    notes = Enum.map_join(1..lines, "\n", &"Line #{&1} of the notes")
    row = fn label, detail, to -> %{"label" => label, "detail" => detail, "to" => to} end

    @list
    |> Map.put("markup", [])
    |> Map.merge(%{
      "back" => "/k/thing",
      "blocks" => [
        %{
          "id" => "item",
          "type" => "item",
          "props" => %{
            "title" => "Thing T-1: One",
            "fields" => [%{"label" => "Notes", "value" => notes}]
          }
        },
        %{
          "id" => "list:parts",
          "type" => "list",
          "props" => %{
            "rows" => [row.("Wheel", "P-1", "/k/part/P-1"), row.("Axle", "P-2", "/k/part/P-2")]
          }
        },
        %{
          "id" => "parent:of",
          "type" => "list",
          "props" => %{"rows" => [row.("W-1", "Widget", "/k/widget/W-1")]}
        }
      ],
      "markup" => [
        %{
          "kind" => "part",
          "start" => "item",
          "end" => "item",
          "props" => %{"title" => "Content", "role" => "main"}
        },
        %{
          "kind" => "part",
          "start" => "list:parts",
          "end" => "parent:of",
          "props" => %{"title" => "References", "role" => "related"}
        },
        %{
          "kind" => "section",
          "start" => "list:parts",
          "end" => "list:parts",
          "props" => %{"title" => "Parts"}
        },
        %{
          "kind" => "section",
          "start" => "parent:of",
          "end" => "parent:of",
          "props" => %{"title" => "Of widget"}
        }
      ]
    })
  end

  # The page above with its owner's part first, as Control sends it to the owner.
  defp with_todo(page) do
    todo = %{
      "id" => "todo",
      "type" => "item",
      "props" => %{
        "title" => "Your move: Check it",
        "fields" => [
          %{
            "label" => "Because",
            "value" => "it is painted",
            "origin" => %{"since" => "2026-11-03T10:00:00Z", "by" => "flow"}
          },
          %{"label" => "How", "value" => "Look it over."},
          %{"label" => "Keys", "value" => "a Approve"}
        ]
      }
    }

    part = %{
      "kind" => "part",
      "start" => "todo",
      "end" => "todo",
      "props" => %{"title" => "Your move", "role" => "todo"}
    }

    page
    |> Map.merge(%{"blocks" => [todo | page["blocks"]], "markup" => [part | page["markup"]]})
    |> model()
  end

  test "the owner's part comes first, and gets its room before the references" do
    m = with_todo(parted_page(60))
    assert hd(Model.parts(m)) == ["todo"]
    text = tall(m)

    assert text =~
             ~r/┌─ Your move ─+┐\n.*Your move: Check it(.*\n)+.*Keys\s+a Approve.*\n.*└─+┘\n.*┌─ Content/u

    assert text =~ "› Wheel"
  end

  test "short detail panes page through every value and provenance line without overscroll debt" do
    values = Enum.map(1..60, &"VALUE_#{&1}_界é")
    provenance = Enum.map(1..8, &"ORIGIN_#{&1}_界é")

    page =
      put_in(parted_page(1), ["blocks", Access.at(0), "props", "fields"], [
        %{
          "label" => "Long Unicode detail label 界é",
          "value" => Enum.join(values, "\n"),
          "origin" => %{"cause" => Enum.join(provenance, "\n")}
        }
      ])

    draw = &View.frame(&1, &2, &3, 5)
    m = %{model(page) | part: 0}
    {initial, m} = draw.(m, 38, 24)

    {bottom, screens} =
      Enum.reduce(1..120, {m, [View.plain(initial)]}, fn _, {m, screens} ->
        {m, []} = Model.operation(m, "page_next")
        {rows, m} = draw.(m, 38, 24)
        {m, [View.plain(rows) | screens]}
      end)

    for line <- values ++ provenance do
      assert Enum.any?(screens, &String.contains?(&1, line)), "Skipped #{line}"
    end

    assert hd(screens) =~ List.last(provenance)
    {up, []} = Model.operation(bottom, "page_previous")
    {rows, _} = draw.(up, 38, 24)
    refute View.plain(rows) == hd(screens)

    for {width, height} <- [{140, 24}, {38, 20}, {38, 32}] do
      {_, resized} = draw.(bottom, width, height)
      {resized, []} = Model.operation(resized, "page_next")
      {at_end, resized} = draw.(resized, width, height)
      assert View.plain(at_end) =~ List.last(provenance)
      {references, []} = Model.operation(resized, "part_next")
      {_, references} = draw.(references, width, height)
      {references, []} = Model.operation(references, "page_next")
      {returned, []} = Model.operation(references, "part_previous")
      assert returned.scrolls[0] == resized.scrolls[0]
      {returned, []} = Model.operation(returned, "page_previous")
      {rows, _} = draw.(returned, width, height)
      refute View.plain(rows) == View.plain(at_end)
    end
  end

  test "a page in parts: a long content never hides the references" do
    m = parted(60)
    assert Model.parts(m) == [["item"], ["list:parts", "parent:of"]]
    text = tall(m)

    # One above the other on a narrow screen; the content cut, saying how much more.
    assert text =~ ~r/┌─ Content ─+┐\n(.*\n)+.*… \d+ more lines.*\n.*└─+┘\n.*┌─ References/u
    assert text =~ "› Wheel"
    assert text =~ "W-1"
    assert length(String.split(text, "\n")) == 30

    # The rows of both lists are one selection.
    {down, _} = press(m, [:down, :down])
    assert tall(down) =~ "› W-1"
    assert {_, [{:send, %{"to" => "/k/widget/W-1"}}]} = press(down, [:enter])

    # Explicit pane operations leave the row selection alone while scrolling content.
    {focused, []} = Model.operation(m, "part_next")
    {_, focused} = View.frame(focused, 90, 30, 5)
    {scrolled, []} = Model.operation(focused, "page_next")
    assert scrolled.selected == 0
    refute tall(scrolled) =~ "Thing T-1: One"
    assert tall(scrolled) =~ "› Wheel"
    {back, []} = Model.operation(scrolled, "part_previous")
    {back, []} = Model.key(back, :down)
    assert back.selected == 1

    # Side by side on a wide screen.
    wide = m |> View.render(150, 20, 5) |> View.plain()
    assert wide =~ ~r/┌─ Content ─+┐ +┌─ References ─+┐/u

    # Content that fits is not cut, and says nothing about more.
    refute tall(parted(2)) =~ "more line"
  end

  test "row navigation reveals the selection without moving another pane's manual scroll" do
    page =
      update_in(parted_page(60), ["blocks", Access.at(1), "props", "rows"], fn _ ->
        for n <- 1..30,
            do: %{"label" => "Reference #{n}", "to" => "/k/part/P-#{n}"}
      end)

    model = %{model(page) | selected: 15, part: 0, scroll: 23, scrolls: %{0 => 10, 1 => 100}}
    refute tall(model) =~ "› Reference 16"

    for {operation, selected, label} <- [
          {"move_next", 16, "Reference 17"},
          {"move_previous", 14, "Reference 15"},
          {"select_first", 0, "Reference 1"},
          {"select_last", 30, "W-1"}
        ] do
      {moved, []} = Model.operation(model, operation)
      assert moved.selected == selected
      assert moved.scrolls == %{0 => 10}
      assert moved.scroll == 23
      assert moved.part == 0
      assert tall(moved) =~ "› #{label}"
      assert tall(moved) =~ "↑ 10 lines above"
    end
  end

  test "a flat list resumes following its selected row after manual scrolling" do
    model = %{model(@list) | scroll: 10}

    for operation <- ~w(move_next move_previous select_first select_last) do
      {moved, []} = Model.operation(model, operation)
      assert moved.scroll == nil
      assert moved.scrolls == %{}
      assert screen(moved) =~ "› "
    end
  end

  test "a hint redraws the list and keeps the selected row" do
    {m, _} = press(model(@list), [:down])

    {hinted, []} =
      ConsoleProjectionFixture.receive(m, %{@list | "reason" => "hint", "position" => 4})

    assert hinted.selected == 1
    assert screen(hinted) =~ "updated by hint at 11:00:00 · position 4"

    {reconciled, []} =
      ConsoleProjectionFixture.receive(hinted, %{
        @list
        | "reason" => "reconcile",
          "at" => "11:00:05"
      })

    assert screen(reconciled) =~ "reconciled at 11:00:05 · position 3 · last hint at 11:00:00"
  end

  test "a form: type, choose, save sends the values" do
    {m, effects} =
      press(model(@form), [
        {:char, "T"},
        {:char, "-"},
        {:char, "9"},
        :backspace,
        {:char, "1"},
        :down,
        :right,
        :right
      ])

    assert effects == []
    assert screen(m) =~ "[T-1"
    assert screen(m) =~ "‹ B ›"

    assert {%{waiting: true},
            [
              {:send,
               %{
                 "op" => "submit",
                 "endpoint" => "create",
                 "params" => %{"kind" => "thing"},
                 "values" => %{"_key" => "T-1", "state" => "b"}
               }}
            ]} =
             press(m, [:ctrl_s])

    assert {_, [{:send, %{"op" => "submit"}}]} = press(m, [:down, :enter])
    assert {_, [{:send, %{"op" => "open", "to" => "/k/thing"}}]} = press(m, [:esc])
  end

  test "an update form offers the other parents as a choice and stores the one chosen" do
    choices =
      for {key, title} <- [{"W-1", "Ask"}, {"W-2", "Plan"}, {"W-3", "Run"}],
          do: %{"value" => key, "label" => "#{key} #{title}"}

    update = %{
      "op" => "page",
      "path" => "/k/part/P-1/edit",
      "title" => "Update part P-1",
      "back" => "/k/part/P-1",
      "reason" => "open",
      "blocks" => [
        %{
          "type" => "form",
          "props" => %{
            "title" => "Update part P-1",
            "submit_label" => "Update",
            "submit_to" => %{"endpoint" => "update", "params" => %{"key" => "P-1"}},
            "cancel_to" => "/k/part/P-1",
            "inputs" => [
              %{"name" => "title", "label" => "Title", "kind" => "text", "value" => "Fix it"},
              %{
                "name" => "in_widget",
                "label" => "In widget",
                "kind" => "choice",
                "value" => "W-2",
                "choices" => choices
              }
            ]
          }
        }
      ]
    }

    m = model(update)
    assert screen(m) =~ "‹ W-2 Plan ›"
    {m, []} = press(m, [:down, :right])
    assert screen(m) =~ "‹ W-3 Run ›"
    # Past the last widget it comes round to the first; left goes back.
    {m, []} = press(m, [:right])
    assert m.values["in_widget"] == "W-1"
    {m, []} = press(m, [:left, :left])
    assert m.values["in_widget"] == "W-2"
    {m, []} = press(m, [:right])

    assert {_,
            [
              {:send,
               %{
                 "endpoint" => "update",
                 "params" => %{"key" => "P-1"},
                 "values" => %{"title" => "Fix it", "in_widget" => "W-3"}
               }}
            ]} = press(m, [:ctrl_s])
  end

  test "a long text wraps in its field instead of being cut" do
    long = String.duplicate("abcdefghij ", 12) |> String.trim()
    {m, _} = press(model(@form), Enum.map(String.graphemes(long), &{:char, &1}))
    text = screen(m)
    assert text =~ "[abcdefghij abcdefghij"
    assert text =~ "abcdefghij▏"
    # Every word is on screen, over more than one row.
    assert text |> String.split("abcdefghij") |> length() == 13
    {m, _} = press(m, [:down])
    refute screen(m) =~ "▏"
    assert screen(m) |> String.split("abcdefghij") |> length() == 13
  end

  @notes_form update_in(@form, ["blocks", Access.at(0), "props", "inputs"], fn inputs ->
                inputs ++
                  [%{"name" => "notes", "label" => "Notes", "kind" => "multiline", "value" => ""}]
              end)

  defp type(text), do: Enum.map(String.graphemes(text), &{:char, &1})

  test "a multi-line input: enter starts a new line, arrows move, ctrl-s saves the lines" do
    {m, _} = press(model(@notes_form), [:down, :down])

    {m, effects} =
      press(
        m,
        type("## Why") ++ [:enter, :enter] ++ type("Because.") ++ [:enter] ++ type("- one")
      )

    assert effects == []
    assert m.values["notes"] == "## Why\n\nBecause.\n- one"

    # Up twice, to the end of "Because."… then a blank line before the list.
    {m, _} = press(m, [:up, :end, :enter])
    assert m.values["notes"] == "## Why\n\nBecause.\n\n- one"

    # Backspace at the start of a line joins it to the line above.
    {m, _} = press(m, [:down, :home, :backspace])
    assert m.values["notes"] == "## Why\n\nBecause.\n- one"

    # Typing goes where the cursor is.
    {m, _} = press(m, [:left, :left] ++ type("!"))
    assert m.values["notes"] == "## Why\n\nBecause!.\n- one"

    assert {_, [{:send, %{"op" => "submit", "values" => %{"notes" => notes}}}]} =
             press(m, [:ctrl_s])

    assert notes == m.values["notes"]

    # Past the first line, up leaves the input; tab always does.
    {m2, _} = press(m, [:up, :up, :up])
    assert Model.focusable(Model.form(m2)) |> Enum.at(m2.focus) |> Map.get(:name) == "state"
    {m3, _} = press(m, [:tab])
    assert Enum.at(Model.focusable(Model.form(m3)), m3.focus) == :submit
  end

  test "a multi-line value: entering it starts on its first line; End goes to the end of the cursor's line" do
    page =
      put_in(
        @notes_form,
        ["blocks", Access.at(0), "props", "inputs", Access.at(2), "value"],
        "First line\nSecond line"
      )

    {m, _} = press(model(page), [:down, :down])
    {m, _} = press(m, type("Intro") ++ [:enter, :end] ++ type(" (and how)"))
    assert m.values["notes"] == "Intro\nFirst line (and how)\nSecond line"

    # Home and End stay on the cursor's line.
    {m, _} = press(m, [:up, :end] ++ type(":") ++ [:down, :down, :home] ++ type("> "))
    assert m.values["notes"] == "Intro:\nFirst line (and how)\n> Second line"
  end

  test "a long multi-line input scrolls to keep the cursor in sight" do
    text = Enum.map_join(1..40, "\n", &"line #{&1}")

    page =
      put_in(
        @notes_form,
        ["blocks", Access.at(0), "props", "inputs", Access.at(2), "value"],
        text
      )

    {m, _} = press(model(page), [:down, :down])
    # Moving down into it starts at its first line.
    assert screen(m) =~ "[line 1 "
    assert screen(m) =~ "more below"
    refute screen(m) =~ "line 40"

    {m, _} = press(m, List.duplicate(:down, 38))
    assert screen(m) =~ "line 39"
    assert screen(m) =~ "more above"
    refute screen(m) =~ "[line 1 "
    assert screen(m) =~ "[ Create ]"

    # Out of focus it shows its start, and how much more there is.
    {m, _} = press(m, [:tab])
    assert screen(m) =~ "[line 1 "
    assert screen(m) =~ "↓ 32 more below"
  end

  test "an item shows text with its line breaks, blank lines and sections" do
    notes =
      "## Why\n\nBecause it is long enough to wrap around the edge of the screen here.\n\n- one\n- two"

    item = %{
      @list
      | "blocks" => [
          %{
            "type" => "item",
            "props" => %{
              "title" => "Thing T-1: " <> String.duplicate("a long title ", 10),
              "fields" => [%{"label" => "Notes", "value" => notes}]
            }
          }
        ]
    }

    lines = model(item) |> View.render(60, 30, 5) |> View.plain() |> String.split("\n")
    at = Enum.find_index(lines, &(&1 =~ "## Why"))
    assert Enum.at(lines, at + 1) |> String.trim() == ""
    assert Enum.at(lines, at + 2) =~ "Because it is long"
    assert Enum.at(lines, at + 3) =~ ~r/^\s+\S/
    assert Enum.at(lines, at + 4) |> String.trim() == ""
    assert Enum.at(lines, at + 5) =~ "- one"
    assert Enum.at(lines, at + 6) =~ "- two"
    # The title wraps instead of being cut.
    assert lines |> Enum.join() |> String.split("a long title") |> length() == 11
  end

  test "a value set by a fact shows since when, by whom and why, under it" do
    item = %{
      @list
      | "blocks" => [
          %{
            "type" => "item",
            "props" => %{
              "title" => "Thing T-1",
              "fields" => [
                %{
                  "label" => "Linked to",
                  "value" => "ada",
                  "origin" => %{
                    "since" => "2026-11-03T14:10:00Z",
                    "by" => "ada",
                    "cause" => "tested"
                  }
                }
              ]
            }
          }
        ]
    }

    lines = model(item) |> View.render(80, 20, 5) |> View.plain() |> String.split("\n")
    at = Enum.find_index(lines, &(&1 =~ "Linked to"))
    assert Enum.at(lines, at) =~ "ada"
    assert Enum.at(lines, at + 1) =~ ~r/since 3 Nov \d\d:10 · by ada · tested/
    assert View.origin_text(nil) == ""
  end

  test "a page longer than the screen scrolls, and keeps a selected row in sight" do
    long = Enum.map_join(1..30, "\n", &"line #{&1}")

    page = fn rows ->
      %{
        @list
        | "blocks" => [
            %{
              "type" => "item",
              "props" => %{
                "title" => "Thing T-1",
                "fields" => [%{"label" => "Notes", "value" => long}]
              }
            },
            %{
              "type" => "list",
              "props" => %{"title" => "Parts", "rows" => rows, "empty" => "No parts yet."}
            }
          ]
      }
    end

    m = model(page.([]))
    refute screen(m) =~ "No parts yet."
    {m, _} = press(m, [:page_down, :page_down, :page_down])
    assert screen(m) =~ "No parts yet."
    {m, _} = press(m, [:page_up, :page_up, :page_up])
    assert screen(m) =~ "line 1\n"

    # The page opens at its top; moving in the list under it brings the row in sight.
    m = model(page.([%{"label" => "Wheel", "to" => "/k/part/P-1"}]))
    refute screen(m) =~ "› Wheel"
    {m, _} = press(m, [:down])
    assert screen(m) =~ "› Wheel"
  end

  test "a read-only input is shown but never takes focus or typing" do
    page =
      update_in(@form, ["blocks", Access.at(0), "props", "inputs"], fn inputs ->
        [
          %{"name" => "_key", "label" => "Id", "kind" => "readonly", "value" => "T-01"}
          | tl(inputs)
        ]
      end)

    {m, _} = press(model(page), [{:char, "x"}])
    assert screen(m) =~ ~r/Id\s+T-01/
    assert m.values["_key"] == "T-01"
    assert m.values["state"] == ""
    assert Model.focusable(Model.form(m)) |> hd() |> Map.get(:name) == "state"
  end

  test "q is text in a form, not quit" do
    {m, effects} = press(model(@form), [{:char, "q"}])
    assert effects == []
    assert m.values["_key"] == "q"
  end

  test "a confirm: y submits, n goes back; without confirm_to it only goes back" do
    confirm = %{
      @form
      | "blocks" => [
          %{
            "type" => "confirm",
            "props" => %{
              "title" => "Delete T-1?",
              "text" => "Gone.",
              "confirm_label" => "Delete",
              "confirm_to" => %{
                "endpoint" => "delete",
                "params" => %{"kind" => "thing", "key" => "T-1"}
              },
              "cancel_to" => "/k/thing/T-1"
            }
          }
        ]
    }

    assert {_,
            [{:send, %{"op" => "submit", "endpoint" => "delete", "params" => %{"key" => "T-1"}}}]} =
             press(model(confirm), [{:char, "y"}])

    assert {_, [{:send, %{"op" => "open", "to" => "/k/thing/T-1"}}]} =
             press(model(confirm), [{:char, "n"}])

    refusal =
      put_in(confirm, ["blocks", Access.at(0), "props"], %{
        "title" => "Cannot",
        "text" => "Still has 2.",
        "cancel_to" => "/k/thing/T-1"
      })

    assert {_, [{:send, %{"op" => "open", "to" => "/k/thing/T-1"}}]} =
             press(model(refusal), [{:char, "y"}, :enter])
  end

  test "notices and a lost connection are shown, never old content as current" do
    m =
      Model.message(model(@list), %{
        "op" => "notice",
        "tone" => "pending",
        "text" => "Sent to State; waiting until it is stored…"
      })

    assert screen(m) =~ "… Sent to State"

    gone = Model.disconnected(m)
    assert screen(gone) =~ "Not connected to Control. Retrying…"
    refute screen(gone) =~ "First"
  end

  describe "markup" do
    # A thing in a part of its own, then its parts in a section.
    @marked %{
      "op" => "page",
      "path" => "/k/thing/T-1",
      "title" => "Thing T-1",
      "back" => "/k/thing",
      "reason" => "open",
      "blocks" => [
        %{
          "id" => "item",
          "type" => "item",
          "props" => %{
            "title" => "Thing T-1: First",
            "fields" => [%{"label" => "Id", "value" => "T-1"}]
          }
        },
        %{
          "id" => "parts",
          "type" => "list",
          "props" => %{
            "rows" => [%{"label" => "Wheel", "detail" => "P-1", "to" => "/k/part/P-1"}]
          }
        }
      ],
      "markup" => [
        %{
          "kind" => "part",
          "start" => "item",
          "end" => "item",
          "props" => %{"title" => "Content", "role" => "main"}
        },
        %{
          "kind" => "section",
          "start" => "parts",
          "end" => "parts",
          "props" => %{"title" => "Parts"}
        }
      ]
    }

    test "Console content preserves part and section markup around row content" do
      text = model(@marked) |> View.render(40, 30, 5) |> View.plain()
      assert text =~ "┌─ Content"
      assert text =~ "Thing T-1: First"
      assert text =~ "Parts ─"
      assert text =~ "› Wheel"
      assert text =~ "P-1"
    end

    test "markup of an unknown kind is left out; the blocks still show" do
      page =
        update_in(
          @marked["markup"],
          &[%{"kind" => "sparkle", "start" => "item", "end" => "item"} | &1]
        )

      assert %Model{markup: [%{"kind" => "part"}, %{"kind" => "section"}]} = model(page)
      assert screen(model(page)) =~ "┌"
    end

    test "markup that does not nest is left out whole, and the page renders flat" do
      crossing = [
        %{
          "kind" => "part",
          "start" => "item",
          "end" => "parts",
          "props" => %{"title" => "All", "role" => "main"}
        },
        %{
          "kind" => "section",
          "start" => "parts",
          "end" => "parts",
          "props" => %{"title" => "Parts"}
        },
        %{
          "kind" => "highlight",
          "start" => "item",
          "end" => "nowhere",
          "props" => %{"tone" => "ok"}
        }
      ]

      m = model(%{@marked | "markup" => crossing})
      assert m.markup == []
      refute screen(m) =~ "┌─ All"
      assert screen(m) =~ "Thing T-1: First"
      assert screen(m) =~ "Wheel"
    end

    test "Console assigns stable content ids when the page omits them" do
      assert %Model{ids: ["#0"], markup: []} = model(@list)
      assert screen(model(@list)) =~ "Things"
    end
  end

  test "the Console renderer covers the complete presentation catalogue" do
    schema = AtlasBFFContract.Contract.__schema__()
    known = View.known()

    for %{name: name} <- schema.blocks,
        do:
          assert(Atom.to_string(name) in known.blocks, "the Console does not draw block #{name}")

    for %{name: name} <- schema.markup,
        do:
          assert(Atom.to_string(name) in known.markup, "the Console does not know markup #{name}")
  end
end
