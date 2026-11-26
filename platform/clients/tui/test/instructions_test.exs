defmodule AtlasTui.InstructionsTest do
  @moduledoc """
  A to-do's page as Control sends it: a stack of generic blocks (a header, the why, one
  instruction per step, the answers) and its details (docs/guides/to-dos.md).
  """
  use ExUnit.Case, async: true
  alias AtlasTui.{Clipboard, ConsoleProjectionFixture, Model, PanelFixture, View}

  @path "/k/todo/TD-12"

  defp text(text), do: %{"kind" => "text", "text" => text}
  defp command(command), do: %{"kind" => "command", "text" => command}
  defp route(parts), do: %{"kind" => "route", "parts" => parts}

  defp step(n, lines),
    do: %{"id" => "step-#{n}", "type" => "instruction", "props" => %{"n" => n, "lines" => lines}}

  defp steps do
    [
      step(1, [text("Open a terminal"), command("cd ~")]),
      step(2, [
        text("Make its folder\nIn your home."),
        command("mkdir w"),
        route(["Finder", "Home", "w"]),
        command("cd w")
      ]),
      step(3, [text("Tell us")])
    ]
  end

  defp page(opts) do
    path = opts[:path] || @path
    answer = &%{"label" => &1, "key" => &2, "to" => path <> "/answer/" <> &2, "note" => true}

    blocks =
      [
        %{
          "id" => "header",
          "type" => "header",
          "props" => %{
            "eyebrow" => "TO DO FOR YOU",
            "key" => "TD-12",
            "title" => "Rotate the key"
          }
        },
        %{
          "id" => "why",
          "type" => "text",
          "props" => %{
            "label" => "Why",
            "text" => "The old key leaked.",
            "since" => DateTime.utc_now() |> DateTime.add(-3 * 3600 - 60) |> DateTime.to_iso8601()
          }
        }
      ] ++
        (opts[:steps] || steps()) ++
        [
          %{
            "id" => "answers",
            "type" => "answers",
            "props" => %{
              "answers" =>
                opts[:answers] ||
                  [
                    Map.put(answer.("Done", "x"), "weight", "main"),
                    Map.put(answer.("Won't do", "n"), "weight", "no")
                  ]
            }
          },
          %{
            "id" => "actions",
            "type" => "actions",
            "props" => %{
              "actions" => [%{"label" => "Update chore", "key" => "u", "to" => path <> "/edit"}]
            }
          },
          %{
            "id" => "item",
            "type" => "item",
            "props" => %{
              "title" => "TD-12",
              "fields" => [%{"label" => "Status", "value" => "Open"}],
              "actions" => []
            }
          }
        ]

    %{
      "op" => "page",
      "path" => path,
      "title" => "TD-12",
      "reason" => "open",
      "blocks" => blocks,
      "markup" => [
        %{
          "kind" => "part",
          "start" => "item",
          "end" => "item",
          "props" => %{"title" => "Details", "role" => "details"}
        }
      ]
    }
  end

  defp model(opts \\ []), do: PanelFixture.projected(page(opts))

  defp rows(model, width \\ 90, height \\ 60),
    do: View.render(model, width, height, 30) |> View.plain() |> lines()

  # A segment's role, whether on the page or on a card.
  defp on_page({{surface, role}, text}) when surface in [:card, :card_selected], do: {role, text}
  defp on_page(segment), do: segment
  defp lines(text), do: String.split(text, "\n")
  defp screen(model, width \\ 90), do: model |> rows(width) |> Enum.join("\n")
  defp marked(model), do: model |> rows() |> Enum.filter(&(&1 =~ ~r/^\s*▸ /u))

  defp press(model, keys) do
    Enum.reduce(keys, {model, []}, fn key, {model, effects} ->
      {model, more} = Model.key(model, key)
      {model, effects ++ more}
    end)
  end

  test "the header, the why and every step in full, one under the other, then the answers" do
    text = screen(model())
    assert text =~ " ◆ TO DO FOR YOU · TD-12\n Rotate the key\n"
    assert text =~ "Why: The old key leaked. · 3h ago"

    assert text =~
             ~r/1\. Open a terminal\n\n.*▎ cd ~\n.*\n\n.*\n +2\. Make its folder\n +In your home\./

    assert text =~ ~r/▎ mkdir w\n\n +⌘ Finder › Home › w\n\n +▎ cd w\n.*\n\n.*\n +3\. Tell us/

    assert text =~
             "x Done · note · n Won't do · note · u Update chore · ↑↓ command · c copy · y copy all"

    refute text =~ ~r/step \d+ of/i
    refute text =~ ~r/Enter|Next step|Previous step|✓ 1\./
  end

  test "every step's number and text start at the same columns, however many steps" do
    steps = for n <- 1..10, do: step(n, [text("Step #{n} text"), command("true")])
    rows = rows(model(steps: steps), 90, 100)

    columns =
      for n <- [1, 2, 9, 10] do
        row = Enum.find(rows, &(&1 =~ ~r/\b#{n}\. +Step #{n} text/))
        [{number, _}] = Regex.run(~r/\b#{n}\. /, row, return: :index)
        [{text, _}] = Regex.run(~r/Step #{n} text/, row, return: :index)
        {number, text}
      end

    assert [_] = Enum.uniq(for {_, text} <- columns, do: text)
    assert [_] = Enum.uniq(for {number, _} <- columns, do: number)
  end

  test "↑↓ move ▸ from command to command across the steps, stopping at the ends" do
    model = model()
    assert [first] = marked(model)
    assert first =~ "▎ cd ~"

    {model, []} = press(model, [:down])
    assert [row] = marked(model)
    assert row =~ "▎ mkdir w"

    {model, []} = press(model, [:down, :down, :down])
    assert [row] = marked(model)
    assert row =~ "▎ cd w"

    {model, []} = press(model, [:up, :up, :up, :up])
    assert [row] = marked(model)
    assert row =~ "▎ cd ~"
  end

  test "c copies the selected command, y all of the page's, one per line; the TUI says so" do
    {copied, [{:copy, "cd ~"}]} = press(model(), [{:char, "c"}])
    assert screen(copied) =~ "✓ copied"
    {_, [{:copy, "mkdir w"}]} = press(model(), [:down, {:char, "c"}])
    {_, [{:copy, "cd w"}]} = press(model(), [:down, :down, {:char, "c"}])
    {_, [{:copy, "cd ~\nmkdir w\ncd w"}]} = press(model(), [:down, {:char, "y"}])
  end

  test "a page without commands copies nothing and names no copy keys" do
    model = model(steps: [step(1, [text("Open it"), route(["Finder", "Home"])])])
    assert {_, []} = press(model, [{:char, "c"}, {:char, "y"}])
    refute screen(model) =~ ~r/c copy|y copy all|↑↓ command/
    assert marked(model) == []
  end

  test "each answer's key is the page's action: it opens the answer" do
    {model, _} = press(model(), [{:char, "x"}])
    assert model.console.in_flight == @path <> "/answer/x"
    {model, _} = press(model(), [{:char, "u"}])
    assert model.console.in_flight == @path <> "/edit"
  end

  test "the page's other actions follow the answers in their key line, muted, each on its key" do
    lines = View.render(model(), 90, 60, 30)
    assert Enum.any?(lines, &({:muted, " Update chore"} in &1 and {:muted, "u"} in &1))
  end

  test "the answers' key line: the main one, then the no, in the primary colour, then the rest" do
    answer = fn label, key, weight, note ->
      %{"label" => label, "key" => key, "to" => @path <> "/answer/" <> key, "weight" => weight}
      |> Map.merge(if note, do: %{"note" => true}, else: %{})
    end

    answers = [
      answer.("Later", "l", "other", false),
      answer.("Won't do", "n", "no", true),
      answer.("Done", "x", "main", true)
    ]

    text = screen(model(answers: answers))
    assert text =~ "x Done · note · n Won't do · note · l Later · u Update chore"

    lines =
      for line <- View.render(model(answers: answers), 90, 60, 30), do: Enum.map(line, &on_page/1)

    [keys] = Enum.filter(lines, &({:info, " Done · note"} in &1))
    assert {:info, " Won't do · note"} in keys
    assert {:dim, " Later"} in keys
  end

  test "a route shows ⌘, its parts in the route colour and muted › between them, in order" do
    lines = for line <- View.render(model(), 90, 60, 30), do: Enum.map(line, &on_page/1)

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

    rows = rows(model(steps: [step(1, [text("Export it"), route(parts)])]), 60)

    assert Enum.any?(rows, &(&1 =~ "⌘ Keychain Access › login › My Certificates"))
    assert Enum.any?(rows, &(&1 =~ ~r/^ +› Developer ID Application: A > B \(TEAMID\)/))
    refute Enum.any?(rows, &(&1 =~ ~r/Certificates › Developer/))
  end

  test "the details stand beside the steps on a wide terminal, under the answers otherwise" do
    wide = rows(model(), 160)
    details = Enum.find_index(wide, &(&1 =~ ~r/  Details( |$)/))
    assert Enum.at(wide, details) =~ "Rotate the key"

    narrow = rows(model(), 90)
    answers = Enum.find_index(narrow, &(&1 =~ "x Done"))
    details = Enum.find_index(narrow, &(&1 =~ ~r/^  Details$/))
    assert answers < details
  end

  test "in columns the arrows move the list while it has the focus, the command in the page" do
    tabs = [%{"id" => "assigned", "label" => "Assigned to you", "to" => "/", "section" => "work"}]

    rows =
      for n <- 1..2, do: %{"label" => "To-do #{n}", "id" => "TD-#{n}", "to" => "/k/todo/TD-#{n}"}

    model = Model.new("test")

    model = %{
      model
      | connected: true,
        console: %{
          model.console
          | phase: :ready,
            stale: false,
            viewport: {220, 60},
            shell: %{"revision" => "fixture", "title" => "Atlas Console", "tabs" => tabs}
        }
    }

    list = %{
      "op" => "page",
      "path" => "/",
      "title" => "Assigned to you",
      "reason" => "open",
      "blocks" => [%{"id" => "list", "type" => "list", "props" => %{"rows" => rows}}]
    }

    {model, _} = ConsoleProjectionFixture.receive(model, list)
    {model, []} = ConsoleProjectionFixture.receive(model, page(path: "/k/todo/TD-1"))

    {page, []} = press(model, [:right, :down])
    assert page.path == "/k/todo/TD-1"
    screen = page |> View.render(220, 60, 30) |> View.plain() |> lines()
    assert [row] = Enum.filter(screen, &(&1 =~ ~r/▸ +▎ /))
    assert row =~ "▎ mkdir w"

    {_listed, [{:send, %{"op" => "open", "to" => "/k/todo/TD-2"}}]} = press(model, [:down])
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
end
