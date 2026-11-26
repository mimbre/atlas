defmodule AtlasTui.ShellStatusTest do
  # Without Control's content the TUI's own state is said once, in the status line: not
  # connected, why and what happens next in plain words, and how often it retries. The
  # content area stays empty, and a page from Control replaces the state at once.
  use ExUnit.Case, async: true
  alias AtlasTui.{Console, Model, Protocol, View}

  defp welcome(spec \\ Protocol.version()),
    do: %{"op" => "welcome", "env" => "prod", "spec" => spec, "surface" => "console"}

  defp page(path) do
    %{
      "op" => "page",
      "path" => path,
      "title" => "Widgets",
      "reason" => "open",
      "blocks" => [
        %{
          "id" => "widgets",
          "type" => "list",
          "props" => %{
            "title" => "Widgets",
            "rows" => [%{"id" => "W1", "label" => "First", "to" => "/k/widget/W1"}]
          }
        }
      ]
    }
  end

  defp boot do
    %{
      "op" => "boot",
      "title" => "Atlas Console",
      "env" => "prod",
      "spec" => Protocol.version(),
      "revision" => "rev1",
      "initial_to" => "/k/widget",
      "active_tab" => "widgets",
      "tabs" => [
        %{"id" => "widgets", "label" => "Widgets", "to" => "/k/widget", "section" => "work"}
      ]
    }
  end

  defp fresh, do: Model.new("prod")

  defp ready do
    {model, []} = Console.receive(fresh(), welcome())
    {model, [_]} = Console.receive(model, page("/"))
    {model, [_]} = Console.receive(model, boot())
    {model, []} = Console.receive(model, page("/k/widget"))
    model
  end

  defp lines(model, width \\ 100),
    do: model |> View.render(width, 24, 5) |> View.plain() |> String.split("\n")

  # The status line(s): everything below the notice line under the rule.
  defp status(model, width \\ 100) do
    lines = lines(model, width)
    rule = Enum.find_index(lines, &String.starts_with?(&1, "────"))
    lines |> Enum.drop(rule + 2) |> Enum.map_join(" ", &String.trim/1)
  end

  # Between the header (bar, tabs box) and the rule: the content area.
  defp content(model) do
    lines = lines(model)
    rule = Enum.find_index(lines, &String.starts_with?(&1, "────"))
    lines |> Enum.slice(4, rule - 4) |> Enum.reject(&(String.trim(&1) == ""))
  end

  @retries "retries every #{div(Console.retry_ms(), 1_000)}s"
  @ours Protocol.version()

  test "each shell state says why and what happens next, once, in the status line" do
    gone = Model.disconnected(ready(), nil)

    for {why, said, retries?} <- [
          {nil, "connecting to Control", false},
          {:no_tunnel, "the tunnel to Control is closed; any atlas command opens it", true},
          {:unreachable, "Control cannot be reached; connects by itself once it answers", true},
          {:silent, "Control is down or restarting; connects once it answers", true},
          {{:newer, "0.1.0"},
           "this TUI is newer than prod (#{@ours} vs 0.1.0); connects once prod is updated",
           false},
          {:refused,
           "Control prod refused this TUI as its Console; connects once Control restarts", false}
        ] do
      model = %{gone | offline: why}
      line = status(model)
      assert line == "○ not connected · " <> said <> if(retries?, do: " · " <> @retries, else: "")
      # Compact: one line at 100 wide.
      assert lines(model) |> List.last() |> String.trim() == line
      assert content(model) == [], "no message and nothing old in the content area"
      text = Enum.join(lines(model), "\n")
      refute text =~ "Not connected to Control"
      refute text =~ "Nothing old is shown"
      refute text =~ "retrying boot"
    end
  end

  test "the client tells its states apart: failures, a newer TUI, a refusal" do
    assert Model.disconnected(fresh(), :unreachable).offline == :unreachable
    # The socket opening again keeps the last known why, so the line does not flicker.
    assert Model.disconnected(%{fresh() | offline: :silent}).offline == :silent

    {newer, []} = Console.receive(fresh(), welcome("0.1.0"))
    assert newer.offline == {:newer, "0.1.0"}
    {refused, []} = Console.receive(fresh(), %{welcome() | "env" => "test"})
    assert refused.offline == :refused
    {refused, []} = Console.receive(fresh(), welcome("999.0.0"))
    assert refused.offline == :refused
  end

  test "closed by Control: its words are the status line's, not said twice" do
    text = "This is Control prod; it does not serve \"test\"."
    {closed, []} = Console.receive(ready(), %{"op" => "bye", "text" => text})
    screen = Enum.join(lines(closed), "\n")
    assert status(closed) == "○ not connected · " <> text <> " · " <> @retries
    assert length(String.split(screen, "does not serve")) == 2
    assert content(closed) == []
  end

  test "on a narrow screen the line wraps, so what to do is never cut off" do
    model = %{Model.disconnected(ready()) | offline: {:newer, "0.1.0"}}
    assert status(model, 60) =~ "connects once prod is updated"
    assert Enum.all?(lines(model, 60), &(String.length(&1) <= 60))
  end

  test "waiting for the first page is said in the status line, not the content area" do
    {model, []} = Console.receive(fresh(), welcome())
    assert status(model) =~ "● connected · waiting for Control's first page"
    assert content(model) == []
  end

  test "as soon as Control answers with a page, content replaces the state" do
    gone = Model.disconnected(ready(), :silent)
    assert status(gone) =~ "down or restarting"

    {back, []} = Console.receive(gone, welcome())
    assert back.offline == nil
    {back, [_]} = Console.receive(back, page("/"))
    {back, [_]} = Console.receive(back, boot())
    {back, []} = Console.receive(back, page("/k/widget"))

    assert status(back) =~ "● connected"
    refute status(back) =~ "down or restarting"
    refute status(back) =~ "waiting for"
    assert Enum.any?(content(back), &(&1 =~ "First"))
  end
end
