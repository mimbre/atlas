defmodule AtlasTui.LegendTest do
  use ExUnit.Case, async: true
  alias AtlasTui.{Console, Interactions, Legend, LegendView, Model, View}

  defp action(id, keys, operation, extra) do
    %{
      "id" => id,
      "type" => "console_action",
      "props" =>
        Map.merge(
          %{
            "label" => id,
            "keys" => List.wrap(keys),
            "operation" => %{"name" => operation},
            "available" => true
          },
          extra
        )
    }
  end

  defp page(context \\ "browse", extra \\ [], revision \\ "r1") do
    native =
      case context do
        "form" ->
          [
            %{
              "id" => "form",
              "type" => "form",
              "props" => %{
                "title" => "Edit",
                "inputs" => [
                  %{"name" => "title", "label" => "Title", "kind" => "text", "value" => "server"},
                  %{
                    "name" => "notes",
                    "label" => "Notes",
                    "kind" => "multiline",
                    "value" => "notes"
                  }
                ],
                "submit_label" => "Save",
                "submit_to" => %{
                  "endpoint" => "update",
                  "params" => %{"kind" => "widget", "key" => "W1"}
                }
              }
            }
          ]

        "confirm" ->
          [
            %{
              "id" => "confirm",
              "type" => "confirm",
              "props" => %{
                "title" => "Confirm",
                "text" => "Are you sure?",
                "cancel_to" => "/k/widget"
              }
            }
          ]

        _ ->
          [
            %{
              "id" => "list",
              "type" => "list",
              "props" => %{
                "title" => "Widgets",
                "rows" => [
                  %{"id" => "W1", "label" => "One", "to" => "/k/widget/W1"},
                  %{"id" => "W2", "label" => "Two", "to" => "/k/widget/W2"}
                ]
              }
            }
          ]
      end

    groups = [
      {context, "Navigation",
       [
         action("keys", if(context == "browse", do: "?", else: "l"), "legend_open", %{
           "label" => "Keys"
         }),
         action("next-tab", "Tab", if(context == "form", do: "focus_next", else: "tab_next"), %{
           "label" => "Next view"
         })
       ]},
      {context, "Active view",
       [
         action("disabled", "d", "refresh", %{
           "label" => "Deferred action",
           "available" => false,
           "reason" => "Waiting for permission"
         })
         | extra
       ]},
      {"legend", "Keys",
       [
         action("close", "Esc", "legend_close", %{"label" => "Close keys"}),
         action("up", ["Up", "k"], "scroll_up", %{"label" => "Scroll up"}),
         action("down", ["Down", "j"], "scroll_down", %{"label" => "Scroll down"}),
         action("pgup", "PageUp", "page_previous", %{"label" => "Previous page"}),
         action("pgdown", "PageDown", "page_next", %{"label" => "Next page"})
       ]}
    ]

    {blocks, markup} =
      Enum.reduce(groups, {native, []}, fn {context, title, actions}, {blocks, markup} ->
        actions =
          Enum.map(actions, fn a ->
            scope =
              Map.merge(
                %{"page" => "/k/widget", "revision" => revision, "context" => context},
                a["props"]["scope"] || %{}
              )

            put_in(a, ["props", "scope"], scope)
          end)

        {blocks ++ actions,
         markup ++
           [
             %{
               "kind" => "legend",
               "start" => hd(actions)["id"],
               "end" => List.last(actions)["id"],
               "props" => %{"title" => title, "context" => context}
             }
           ]}
      end)

    %{
      "op" => "page",
      "path" => "/k/widget",
      "title" => "Widgets",
      "reason" => "open",
      "blocks" => blocks,
      "markup" => markup,
      "actions_revision" => revision
    }
  end

  defp model(page \\ page()) do
    shell = %{
      "title" => "Atlas Console",
      "tabs" => [%{"id" => "widgets", "label" => "Widgets", "to" => "/k/widget"}],
      "revision" => "shell1"
    }

    initial = %{
      Model.new("test")
      | connected: true,
        console: %{Console.new() | phase: :ready, shell: shell, stale: false}
    }

    {model, []} = Console.receive(initial, page)
    assert model.console.projection != nil
    model
  end

  defp screen(model, width \\ 90, height \\ 30),
    do: model |> View.render(width, height, 5) |> View.plain()

  defp press(model, key) do
    {model, []} = Model.key(model, key)
    model
  end

  test "declared opener shows grouped vertical rows and the same original action objects" do
    m = model()
    assert screen(m) =~ "? Keys"
    opened = press(m, {:char, "?"})
    assert Interactions.context(opened) == "legend"
    groups = Legend.groups(opened)

    assert Enum.map(groups, & &1.markup["props"]["title"]) == [
             "Navigation",
             "Active view",
             "Keys"
           ]

    assert Enum.flat_map(groups, & &1.actions) == opened.console.projection.actions
    text = screen(opened)

    for label <- [
          "┌ Keys",
          "Navigation",
          "Active view",
          "Next view",
          "Esc",
          "Close keys",
          "Deferred action",
          "unavailable",
          "Waiting for permission"
        ],
        do: assert(text =~ label)

    refute text =~ "› W1"
    refute text =~ "tab next part"
    # Real source bindings remain identical after restoring browse focus.
    closed = press(opened, :esc)
    assert closed.console.legend == nil
    assert closed.focus == m.focus
    assert closed.values == m.values
    assert Interactions.capture(closed, :tab).id == "next-tab"
  end

  test "the BFF chooses opener/closer keys; no local question-mark or Escape fallback exists" do
    p = page() |> put_in(["blocks", Access.at(1), "props", "keys"], ["x"])
    m = model(p)
    assert Model.key(m, {:char, "?"}) == {m, []}
    opened = press(m, {:char, "x"})
    assert opened.console.legend != nil
    assert screen(m) =~ "x Keys"

    p =
      update_in(p["blocks"], fn blocks ->
        Enum.map(blocks, fn a ->
          if a["id"] == "close", do: put_in(a, ["props", "keys"], ["z"]), else: a
        end)
      end)

    {opened, []} = Console.receive(opened, Map.put(p, "reason", "hint"))
    assert press(opened, :esc).console.legend != nil
    assert press(opened, {:char, "z"}).console.legend == nil
  end

  test "form/modal legend restores actual drafts, cursor and focus; unbound modal keys never edit" do
    for context <- ["form", "confirm"] do
      m = model(page(context))

      m = %{
        m
        | values: %{"title" => "typed? actual draft", "notes" => "first\nsecond"},
          focus: 1,
          cursor: {1, 3}
      }

      opened = press(m, {:char, "l"})

      for key <- [{:char, "?"}, {:char, "q"}, :tab, :backspace, :enter] do
        assert Model.key(opened, key) == {opened, []}
      end

      restored = press(opened, :esc)

      assert Map.take(restored, [:values, :focus, :cursor, :selected, :scroll, :steps]) ==
               Map.take(m, [:values, :focus, :cursor, :selected, :scroll, :steps])

      assert Interactions.context(restored) == context
    end

    m = model(page("form")) |> press({:char, "?"})
    assert m.values["title"] == "server?"
    assert m.console.legend == nil
  end

  test "open/close transitions expire captured actions even when returning to the same context" do
    m = model()
    before = Interactions.capture(m, :tab)
    opened = press(m, {:char, "?"})
    assert Interactions.dispatch(opened, before) == {opened, []}
    close_event = Interactions.capture(opened, :esc)
    closed = press(opened, :esc)
    assert Interactions.dispatch(closed, before) == {closed, []}
    assert Interactions.dispatch(closed, close_event) == {closed, []}
  end

  test "hint replacement updates labels, availability and original objects without losing a draft" do
    p = page("form")
    m = model(p) |> Map.put(:values, %{"title" => "mine", "notes" => ""}) |> press({:char, "l"})

    fresh =
      page("form", [], "r2")
      |> update_in(["blocks"], fn blocks ->
        Enum.map(blocks, fn a ->
          if a["id"] == "disabled",
            do:
              a
              |> put_in(["props", "label"], "Now enabled")
              |> put_in(["props", "available"], true),
            else: a
        end)
      end)
      |> Map.put("reason", "hint")

    captured = Interactions.capture(m, :esc)
    {updated, []} = Console.receive(m, fresh)
    assert updated.console.legend != nil
    assert updated.values == m.values
    assert screen(updated) =~ "Now enabled"
    refute screen(updated) =~ "Deferred action"
    assert Interactions.dispatch(updated, captured) == {updated, []}
    assert press(updated, :esc).values == m.values
  end

  test "refresh losing the last declared closer dismisses safely and can recover" do
    for variant <- [:disabled, :removed, :scope] do
      context = if variant == :scope, do: "browse", else: "form"
      m = model(page(context))

      m = %{
        m
        | values: %{"title" => "human draft", "notes" => "untouched"},
          cursor: {0, 3},
          focus: 1
      }

      opened = press(m, {:char, if(context == "form", do: "l", else: "?")})
      captured = Interactions.capture(opened, :esc)
      assert captured != nil
      fresh = page(context, [], "r2") |> Map.put("reason", "hint")

      fresh =
        case variant do
          :removed ->
            fresh
            |> update_in(["blocks"], &Enum.reject(&1, fn a -> a["id"] == "close" end))
            |> update_in(
              ["markup"],
              &Enum.map(&1, fn group ->
                if group["start"] == "close", do: %{group | "start" => "up"}, else: group
              end)
            )

          _ ->
            update_in(fresh, ["blocks"], fn blocks ->
              Enum.map(blocks, fn a ->
                if a["id"] == "close" do
                  if variant == :disabled,
                    do: put_in(a, ["props", "available"], false),
                    else:
                      update_in(
                        a,
                        ["props", "scope"],
                        &Map.merge(&1, %{"on" => "list", "row" => "W2"})
                      )
                else
                  a
                end
              end)
            end)
        end

      {updated, []} = Console.receive(opened, fresh)
      assert updated.console.projection != nil
      assert updated.console.action_error == nil
      assert updated.console.legend == nil
      assert updated.focus == opened.focus
      assert updated.cursor == opened.cursor
      assert updated.selected == opened.selected
      if context == "form", do: assert(updated.values == opened.values)
      assert updated.console.generation > opened.console.generation
      assert Interactions.dispatch(updated, captured) == {updated, []}

      {restored, []} =
        Console.receive(updated, Map.put(page(context, [], "r3"), "reason", "hint"))

      reopened = press(restored, {:char, if(context == "form", do: "l", else: "?")})
      assert reopened.console.legend != nil
      assert press(reopened, :esc).console.legend == nil
    end
  end

  test "actual Control projection cannot retain a modal after Close becomes unavailable" do
    actual =
      __DIR__ |> Path.join("fixtures/console-actions.json") |> File.read!() |> JSON.decode!()

    opened = model(actual) |> press({:char, "?"})
    captured = Interactions.capture(opened, :esc)

    fresh =
      actual
      |> Map.put("reason", "hint")
      |> update_in(["blocks"], fn blocks ->
        Enum.map(blocks, fn a ->
          if get_in(a, ["props", "operation", "name"]) == "legend_close",
            do: put_in(a, ["props", "available"], false),
            else: a
        end)
      end)

    {updated, []} = Console.receive(opened, fresh)
    assert updated.console.projection != nil
    assert Legend.closer(updated) == nil
    assert updated.console.legend == nil
    assert Interactions.dispatch(updated, captured) == {updated, []}
  end

  test "read-only overlay can close after disconnect using its last declared binding" do
    m = model(page("form")) |> press({:char, "l"}) |> Model.disconnected()
    closed = press(m, :esc)
    assert closed.console.legend == nil
    assert closed.values == m.values
    refute closed.connected

    refused = %{m | closed: true}
    assert press(refused, :esc).console.legend == nil
    assert press(refused, :esc).values == m.values
  end

  test "legend and executor filter the same selected row scope" do
    extras =
      for {id, label} <- [{"W1", "Open first reference"}, {"W2", "Open second reference"}] do
        action("row-#{id}", "o", "open", %{
          "label" => label,
          "operation" => %{"name" => "open", "to" => "/k/widget/#{id}"},
          "scope" => %{"on" => "list", "row" => id}
        })
      end

    m = %{model(page("browse", extras)) | selected: 1}
    assert Interactions.capture(m, {:char, "o"}).id == "row-W2"
    opened = press(m, {:char, "?"})
    assert screen(opened) =~ "Open second reference"
    refute screen(opened) =~ "Open first reference"
    assert press(opened, :up).selected == 1
    restored = press(opened, :esc)
    assert Interactions.capture(restored, {:char, "o"}).id == "row-W2"
  end

  test "a replacement page or invalid projection dismisses the overlay and expires its events" do
    opened = model() |> press({:char, "?"})
    event = Interactions.capture(opened, :esc)

    replaced =
      page()
      |> Map.put("path", "/k/part")
      |> update_in(["blocks"], fn blocks ->
        Enum.map(blocks, fn
          %{"type" => "console_action"} = a -> put_in(a, ["props", "scope", "page"], "/k/part")
          b -> b
        end)
      end)

    {replaced, []} = Console.receive(opened, replaced)
    assert replaced.console.legend == nil
    assert Interactions.dispatch(replaced, event) == {replaced, []}
    invalid = page() |> Map.put("actions_revision", "wrong") |> Map.put("reason", "hint")
    {invalid, []} = Console.receive(opened, invalid)
    assert invalid.console.legend == nil
    assert invalid.console.projection == nil
  end

  test "request and step-editor drafts survive legend focus without becoming input targets" do
    alias AtlasTui.Blocks
    asked = %{model(page("ask")) | ask: "request? exactly"}
    opened = press(asked, {:char, "l"})
    assert opened.console.legend != nil
    assert press(opened, {:char, "x"}).ask == asked.ask
    restored = press(opened, :esc)
    assert restored.ask == asked.ask
    assert Interactions.context(restored) == "ask"

    step = %Blocks.Step{
      n: 1,
      label: "Edit step",
      state: "proposed",
      inputs: [
        %Blocks.Input{name: "title", label: "Title", kind: "text", value: "original"}
      ]
    }

    editing = %{
      model(page("step_form"))
      | plan: %Blocks.Plan{title: "Plan", request: "request", state: "proposed", steps: [step]},
        steps: %{selected: 0, dropped: MapSet.new(), values: %{}, editing: 1},
        values: %{"title" => "unsaved? actual step draft"},
        cursor: {0, 5}
    }

    opened = press(editing, {:char, "l"})
    assert opened.console.legend != nil
    assert press(opened, :enter).steps.editing == 1
    restored = press(opened, :esc)
    assert restored.values == editing.values
    assert restored.steps == editing.steps
    assert restored.cursor == editing.cursor
    assert Interactions.context(restored) == "step_form"
  end

  test "unavailable close binding cannot create a trapped modal or a local fallback" do
    p =
      page()
      |> update_in(["blocks"], fn blocks ->
        Enum.map(blocks, fn a ->
          if a["id"] == "close", do: put_in(a, ["props", "available"], false), else: a
        end)
      end)

    m = press(model(p), {:char, "?"})
    assert m.console.legend == nil
    assert m.notice.text =~ "unavailable"
  end

  test "long rows wrap in aligned columns, scrolling is bounded and resize clamps the viewport" do
    extras =
      for n <- 1..12,
          do:
            action("long#{n}", "#{n |> rem(10)}", "refresh", %{
              "label" => "Action #{n}: " <> String.duplicate("long readable label ", 3),
              "available" => false
            })

    m = model(page("browse", extras)) |> press({:char, "?"}) |> Legend.resize(30, 13)
    text = screen(m, 30, 13)
    assert text =~ "below"
    assert length(String.split(text, "\n")) == 13
    assert Enum.all?(String.split(text, "\n"), &(String.length(&1) <= 30))
    scrolled = Enum.reduce(1..300, m, fn _, acc -> press(acc, :down) end)
    geometry = LegendView.geometry(scrolled, 30, 6)
    assert scrolled.console.legend.scroll == geometry.max_scroll
    assert press(scrolled, :down).console.legend.scroll == geometry.max_scroll
    assert press(scrolled, :up).console.legend.scroll == max(geometry.max_scroll - 1, 0)
    assert scrolled.selected == m.selected
    assert scrolled.scroll == m.scroll
    resized = Legend.resize(scrolled, 120, 45)
    assert resized.console.legend.scroll <= LegendView.geometry(resized, 120, 38).max_scroll
    assert screen(resized, 120, 45) =~ "Close keys"
  end
end
