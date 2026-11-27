defmodule AtlasTui.PanelTest do
  use ExUnit.Case, async: true
  alias AtlasTui.{Model, PanelFixture}

  defp screen(model, width \\ 100),
    do: AtlasTui.View.render(model, width, 60, 30) |> AtlasTui.View.plain()

  defp line(screen, text), do: screen |> String.split("\n") |> Enum.find(&(&1 =~ text))

  defp effects(model, keys) do
    Enum.reduce(keys, {model, []}, fn key, {model, _} -> Model.key(model, key) end)
  end

  test "a panel to accept shows its heading, title, count, byline and the selected item" do
    screen = screen(PanelFixture.model(:accept))
    heading = line(screen, "TO ACCEPT")
    lines = String.split(screen, "\n")
    under = Enum.at(lines, Enum.find_index(lines, &(&1 == heading)) + 1)

    assert heading =~ "◆ TO ACCEPT" and heading =~ "3 widgets"
    assert under =~ ~r/^ Plan for UC-Atlas-23/
    assert screen =~ "Proposed by planner · waiting 3h"
    assert line(screen, "IS-Atlas-162") =~ "▸"
    refute line(screen, "IS-Atlas-163  Show") =~ "▸"
    assert line(screen, "What ") =~ "Record who produced each item"
    assert line(screen, "Done ") =~ "Every new item names its producer."
    assert screen =~ "a Accept" and screen =~ "n Not accepted"
    assert screen =~ "i Full proposal" and screen =~ "↑↓ choose"
  end

  test "the heading carries the key of the fact the panel is about" do
    screen = screen(PanelFixture.model(:accept, %{"key" => "UC-Atlas-23"}))
    assert line(screen, "TO ACCEPT") =~ "◆ TO ACCEPT · UC-Atlas-23"
  end

  test "an age alone, without text, is shown as an age" do
    since = DateTime.utc_now() |> DateTime.add(-26 * 3_600 - 60) |> DateTime.to_iso8601()

    screen =
      screen(PanelFixture.model(:accept, %{"byline" => [%{"text" => "", "since" => since}]}))

    assert line(screen, ~r/^  1d( |$)/)
  end

  test "the arrows move the selected item and the details shown with it" do
    model = PanelFixture.model(:accept)
    {down, []} = Model.key(model, :down)

    assert down.choice == "IS-Atlas-163"
    assert line(screen(down), "IS-Atlas-163  Show") =~ "▸"
    assert line(screen(down), "Done ") =~ "The page says who made it."
    refute screen(down) =~ "Every new item names its producer."

    {last, []} = effects(down, [:down, :down, :down])
    assert last.choice == "IS-Atlas-164"
    {first, []} = effects(last, [:up, :up, :up])
    assert first.choice == "IS-Atlas-162"
  end

  test "the selection stays on the same page and starts again on another" do
    {down, []} = Model.key(PanelFixture.model(:accept), :down)
    page = PanelFixture.page(:accept)

    {again, _} = AtlasTui.ConsoleProjectionFixture.receive(down, %{page | "reason" => "hint"})
    assert again.choice == "IS-Atlas-163"

    {other, _} =
      AtlasTui.ConsoleProjectionFixture.receive(down, %{page | "path" => "/k/widget/K-2"})

    assert other.choice == nil
  end

  test "Enter opens the selected item's page" do
    {model, effects} = effects(PanelFixture.model(:accept), [:down, :enter])
    assert [{:send, %{"op" => "open", "to" => "/k/widget/IS-Atlas-163"}}] = effects
    assert model.console.expected == "/k/widget/IS-Atlas-163"
  end

  test "an answer given with a note opens its note form, never submits" do
    {model, effects} = Model.key(PanelFixture.model(:accept), {:char, "n"})
    assert [{:send, %{"op" => "open", "to" => "/k/widget/K-1/answer/reject"}}] = effects
    assert model.console.expected == "/k/widget/K-1/answer/reject"

    {_, accept} = Model.key(PanelFixture.model(:accept), {:char, "a"})
    assert [{:send, %{"op" => "submit", "params" => %{"answer" => "accept"}}}] = accept
  end

  test "a check shows its state by a mark, its label and text in columns" do
    checks = [
      %{"label" => "CI", "state" => "success", "text" => "Passed"},
      %{"label" => "Review", "state" => "none", "text" => "—"},
      %{"label" => "Lint", "state" => "error", "text" => "Failed"},
      %{"label" => "Deploy", "state" => "pending", "text" => "Running"}
    ]

    screen = screen(PanelFixture.model(:merge, %{"checks" => checks}))

    assert line(screen, "CI") =~ ~r/✓ CI\s+Passed/
    assert line(screen, "Review") =~ ~r/— Review\s+—/
    assert line(screen, "Lint") =~ ~r/✗ Lint\s+Failed/
    assert line(screen, "Deploy") =~ ~r/… Deploy\s+Running/

    columns =
      for label <- ~w(Passed Failed Running),
          do: line(screen, label) |> :binary.match(label) |> elem(0)

    assert columns |> Enum.uniq() |> length() == 1
    assert screen =~ "o Open on GitHub" and screen =~ "v Full review"
  end

  test "a panel fits any width" do
    for kind <- [:accept, :merge],
        width <- [1, 5, 12, 20, 40],
        do: assert(is_binary(screen(PanelFixture.model(kind), width)))
  end
end
