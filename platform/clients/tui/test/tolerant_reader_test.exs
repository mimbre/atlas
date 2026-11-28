defmodule AtlasTui.TolerantReaderTest do
  # D-0105: a TUI reads any Control's pages, older or newer than its own contract. Every
  # property is optional to it: a block without the ones it uses still draws (what it
  # lacks left out, or the block plainly), keys still work, and the rest of the page shows.
  use ExUnit.Case, async: true
  alias AtlasTui.{Blocks, Model, View}

  @row %{
    "type" => "list",
    "id" => "things",
    "props" => %{"title" => "Things", "rows" => [%{"id" => "T-1", "label" => "Still here"}]}
  }

  defp page(blocks, markup \\ []),
    do: %{
      "op" => "page",
      "path" => "/k/thing",
      "title" => "Things",
      "reason" => "open",
      "blocks" => blocks,
      "markup" => markup
    }

  # As Control sent it: no projection made from the blocks here (that is Control's).
  defp model(page), do: AtlasTui.ConsoleProjectionFixture.projected(page, page)
  defp screen(model), do: model |> View.render(100, 40, 5) |> View.plain()

  test "every block of the contract, without any property, draws and leaves the page usable" do
    for {type, _} <- AtlasBFFContract.Contract.__schema__().blocks |> Enum.map(&{&1.name, &1}),
        props <- [%{}, nil] do
      block = %{"type" => to_string(type), "id" => "b"}
      block = if props, do: Map.put(block, "props", props), else: block
      m = model(page([block, @row]))

      text = screen(m)
      assert text =~ "Still here", "#{type} without props hides the rest of the page"

      for key <- [:down, :up, :tab, :enter, :esc, :backspace, :ctrl_s, {:char, "x"}, {:char, "c"}] do
        {after_key, _effects} = Model.key(m, key)
        _ = screen(after_key)
      end
    end
  end

  test "markup of a newer kind, or without its properties, leaves its blocks as they are" do
    markup = [
      %{"kind" => "sparkle", "start" => "things", "end" => "things", "props" => %{"x" => 1}},
      %{"kind" => "section", "start" => "things", "end" => "things"}
    ]

    assert screen(model(page([@row], markup))) =~ "Still here"
  end

  test "an older TUI meets a newer block: its title and words show, plainly" do
    newer = %{
      "type" => "timeline",
      "id" => "t",
      "props" => %{
        "title" => "Release plan",
        "text" => "Three steps left",
        "to" => "/k/plan/1",
        "entries" => [%{"label" => "Build", "value" => "done"}, %{"label" => "Ship"}]
      }
    }

    assert %Blocks.Fallback{title: "Release plan"} = Blocks.decode(newer)
    text = screen(model(page([newer, @row])))

    for words <- ["Release plan", "Three steps left", "Build: done", "Ship", "Still here"],
        do: assert(text =~ words)

    refute text =~ "/k/plan/1"
  end

  test "the defined unknown block uses the same plain rendering as an unrecognized type" do
    props = %{"title" => "Example", "text" => "First", "lines" => ["Second", "Third"]}
    defined = %{"type" => "unknown", "id" => "example", "props" => props}
    future = %{defined | "type" => "future_block"}

    assert %Blocks.Unknown{title: "Example", text: "First", lines: ["Second", "Third"]} =
             Blocks.decode(defined)

    assert %Blocks.Fallback{type: "future_block", reason: "unknown block"} = Blocks.decode(future)
    assert screen(model(page([defined, @row]))) == screen(model(page([future, @row])))

    empty = %{defined | "props" => %{}}
    assert screen(model(page([empty, @row]))) =~ "(a unknown block this TUI cannot show)"
    assert screen(model(page([empty, @row]))) =~ "Still here"
  end

  test "a property of another type than this TUI knows is left out, never a crash" do
    odd = %{"type" => "list", "id" => "odd", "props" => %{"title" => 7, "rows" => "many"}}
    assert screen(model(page([odd, @row]))) =~ "Still here"
  end
end
