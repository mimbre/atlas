defmodule AtlasTui.StepsPanelTest do
  use ExUnit.Case, async: true
  alias AtlasTui.{Clipboard, Model, View}

  defp page do
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
        "current" => 2,
        "steps" => [
          %{"n" => 1, "text" => "Open a terminal", "commands" => []},
          %{"n" => 2, "text" => "Make its folder", "commands" => ["mkdir w", "cd w"]},
          %{"n" => 3, "text" => "Tell us", "commands" => []}
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
    assert text =~ "▸ 2. Make its folder"
    assert text =~ "│ mkdir w"
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
end
