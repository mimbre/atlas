defmodule AtlasTui.StepsPanelTest do
  use ExUnit.Case, async: true
  alias AtlasTui.{Clipboard, Model, View}

  defp text(text), do: %{"kind" => "text", "text" => text}
  defp command(command), do: %{"kind" => "command", "text" => command}
  defp route(parts), do: %{"kind" => "route", "parts" => parts}

  # A step as Control sends it: its lines in order, and its text, commands and routes.
  defp step(n, lines) do
    of = fn kind, key -> for %{"kind" => ^kind} = line <- lines, do: line[key] end

    %{
      "n" => n,
      "text" => Enum.join(of.("text", "text"), "\n"),
      "commands" => of.("command", "text"),
      "routes" => of.("route", "parts"),
      "lines" => lines
    }
  end

  defp page(steps \\ nil, current \\ 2) do
    path = "/k/widget/W-01"

    move = fn label, key, to ->
      %{
        "label" => label,
        "key" => key,
        "to" => path <> "/step/#{to}",
        "submit_to" => %{
          "endpoint" => "step",
          "params" => %{"kind" => "widget", "key" => "W-01", "step" => "#{to}"}
        }
      }
    end

    steps = %{
      "id" => "steps",
      "type" => "steps",
      "props" => %{
        "title" => "Set up the widget",
        "why" => "The widget needs a home.",
        "since" => DateTime.utc_now() |> DateTime.add(-3 * 3600) |> DateTime.to_iso8601(),
        "current" => current,
        "steps" =>
          steps ||
            [
              step(1, [text("Open a terminal")]),
              step(2, [
                text("Make its folder\nIn your home."),
                command("mkdir w"),
                route(["Finder", "Home", "w"]),
                command("cd w")
              ]),
              step(3, [text("Tell us")])
            ],
        "actions" => [
          move.("Step 2 done", "Enter", 3),
          move.("Next step", "Down", 3),
          move.("Previous step", "Up", 1)
        ]
      }
    }

    AtlasTui.ConsoleProjectionFixture.model(%{
      "op" => "page",
      "path" => path,
      "title" => "W-01",
      "reason" => "open",
      "blocks" => [steps]
    })
  end

  defp screen(model), do: View.render(model, 90, 40, 30) |> View.plain()

  test "the panel shows why, the done step, the current one with its commands, the later one" do
    text = screen(page())
    assert text =~ "◆ TO DO FOR YOU  Set up the widget"
    assert text =~ "step 2 of 3"
    assert text =~ "Why: The widget needs a home. · 3h"
    assert text =~ "✓ 1. Open a terminal"
    assert text =~ ~r/▸ 2\. Make its folder +│ │\n.*│      In your home\./
    assert text =~ "│ mkdir w"
    assert text =~ "⌘ Finder › Home › w"
    assert text =~ "│ cd w"
    assert text =~ "3. Tell us"
    assert text =~ "Enter Step 2 done"
    assert text =~ "y copy all"
  end

  test "c copies the first command, C the next, y all of them, and the TUI says so" do
    model = page()
    {copied, [{:copy, "mkdir w"}]} = Model.key(model, {:char, "c"})
    assert screen(copied) =~ "✓ copied"
    {copied, [{:copy, "cd w"}]} = Model.key(copied, {:char, "C"})
    {_, [{:copy, "cd w"}]} = Model.key(copied, {:char, "C"})
    {_, [{:copy, "mkdir w\ncd w"}]} = Model.key(model, {:char, "y"})
  end

  test "Enter moves to the next step through Control's action" do
    {moved, _} = Model.key(page(), :enter)
    assert moved.console.in_flight == "/k/widget/W-01/step/3"
  end

  @tag :tmp_dir
  test "pbcopy is handed the text", %{tmp_dir: dir} do
    out = Path.join(dir, "out")
    fake = Path.join(dir, "pbcopy")
    File.write!(fake, "#!/bin/sh\ncat > '#{out}'\n")
    File.chmod!(fake, 0o755)
    Clipboard.copy("mkdir w\ncd w", pbcopy: fake)
    assert File.read!(out) == "mkdir w\ncd w"
  end

  test "the OSC 52 payload decodes to the command, wrapped for tmux inside tmux" do
    "\e]52;c;" <> rest = Clipboard.osc52("mkdir w", nil)
    assert Base.decode64!(String.trim_trailing(rest, "\a")) == "mkdir w"

    wrapped = Clipboard.osc52("cd w", "/tmp/tmux-1/default,1,0")
    assert "\ePtmux;\e\e]52;c;" <> _ = wrapped
    [_, payload] = Regex.run(~r/\e\]52;c;([^\a]*)\a$/, wrapped)
    assert Base.decode64!(payload) == "cd w"
  end

  test "a route shows ⌘, its parts in the route colour and muted › between them, in order" do
    lines = View.render(page(), 90, 40, 30)
    plain = View.plain(lines)
    order = for line <- ["mkdir w", "⌘ Finder", "cd w"], do: :binary.match(plain, line) |> elem(0)
    assert order == Enum.sort(order)

    [route] = Enum.filter(lines, fn line -> Enum.any?(line, &match?({:route, "Finder"}, &1)) end)
    segments = Enum.drop_while(route, &(&1 != {:dim, "⌘ "}))

    assert [
             {:dim, "⌘ "},
             {:route, "Finder"},
             {:dim, " › "},
             {:route, "Home"},
             {:dim, " › "},
             {:route, "w"} | _
           ] = segments
  end

  test "a long route goes on at a separator, the next row starting with ›" do
    parts = [
      "Keychain Access",
      "login",
      "My Certificates",
      "Developer ID Application: A > B (TEAMID)"
    ]

    steps = [step(1, [text("Export it"), route(parts)])]
    rows = View.render(page(steps, 1), 60, 40, 30) |> View.plain() |> String.split("\n")

    assert Enum.any?(rows, &(&1 =~ "⌘ Keychain Access › login › My Certificates"))
    assert Enum.any?(rows, &(&1 =~ ~r/│\s+› Developer ID Application: A > B \(TEAMID\)/))
    refute Enum.any?(rows, &(&1 =~ ~r/Certificates › Developer/))
  end

  test "copy keys copy only commands, never a route" do
    {_, [{:copy, "mkdir w\ncd w"}]} = Model.key(page(), {:char, "y"})
    steps = [step(1, [text("Open it"), route(["Finder", "Home"])])]

    assert {_, []} =
             Model.key(page(steps, 1), {:char, "c"})
             |> then(fn {m, e} -> {m, Enum.filter(e, &match?({:copy, _}, &1))} end)
  end

  test "every step's number starts at the same column, done, current and later" do
    steps = for n <- 1..10, do: step(n, [text("Step #{n} text"), command("true")])
    rows = View.render(page(steps, 2), 90, 60, 30) |> View.plain() |> String.split("\n")

    columns =
      for n <- [1, 2, 3, 10] do
        row = Enum.find(rows, &(&1 =~ ~r/\b#{n}\. +Step #{n} text/))
        [{number, _}] = Regex.run(~r/\b#{n}\. /, row, return: :index)
        [{text, _}] = Regex.run(~r/Step #{n} text/, row, return: :index)
        {String.length(binary_part(row, 0, number)), String.length(binary_part(row, 0, text))}
      end

    assert [_] = Enum.uniq(columns)
  end
end
