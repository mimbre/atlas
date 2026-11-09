defmodule AtlasTui.GoingBackTest do
  @moduledoc """
  Back (Esc, Left, b) returns to the page the user came from, in their own history in
  this TUI, as they left it: not to the parent Control names in a page's `back`.
  """
  use ExUnit.Case, async: true

  alias AtlasTui.{Console, ConsoleProjectionFixture, Interactions, Model}

  @tabs [
    %{"id" => "assigned", "label" => "Assigned to you", "to" => "/"},
    %{"id" => "open", "label" => "Open work", "to" => "/k/part"}
  ]

  defp list(path, title, rows, extra \\ %{}) do
    %{
      "op" => "page",
      "path" => path,
      "title" => title,
      "back" => extra["back"],
      "reason" => "open",
      "blocks" => [
        %{
          "type" => "list",
          "props" =>
            Map.merge(
              %{
                "title" => title,
                "rows" => for({label, to} <- rows, do: %{"label" => label, "to" => to})
              },
              Map.take(extra, ["actions"])
            )
        }
      ]
    }
  end

  # What waits for the user: rows of a kind whose own list is elsewhere.
  defp assigned,
    do:
      list("/", "Assigned to you", [{"Ask", "/k/widget/W-1"}, {"Plan", "/k/widget/W-2"}], %{
        "actions" => [%{"label" => "Widgets", "key" => "s", "to" => "/k/widget"}]
      })

  defp widgets do
    rows = for n <- 1..3, do: {"Widget #{n}", "/k/widget/W-#{n}"}
    list("/k/widget", "Widgets", rows, %{"back" => "/"})
  end

  defp open_work, do: list("/k/part", "Open work", [{"Part", "/k/part/P-1"}])

  # A fact's page: Control names its kind's list as the way back.
  defp widget(key, notes \\ 1) do
    %{
      "op" => "page",
      "path" => "/k/widget/#{key}",
      "title" => "Widget #{key}",
      "back" => "/k/widget",
      "reason" => "open",
      "blocks" => [
        %{
          "type" => "item",
          "props" => %{
            "title" => "Widget #{key}",
            "fields" => [
              %{"label" => "Notes", "value" => Enum.map_join(1..notes, "\n", &"Line #{&1}")}
            ],
            "actions" => [
              %{"label" => "Edit", "key" => "e", "to" => "/k/widget/#{key}/edit"}
            ]
          }
        },
        %{
          "type" => "list",
          "props" => %{
            "title" => "Parts",
            "rows" => [
              %{"label" => "Part one", "to" => "/k/part/P-1"},
              %{"label" => "Part two", "to" => "/k/part/P-2"}
            ]
          }
        }
      ]
    }
  end

  # A related fact whose parent, as Control has it, is a page the user never saw.
  defp part(key) do
    %{
      "op" => "page",
      "path" => "/k/part/#{key}",
      "title" => "Part #{key}",
      "back" => "/k/maker/M-1",
      "reason" => "open",
      "blocks" => [%{"type" => "item", "props" => %{"title" => "Part #{key}", "fields" => []}}]
    }
  end

  defp edit(key) do
    %{
      "op" => "page",
      "path" => "/k/widget/#{key}/edit",
      "title" => "Edit widget #{key}",
      "back" => "/k/widget/#{key}",
      "reason" => "open",
      "blocks" => [
        %{
          "type" => "form",
          "props" => %{
            "title" => "Edit widget #{key}",
            "submit_label" => "Keep",
            "submit_to" => %{"endpoint" => "update", "params" => %{"key" => key}},
            "cancel_to" => "/k/widget/#{key}",
            "inputs" => [%{"name" => "title", "label" => "Title", "kind" => "text"}]
          }
        }
      ]
    }
  end

  defp start do
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

    {model, []} = ConsoleProjectionFixture.receive(model, assigned())
    model
  end

  defp press(model, keys) when is_list(keys) do
    Enum.reduce(keys, {model, []}, fn key, {model, _} -> Model.key(model, key) end)
  end

  defp press(model, key), do: press(model, [key])

  # Press `key`, which must open `page`, and let Control's page arrive.
  defp go(model, key, page) do
    to = page["path"]
    assert {model, [{:send, %{"op" => "open", "to" => ^to}}]} = press(model, key)
    {model, []} = ConsoleProjectionFixture.receive(model, page)
    assert model.path == to
    model
  end

  defp selected(model), do: Enum.at(Model.rows(model), model.selected).to

  defp back_action(model),
    do: Enum.find(Interactions.active(model), &(&1["props"]["operation"]["name"] == "back"))

  test "a fact opened from Assigned to you goes back there in one step, its row still selected" do
    m = start()
    {m, []} = press(m, :down)
    m = m |> go(:enter, widget("W-2"))

    # Control names the kind's list; the user came from Assigned to you.
    assert m.back == "/k/widget"
    m = go(m, :esc, assigned())

    assert selected(m) == "/k/widget/W-2"
    assert m.console.active == "assigned"
    assert m.console.history == []
  end

  test "Esc, Left and b are all back" do
    for key <- [:esc, :left, {:char, "b"}] do
      m = start() |> go(:enter, widget("W-1"))
      assert go(m, key, assigned()).path == "/"
    end
  end

  test "a fact opened from a kind's list goes back to that list, then to where the list was opened" do
    m = start() |> go({:char, "s"}, widgets())
    {m, []} = press(m, [:down, :down])
    m = go(m, :enter, widget("W-3"))

    m = go(m, :esc, widgets())
    assert selected(m) == "/k/widget/W-3"

    m = go(m, :esc, assigned())
    assert selected(m) == "/k/widget/W-1"
  end

  test "two levels deep, back twice retraces the way, not the parents Control names" do
    m = start() |> go({:char, "s"}, widgets())
    {m, []} = press(m, :down)
    m = go(m, :enter, widget("W-2", 40))
    {m, []} = press(m, [:down, :page_down])
    assert m.scroll == 10
    scrolled = {m.scroll, m.scrolls, m.part}
    m = go(m, :enter, part("P-2"))

    assert m.back == "/k/maker/M-1"
    m = go(m, :esc, widget("W-2", 40))
    assert selected(m) == "/k/part/P-2"
    assert {m.scroll, m.scrolls, m.part} == scrolled

    m = go(m, :esc, widgets())
    assert selected(m) == "/k/widget/W-2"
  end

  test "back on a tab root does nothing, and Back shows as unavailable there" do
    m = start()
    assert %{"props" => %{"available" => false}} = back_action(m)

    for key <- [:esc, :left, {:char, "b"}] do
      assert press(m, key) == {m, []}
    end

    # Once a page was opened from it, the same root has a way back again.
    m = m |> go(:enter, widget("W-1")) |> go(:esc, assigned())
    assert press(m, :esc) == {m, []}
  end

  test "switching tabs starts afresh: back does not cross into the other tab" do
    m = start() |> go(:enter, widget("W-1"))
    assert %{"props" => %{"available" => true}} = back_action(m)

    m = go(m, :tab, open_work())
    assert m.console.history == []
    assert press(m, :esc) == {m, []}

    m = go(m, :enter, part("P-1"))
    assert go(m, :esc, open_work()).path == "/k/part"
  end

  test "a form's cancel returns to the page it was opened from, and back goes on from there" do
    m = start() |> go(:enter, widget("W-1"))
    m = go(m, {:char, "e"}, edit("W-1"))

    # In the form Esc is its cancel, to the form's declared target.
    m = go(m, :esc, widget("W-1"))
    assert [%{path: "/"}] = m.console.history

    assert go(m, :esc, assigned()).path == "/"
  end

  test "after a stored change the fact shows, and back skips the form" do
    m = start() |> go(:enter, widget("W-1"))
    m = go(m, {:char, "e"}, edit("W-1"))
    {m, [{:send, %{"op" => "submit"}}]} = press(m, :ctrl_s)

    {m, []} = ConsoleProjectionFixture.receive(m, %{widget("W-1") | "reason" => "stored"})
    assert m.path == "/k/widget/W-1"

    assert go(m, :esc, assigned()).path == "/"
  end

  test "the history is bounded: it keeps the newest pages left" do
    m = start() |> go(:enter, widget("W-1"))
    model = %{m | console: %{m.console | history: Enum.map(1..150, &%{path: "/k/part/P-#{&1}"})}}
    {m, _} = Console.open(model, "/k/part/P-1")
    assert length(m.console.history) == 100
    assert hd(m.console.history).path == "/k/widget/W-1"
  end
end
