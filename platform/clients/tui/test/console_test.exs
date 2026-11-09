defmodule AtlasTui.ConsoleTest do
  use ExUnit.Case, async: true
  alias AtlasTui.{Console, Model, Protocol, View}

  defp fresh, do: %{Model.new("test") | console: Console.new()}

  defp welcome,
    do: %{
      "op" => "welcome",
      "env" => "test",
      "spec" => Protocol.version(),
      "surface" => "console"
    }

  defp page(path \\ "/k/widget", reason \\ "open") do
    %{
      "op" => "page",
      "path" => path,
      "title" => "Widgets",
      "reason" => reason,
      "blocks" => [
        %{
          "id" => "widgets",
          "type" => "list",
          "props" => %{
            "title" => "Widgets",
            "rows" => [
              %{"id" => "W1", "label" => "First", "to" => "/k/widget/W1"},
              %{"id" => "W2", "label" => "Second", "to" => "/k/widget/W2"}
            ]
          }
        }
      ]
    }
  end

  defp boot(target \\ "/k/widget") do
    %{
      "op" => "boot",
      "title" => "Atlas Console",
      "env" => "test",
      "spec" => Protocol.version(),
      "revision" => "rev1",
      "initial_to" => target,
      "active_tab" => "widgets",
      "tabs" => [
        %{"id" => "widgets", "label" => "Widgets", "to" => "/k/widget"},
        %{"id" => "parts", "label" => "Parts", "to" => "/k/part"},
        %{"id" => "open", "label" => "Open work", "to" => "/k/work"}
      ]
    }
  end

  defp handshake(model \\ fresh()) do
    {model, []} = Console.receive(model, welcome())
    {model, [{:send, %{"op" => "boot"}}]} = Console.receive(model, page("/"))
    model
  end

  defp ready do
    {model, [{:send, %{"op" => "open", "to" => "/k/widget"}}]} =
      Console.receive(handshake(), boot())

    {model, []} = Console.receive(model, page())
    model
  end

  # A page that is not drawn is still kept for its path, and changes nothing else.
  defp assert_only_kept(model, message) do
    {kept, []} = Console.receive(model, message)
    assert AtlasTui.PageCache.get(kept.console.cache, message["path"]) == message
    assert put_in(kept.console.cache, model.console.cache) == model
  end

  defp screen(model, width \\ 80), do: model |> View.render(width, 20, 5) |> View.plain()

  test "compatibility page is discarded; native boot opens content inside persistent tabs" do
    model = handshake()
    assert model.path == nil
    assert model.blocks == []
    {model, [_]} = Console.receive(model, boot())
    {model, []} = Console.receive(model, page())
    assert model.console.phase == :ready
    assert model.console.active == "widgets"
    text = screen(model)

    for label <- ["Atlas Console · test", "▸ Widgets", "Parts", "Open work", "First"],
        do: assert(text =~ label)

    refute text =~ "Home"
    refute text =~ "tab next part"
  end

  test "only an explicit compatible welcome enables Console" do
    for welcome <- [
          Map.delete(welcome(), "surface"),
          Map.put(welcome(), "env", "prod"),
          Map.put(welcome(), "spec", "999.0.0")
        ] do
      {model, []} = Console.receive(fresh(), welcome)
      refute model.connected
      assert model.console.phase == :unsupported
      assert screen(model) =~ "did not acknowledge"
      {model, []} = Console.receive(model, page())
      assert model.path == nil
    end
  end

  test "invalid boot retains stale last good shell and recovers independently of content" do
    model = ready()

    for invalid <- [
          %{"op" => "boot", "error" => "Facts unavailable"},
          Map.put(boot(), "tabs", []),
          Map.put(boot(), "env", "prod"),
          put_in(boot(), ["tabs", Access.at(0), "to"], "/k/widget/W1"),
          put_in(boot(), ["tabs", Access.at(0), "label"], 42),
          Map.put(boot(), "initial_to", "/unknown"),
          Map.put(boot(), "tabs", [hd(boot()["tabs"]), hd(boot()["tabs"])])
        ] do
      {pending, [_]} = Console.refresh(model)
      {stale, []} = Console.receive(pending, invalid)
      assert stale.console.shell == model.console.shell
      assert stale.console.stale
      assert screen(stale) =~ "stale shell"
      assert screen(stale) =~ "▸ Widgets"
      {pending, [_]} = Console.refresh(stale)
      {recovered, []} = Console.receive(pending, Map.put(boot(), "revision", "rev2"))
      refute recovered.console.stale
      assert recovered.console.shell["revision"] == "rev2"
      assert recovered.path == model.path
    end
  end

  test "one boot in flight; unsolicited replies and interleaved compatibility pages have no authority" do
    model = fresh()
    assert Console.receive(model, boot()) == {model, []}
    model = handshake()
    assert Console.refresh(model) == {model, []}
    {model, []} = Console.receive(model, page("/"))
    assert model.path == nil
  end

  test "reconnect preserves actual edited form values, cursor and focus through all pages" do
    form = %{
      "op" => "page",
      "path" => "/k/widget/W1/edit",
      "reason" => "open",
      "blocks" => [
        %{
          "id" => "editor",
          "type" => "form",
          "props" => %{
            "title" => "Edit",
            "inputs" => [
              %{
                "name" => "title",
                "label" => "Title",
                "kind" => "text",
                "value" => "server default"
              }
            ],
            "submit_label" => "Save",
            "submit_to" => %{
              "endpoint" => "update",
              "params" => %{"kind" => "widget", "key" => "W1"}
            },
            "cancel_to" => "/k/widget/W1"
          }
        }
      ]
    }

    {model, []} = Console.receive(ready(), form)
    {model, []} = Model.key(model, {:char, "!"})
    assert model.values["title"] == "server default!"
    model = %{model | cursor: {0, 4}, focus: 1}
    disconnected = %{Model.disconnected(model) | closed: true}
    assert screen(disconnected) =~ "stale shell"
    pending = handshake(disconnected)
    refute pending.closed
    assert pending.values == model.values
    assert pending.path == model.path

    {pending, [{:send, %{"to" => "/k/widget/W1/edit"}}]} =
      Console.receive(pending, boot(model.path))

    {pending, []} = Console.receive(pending, page("/"))
    assert pending.values == model.values
    {restored, []} = Console.receive(pending, form)
    assert restored.values == model.values
    assert restored.cursor == {0, 4}
    assert restored.focus == 1
    assert restored.console.phase == :ready
    assert restored.console.active == "widgets"
    {pending, [_]} = Console.refresh(restored)
    {pending, []} = Console.receive(pending, boot("/k/part"))
    assert pending.path == model.path
    {hinted, []} = Console.receive(pending, Map.put(form, "reason", "hint"))
    assert hinted.values == model.values
  end

  test "cycling operations wrap and reject stale/disconnected/modal navigation" do
    model = ready()
    {previous, [{:send, %{"to" => "/k/work"}}]} = Console.cycle(model, -1)
    {previous, []} = Console.receive(previous, page("/k/work"))
    assert previous.console.active == "open"
    {next, [{:send, %{"to" => "/k/widget"}}]} = Console.cycle(previous, 1)
    {next, []} = Console.receive(next, page())
    assert next.console.active == "widgets"

    for blocked <- [
          Model.disconnected(model),
          %{model | ask: "literal ?"},
          %{model | console: %{model.console | stale: true}}
        ] do
      assert Console.cycle(blocked, 1) == {blocked, []}
    end
  end

  test "rapid tab keys select immediately and coalesce pending requests without showing stale content" do
    projected =
      declared(page(), "browse", [
        action("next", "Tab", "tab_next"),
        action("previous", "Shift+Tab", "tab_previous"),
        action("row", "Down", "move_next")
      ])

    {model, []} = Console.receive(ready(), projected)
    {parts, [{:send, %{"to" => "/k/part"}}]} = Model.key(model, :tab)
    assert parts.console.active == "parts"
    assert screen(parts) =~ "▸ Parts"
    assert screen(parts) =~ "Loading"
    refute screen(parts) =~ "First"
    assert Model.key(parts, :down) == {parts, []}

    {work, []} = Model.key(parts, :tab)
    assert work.console.active == "open"
    assert screen(work) =~ "▸ Open work"
    {widgets, []} = Model.key(work, :tab)
    assert widgets.console.active == "widgets"
    {work, []} = Model.key(widgets, :shift_tab)
    assert work.console.active == "open"
    assert_only_kept(work, page("/k/part", "hint"))

    {pending, [{:send, %{"to" => "/k/work"}}]} =
      Console.receive(work, page("/k/part"))

    assert pending.console.active == "open"
    assert screen(pending) =~ "Loading"
    refute screen(pending) =~ "First"
    assert_only_kept(pending, page("/k/part", "reconcile"))
    {loaded, []} = Console.receive(pending, page("/k/work"))
    assert loaded.console.active == "open"
    assert loaded.path == "/k/work"
    assert loaded.console.expected == nil
    assert screen(loaded) =~ "First"
    assert_only_kept(loaded, page("/k/part", "hint"))
  end

  test "an unsuperseded open accepts a canonical redirect" do
    {pending, [_]} = Console.navigate(ready(), "/k/widget/W1")
    {redirected, []} = Console.receive(pending, page("/k/widget/W2"))
    assert redirected.path == "/k/widget/W2"
    assert redirected.console.expected == nil
    assert redirected.console.in_flight == nil
  end

  test "an already pending boot reply cannot undo immediate tab selection" do
    {model, [_]} = Console.refresh(ready())
    {pending, [_]} = Console.cycle(model, 1)
    {updated, []} = Console.receive(pending, boot())
    assert updated.console.active == "parts"
    assert updated.console.expected == "/k/part"
    assert Console.refresh(updated) == {updated, []}
  end

  test "deep links retain parent tab; tab return restores selected identity across reorder" do
    model = %{ready() | selected: 1}
    {other, [_]} = Console.cycle(model, 1)
    {other, []} = Console.receive(other, page("/k/part"))
    {back, [_]} = Console.cycle(other, -1)
    reordered = update_in(page(), ["blocks", Access.at(0), "props", "rows"], &Enum.reverse/1)
    {back, []} = Console.receive(back, reordered)
    assert back.selected == 0
    {detail, []} = Console.receive(back, page("/k/widget/W2"))
    assert detail.console.active == "widgets"
  end

  test "narrow viewport follows active tab and resize preserves shell and content" do
    {model, [_]} = Console.cycle(ready(), -1)
    {model, []} = Console.receive(model, page("/k/work"))

    for width <- [16, 20, 40, 100] do
      text = screen(model, width)
      assert text =~ "▸ Open work"
      assert length(String.split(text, "\n")) == 20
      assert Enum.all?(String.split(text, "\n"), &(String.length(&1) <= width))
    end

    assert screen(model, 16) =~ "‹"
    assert screen(model, 100) =~ "Widgets"
  end

  # Private approved-design fixtures, replaced by actual IS120 projection in the
  # integrated proof. No production key/legend defaults exist in the renderer.
  defp action(id, key, name, extra \\ %{}) do
    %{
      "id" => id,
      "type" => "console_action",
      "props" =>
        Map.merge(
          %{
            "label" => id,
            "keys" => [key],
            "operation" => %{"name" => name},
            "available" => true
          },
          extra
        )
    }
  end

  defp declared(page, context, actions) do
    actions =
      Enum.map(actions, fn action ->
        put_in(
          action,
          ["props", "scope"],
          Map.merge(
            %{
              "page" => page["path"],
              "revision" => "fixture",
              "context" => context
            },
            action["props"]["scope"] || %{}
          )
        )
      end)

    page
    |> Map.put("actions_revision", "fixture")
    |> Map.update!("blocks", &(&1 ++ actions))
    |> Map.put("markup", [
      %{
        "kind" => "legend",
        "start" => hd(actions)["id"],
        "end" => List.last(actions)["id"],
        "props" => %{"title" => "Navigation", "context" => context}
      }
    ])
  end

  test "fixture-declared bindings alone cycle tabs and arrows retain list movement" do
    page =
      declared(page(), "browse", [
        action("next", "Tab", "tab_next"),
        action("previous", "Shift+Tab", "tab_previous"),
        action("down", "Down", "move_next")
      ])

    {model, []} = Console.receive(ready(), page)
    {down, []} = Model.key(model, :down)
    assert down.selected == 1
    assert {_, [{:send, %{"to" => "/k/part"}}]} = Model.key(down, :tab)
    {previous, [{:send, %{"to" => "/k/work"}}]} = Model.key(model, :shift_tab)
    assert previous.console.expected == "/k/work"
    # Changing BFF keys changes execution; there is no local Tab fallback.
    custom = declared(page(), "browse", [action("next", "x", "tab_next")])
    {custom, []} = Console.receive(model, custom)
    assert Model.key(custom, :tab) == {custom, []}
    assert {_, [{:send, %{"to" => "/k/part"}}]} = Model.key(custom, {:char, "x"})
  end

  test "captured action cannot execute after page, context, row, availability or connection changes" do
    alias AtlasTui.Interactions
    projected = declared(page(), "browse", [action("down", "Down", "move_next")])
    {model, []} = Console.receive(ready(), projected)
    event = Interactions.capture(model, :down)
    assert event.id == "down"
    {changed, []} = Console.receive(model, Map.put(projected, "reason", "hint"))

    for stale <- [
          changed,
          %{model | selected: 1},
          %{model | ask: "draft"},
          Model.disconnected(model)
        ] do
      assert Interactions.dispatch(stale, event) == {stale, []}
    end

    disabled =
      declared(page(), "browse", [action("down", "Down", "move_next", %{"available" => false})])

    {disabled, []} = Console.receive(model, disabled)
    assert Model.key(disabled, :down) == {disabled, []}
    replaced = declared(page("/k/part"), "browse", [action("down", "Down", "move_next")])
    {replaced, []} = Console.receive(model, replaced)
    assert Interactions.dispatch(replaced, event) == {replaced, []}
    refute screen(model) =~ "console_action"
  end

  test "editing context traverses form focus and keeps literal question mark and actual values" do
    form = %{
      "op" => "page",
      "path" => "/k/widget/new",
      "blocks" => [
        %{
          "id" => "editor",
          "type" => "form",
          "props" => %{
            "title" => "Create",
            "inputs" => [
              %{"name" => "title", "label" => "Title", "kind" => "text", "value" => ""}
            ],
            "submit_label" => "Save",
            "submit_to" => %{"endpoint" => "create", "params" => %{"kind" => "widget"}}
          }
        }
      ]
    }

    form =
      declared(form, "form", [
        action("focus", "Tab", "focus_next"),
        action("back-focus", "Shift+Tab", "focus_previous")
      ])

    {model, []} = Console.receive(ready(), form)
    {model, []} = Model.key(model, {:char, "?"})
    assert model.values["title"] == "?"
    {model, []} = Model.key(model, :tab)
    assert model.focus == 1
    {model, []} = Model.key(model, :shift_tab)
    assert model.focus == 0
    assert model.path == "/k/widget/new"
    assert model.values["title"] == "?"
  end

  test "worker overview boots as a tab and removal falls back without retargeting its detail" do
    shell =
      boot("/workers")
      |> Map.put("tabs", [
        %{"id" => "workers", "label" => "Workers", "to" => "/workers"} | boot()["tabs"]
      ])
      |> Map.put("active_tab", "workers")

    {model, [{:send, %{"to" => "/workers"}}]} = Console.receive(handshake(), shell)
    {model, []} = Console.receive(model, page("/workers"))
    assert model.console.active == "workers"
    {pending, [_]} = Console.refresh(model)
    {fallback, [{:send, %{"to" => "/k/widget"}}]} = Console.receive(pending, boot())
    assert fallback.console.expected == "/k/widget"

    path = "/workers/box/W-1/R-1/attempt-1"
    {detail, _history_read} = Console.receive(model, page(path))
    {pending, [_]} = Console.refresh(detail)
    {preserved, []} = Console.receive(pending, %{boot(path) | "active_tab" => nil})
    assert preserved.path == path
    assert preserved.console.active == nil

    for invalid <- [path, path <> "/guidance"] do
      {pending, [_]} = Console.refresh(model)

      {rejected, []} =
        Console.receive(pending, put_in(shell, ["tabs", Access.at(0), "to"], invalid))

      assert rejected.console.stale
    end
  end

  test "removed index falls back on boot reconciliation without replacing a valid deep link" do
    model = ready()

    shell =
      boot("/k/part") |> Map.put("tabs", tl(boot()["tabs"])) |> Map.put("active_tab", "parts")

    {pending, [_]} = Console.refresh(model)
    {fallback, [{:send, %{"to" => "/k/part"}}]} = Console.receive(pending, shell)
    assert fallback.path == "/k/widget"
    {detail, []} = Console.receive(model, page("/k/widget/W1"))
    {pending, [_]} = Console.refresh(detail)

    {preserved, []} =
      Console.receive(pending, %{shell | "initial_to" => detail.path, "active_tab" => nil})

    assert preserved.path == detail.path
    assert preserved.console.active == nil
  end

  test "boot reconciliation preserves an overview opened outside configured tabs" do
    {agents, []} = Console.receive(ready(), page("/k/agent"))
    {pending, [_]} = Console.refresh(agents)
    {preserved, []} = Console.receive(pending, boot())
    assert preserved.path == "/k/agent"
    assert preserved.console.expected == nil
    assert preserved.console.active == nil
  end

  test "typed confirm actions submit the supplied call and cancel restores the declared target" do
    confirm = %{
      "op" => "page",
      "path" => "/k/widget/W1/delete",
      "reason" => "open",
      "blocks" => [
        %{
          "id" => "question",
          "type" => "confirm",
          "props" => %{
            "title" => "Delete widget?",
            "text" => "Confirm",
            "confirm_to" => %{
              "endpoint" => "delete",
              "params" => %{"kind" => "widget", "key" => "W1"}
            },
            "cancel_to" => "/k/widget/W1"
          }
        }
      ]
    }

    confirm =
      declared(confirm, "confirm", [
        action("yes", "y", "submit_form"),
        action("no", "Esc", "cancel_form")
      ])

    {model, []} = Console.receive(ready(), confirm)

    assert {_,
            [{:send, %{"op" => "submit", "endpoint" => "delete", "params" => %{"key" => "W1"}}}]} =
             Model.key(model, {:char, "y"})

    assert {_, [{:send, %{"op" => "open", "to" => "/k/widget/W1"}}]} = Model.key(model, :esc)
    assert Model.key(model, :tab) == {model, []}
  end

  test "typed ask and plan contexts execute only declared actions while preserving literal text" do
    alias AtlasTui.Interactions

    ask_page =
      declared(page(), "ask", [
        action("send", "Enter", "ask_send"),
        action("cancel", "Esc", "ask_cancel")
      ])

    {model, []} = Console.receive(ready(), ask_page)
    model = %{model | ask: "make parts"}
    {model, []} = Model.key(model, {:char, "?"})
    assert screen(model) =~ "Request make parts?"
    refute screen(model) =~ "↵ ask the agent"
    assert Interactions.context(model) == "ask"

    {planning, [{:agent, %{"op" => "ask", "request" => "make parts?"}}]} =
      Model.key(model, :enter)

    assert Interactions.context(planning) == "plan_planning"

    proposed_page =
      declared(page(), "plan_proposed", [
        action("run", "Enter", "plan_run"),
        action("edit", "e", "plan_edit")
      ])

    {planning, []} = Console.receive(planning, proposed_page)

    plan = %{
      "op" => "plan",
      "block" => %{
        "type" => "plan",
        "props" => %{
          "title" => "Proposed",
          "request" => "make parts?",
          "state" => "proposed",
          "steps" => [
            %{
              "n" => 1,
              "label" => "Create",
              "state" => "proposed",
              "inputs" => [
                %{"name" => "title", "label" => "Title", "kind" => "text", "value" => "One"}
              ]
            }
          ]
        }
      }
    }

    proposed = Model.agent(planning, plan)
    assert Interactions.context(proposed) == "plan_proposed"
    {editing, []} = Model.key(proposed, {:char, "e"})
    assert Interactions.context(editing) == "step_form"
    assert editing.values["title"] == "One"

    step_page =
      declared(page(), "step_form", [
        action("save", "Ctrl+S", "step_save"),
        action("cancel", "Esc", "step_cancel")
      ])

    {editing, []} = Console.receive(editing, Map.put(step_page, "reason", "hint"))
    {editing, []} = Model.key(editing, {:char, "!"})
    assert editing.values["title"] == "One!"
    {saved, []} = Model.key(editing, :ctrl_s)
    assert saved.steps.editing == nil
    assert saved.steps.values[1]["title"] == "One!"
    assert Interactions.context(saved) == "plan_proposed"
  end

  test "unknown operations, tokens and inconsistent scopes disable projection visibly" do
    for {field, value} <- [
          {"operation", %{"name" => "system_eval"}},
          {"keys", ["NoSuchKey"]},
          {"scope", %{"page" => "/k/part", "revision" => "r", "context" => "browse"}}
        ] do
      projected = declared(page(), "browse", [action("next", "Tab", "tab_next")])
      projected = put_in(projected, ["blocks", Access.at(1), "props", field], value)
      {model, []} = Console.receive(ready(), projected)
      assert model.console.projection == nil
      assert screen(model) =~ "Unsupported or invalid Console actions"
      assert Model.key(model, :tab) == {model, []}
    end

    conflict =
      declared(page(), "browse", [
        action("a", "Tab", "tab_next"),
        action("b", "Tab", "tab_previous")
      ])

    {model, []} = Console.receive(ready(), conflict)
    assert model.console.projection == nil
  end

  test "canonical response to a declared generic deep link is accepted after navigation" do
    {pending, [{:send, %{"to" => "/k/_/W1"}}]} = Console.navigate(ready(), "/k/_/W1")
    {opened, []} = Console.receive(pending, page("/k/widget/W1"))
    assert opened.path == "/k/widget/W1"
    assert opened.console.active == "widgets"
  end

  test "row scope includes its content block when two lists have the same row id" do
    projected = page()
    first = hd(projected["blocks"])

    second =
      first
      |> Map.put("id", "second-list")
      |> put_in(["props", "rows"], [
        %{"id" => "W1", "label" => "Same id in another list", "to" => "/k/part/P1"}
      ])

    projected = Map.put(projected, "blocks", [first, second])

    scoped =
      action("open-part", "o", "open", %{
        "operation" => %{"name" => "open", "to" => "/k/part/P1"},
        "scope" => %{"on" => "second-list", "row" => "W1"}
      })

    projected = declared(projected, "browse", [scoped])
    {model, []} = Console.receive(ready(), projected)
    assert model.console.projection != nil
    assert Model.key(model, {:char, "o"}) == {model, []}
    {_, [{:send, %{"to" => "/k/part/P1"}}]} = Model.key(%{model | selected: 2}, {:char, "o"})
  end

  test "captured tab action expires on an independent shell revision change" do
    alias AtlasTui.Interactions
    projected = declared(page(), "browse", [action("next", "Tab", "tab_next")])
    {model, []} = Console.receive(ready(), projected)
    event = Interactions.capture(model, :tab)
    {pending, [_]} = Console.refresh(model)
    {same, []} = Console.receive(pending, boot())
    assert {_, [{:send, %{"to" => "/k/part"}}]} = Interactions.dispatch(same, event)
    {pending, [_]} = Console.refresh(model)
    {changed, []} = Console.receive(pending, Map.put(boot(), "revision", "changed"))
    assert Interactions.dispatch(changed, event) == {changed, []}
    assert changed.console.generation == model.console.generation
  end
end
