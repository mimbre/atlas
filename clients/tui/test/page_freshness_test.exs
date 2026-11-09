defmodule AtlasTui.PageFreshnessTest do
  @moduledoc """
  The client side of page freshness (docs/design/page-freshness.md §3): every page Control
  sends is kept per path; back and a tab switch show the kept page at once and ask for
  it again; a page that replaces the list on screen keeps the selection by
  `AtlasTui.Selection`; a row Control marks pending says so. The TUI decides nothing.
  """
  use ExUnit.Case, async: true

  alias AtlasTui.{ConsoleProjectionFixture, Model, PageCache, View}

  @tabs [
    %{"id" => "assigned", "label" => "Assigned to you", "to" => "/"},
    %{"id" => "open", "label" => "Open work", "to" => "/k/part"}
  ]

  # A list page; a row is `key` or `{key, pending}`.
  defp list(path, rows, opts) do
    %{
      "op" => "page",
      "path" => path,
      "title" => "List #{path}",
      "reason" => opts[:reason] || "open",
      "position" => opts[:position],
      "blocks" => [
        %{
          "type" => "list",
          "props" => %{
            "title" => "List #{path}",
            "rows" =>
              for row <- rows do
                {key, pending} = if is_tuple(row), do: row, else: {row, nil}
                to = "/k/widget/#{key}"
                base = %{"label" => "Widget #{key}", "to" => to, "key" => key}
                if pending, do: Map.put(base, "pending", true), else: base
              end
          }
        }
      ]
    }
  end

  defp assigned(rows, opts), do: list("/", rows, opts)
  defp open_work(rows, opts), do: list("/k/part", rows, opts)

  defp item(key, opts) do
    %{
      "op" => "page",
      "path" => "/k/widget/#{key}",
      "title" => "Widget #{key}",
      "reason" => opts[:reason] || "open",
      "position" => opts[:position],
      "blocks" => [
        %{"type" => "item", "props" => %{"title" => "Widget #{key}", "fields" => []}}
      ]
    }
  end

  defp start(page) do
    model = Model.new("test")

    model = %{
      model
      | connected: true,
        console: %{
          model.console
          | phase: :ready,
            stale: false,
            shell: %{"revision" => "fixture", "title" => "Atlas Console", "tabs" => @tabs}
        }
    }

    receive!(model, page)
  end

  defp receive!(model, page) do
    {model, []} = ConsoleProjectionFixture.receive(model, page)
    model
  end

  defp press(model, keys) do
    Enum.reduce(List.wrap(keys), {model, []}, fn key, {model, _} -> Model.key(model, key) end)
  end

  # Press `key`, which must open `page`, and let Control's page arrive.
  defp go(model, key, page) do
    to = page["path"]
    assert {model, [{:send, %{"op" => "open", "to" => ^to}}]} = press(model, key)
    receive!(model, page)
  end

  defp labels(model), do: Enum.map(Model.rows(model), & &1.label)
  defp selected(model), do: Enum.at(Model.rows(model), model.selected).key
  defp screen(model), do: model |> View.render(90, 20, 5) |> View.plain()

  test "a page for a path not on screen is kept, not drawn" do
    m = start(assigned(~w(W-1 W-2), position: 1)) |> go(:enter, item("W-1", position: 1))
    shown = {m.path, m.blocks, m.selected}

    m = receive!(m, assigned(~w(W-2), reason: "hint", position: 2))
    assert {m.path, m.blocks, m.selected} == shown
    assert PageCache.get(m.console.cache, "/")["position"] == 2
  end

  test "back shows the kept page at once, with the selection left, and asks for it again" do
    m = start(assigned(~w(W-1 W-2 W-3), position: 1))
    {m, []} = press(m, :down)
    m = go(m, :enter, item("W-2", position: 1))

    # Control pushes the list the user came from: a row was added before W-2.
    m = receive!(m, assigned(~w(W-0 W-1 W-2 W-3), reason: "hint", position: 2))

    assert {m, [{:send, %{"op" => "open", "to" => "/"}}]} = press(m, :esc)
    assert m.path == "/"
    assert labels(m) == ["Widget W-0", "Widget W-1", "Widget W-2", "Widget W-3"]
    assert selected(m) == "W-2"
    assert m.updated.reason == "cache"
    assert screen(m) =~ "from cache"

    # The fresh copy replaces it under the same rule: W-2 left, the row at its index.
    m = receive!(m, assigned(~w(W-0 W-1 W-3), position: 3))
    assert selected(m) == "W-3"
    assert m.updated.reason == "open"
    assert m.console.expected == nil
  end

  test "an older page does not replace the kept one; back shows the newer" do
    m = start(assigned(~w(W-1), position: 1)) |> go(:enter, item("W-1", position: 1))
    m = receive!(m, assigned(~w(W-1 W-2), reason: "hint", position: 5))
    m = receive!(m, assigned(~w(W-1), reason: "hint", position: 4))

    {m, [_open]} = press(m, :esc)
    assert labels(m) == ["Widget W-1", "Widget W-2"]
  end

  test "without a kept page, back waits for Control and restores the selection left" do
    m = start(assigned(~w(W-1 W-2), position: 1))
    {m, []} = press(m, :down)
    m = go(m, :enter, item("W-2", position: 1))
    m = %{m | console: %{m.console | cache: PageCache.new()}}

    {m, [{:send, %{"to" => "/"}}]} = press(m, :esc)
    assert m.path == "/k/widget/W-2"
    m = receive!(m, assigned(~w(W-2 W-1), position: 2))
    assert selected(m) == "W-2"
  end

  test "a tab switch shows the tab's kept page at once, with the selection it was left with" do
    m = start(assigned(~w(W-1 W-2), position: 1))
    {m, []} = press(m, :down)
    m = go(m, :tab, open_work(~w(W-7), position: 1))

    assert {m, [{:send, %{"op" => "open", "to" => "/"}}]} = press(m, :tab)
    assert m.path == "/"
    assert m.console.active == "assigned"
    assert selected(m) == "W-2"
    assert m.updated.reason == "cache"
  end

  test "a page for the path on screen keeps the selected key, wherever its row moved" do
    m = start(assigned(~w(W-1 W-2 W-3), position: 1))
    {m, []} = press(m, :down)
    m = receive!(m, assigned(~w(W-3 W-0 W-1 W-2), reason: "hint", position: 2))
    assert selected(m) == "W-2"
  end

  test "a row Control marks pending says so beside its label; others do not" do
    m = start(assigned([{"W-1", true}, "W-2"], position: 1))
    [marked, plain] = m |> screen() |> String.split("\n") |> Enum.filter(&(&1 =~ "Widget W-"))
    assert marked =~ ~r/Widget W-1\s+⋯ being processed/
    refute plain =~ "being processed"

    m = receive!(m, assigned(~w(W-1 W-2), reason: "hint", position: 2))
    refute screen(m) =~ "being processed"
  end

  test "a submit changes no row before Control sends a page" do
    form = %{
      "op" => "page",
      "path" => "/k/widget/W-1/edit",
      "title" => "Edit",
      "reason" => "open",
      "blocks" => [
        %{
          "type" => "form",
          "props" => %{
            "title" => "Edit",
            "submit_label" => "Keep",
            "submit_to" => %{"endpoint" => "update", "params" => %{"key" => "W-1"}},
            "inputs" => [%{"name" => "title", "label" => "Title", "kind" => "text"}]
          }
        }
      ]
    }

    m = start(assigned(~w(W-1 W-2), position: 1))
    {m, [_open]} = AtlasTui.Console.open(m, form["path"])
    m = receive!(m, form)
    {after_submit, [{:send, %{"op" => "submit"}}]} = press(m, :ctrl_s)
    assert after_submit.blocks == m.blocks
    assert after_submit.console.cache == m.console.cache
  end

  # §3.1, worked through as page messages.
  describe "working through a list" do
    setup do
      m = start(assigned(~w(A B C), position: 1))
      {m, []} = press(m, :down)
      m = go(m, :enter, item("B", position: 1))
      # The answer is stored; Control pushes the list with B marked.
      m = receive!(m, assigned(["A", {"B", true}, "C"], reason: "pending", position: 1))
      {m, [_open]} = press(m, :esc)
      %{m: m}
    end

    test "back shows B marked and still selected; moved on, the settled list keeps C", %{m: m} do
      assert selected(m) == "B"
      assert screen(m) =~ "being processed"

      # Moving on while the list is asked for again.
      {m, []} = press(m, :down)
      assert selected(m) == "C"
      m = receive!(m, assigned(["A", {"B", true}, "C"], position: 2))
      assert selected(m) == "C"

      m = receive!(m, assigned(~w(A C), reason: "hint", position: 3))
      assert selected(m) == "C"
      refute screen(m) =~ "being processed"
    end

    test "not moved: B leaves the list and the row at its place, C, is selected", %{m: m} do
      m = receive!(m, assigned(["A", {"B", true}, "C"], position: 2))
      m = receive!(m, assigned(~w(A C), reason: "hint", position: 3))
      assert selected(m) == "C"
    end
  end
end
