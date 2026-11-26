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
    bar = line(screen, "TO ACCEPT")

    assert bar =~ "◆ TO ACCEPT" and bar =~ "Plan for UC-Atlas-23" and bar =~ "3 issues"
    assert screen =~ "Proposed by planner · waiting 3h"
    assert line(screen, "IS-Atlas-162") =~ "▸"
    refute line(screen, "IS-Atlas-163  Show") =~ "▸"
    assert line(screen, "What ") =~ "Record who produced each item"
    assert line(screen, "Done ") =~ "Every new item names its producer."
    assert screen =~ "a Accept" and screen =~ "n Not accepted · note"
    assert screen =~ "i Full proposal" and screen =~ "↑↓ choose"
  end

  test "an age alone, without text, is shown as an age" do
    screen = screen(PanelFixture.model(:decision))
    assert line(screen, "│ 1d ")
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
      AtlasTui.ConsoleProjectionFixture.receive(down, %{page | "path" => "/k/issue/K-2"})

    assert other.choice == nil
  end

  test "Enter opens the selected item's page" do
    {model, effects} = effects(PanelFixture.model(:accept), [:down, :enter])
    assert [{:send, %{"op" => "open", "to" => "/k/issue/IS-Atlas-163"}}] = effects
    assert model.console.expected == "/k/issue/IS-Atlas-163"
  end

  test "an answer given with a note opens its note form, never submits" do
    {model, effects} = Model.key(PanelFixture.model(:accept), {:char, "n"})
    assert [{:send, %{"op" => "open", "to" => "/k/issue/K-1/answer/reject"}}] = effects
    assert model.console.expected == "/k/issue/K-1/answer/reject"

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

  test "a stuck one shows what went wrong and its answers, the recommended one selected" do
    model = PanelFixture.model(:decision)
    screen = screen(model)

    assert screen =~ "What went wrong"
    assert screen =~ "the tests could not reach the database."
    assert line(screen, "Retry") =~ "▸" and line(screen, "Retry") =~ "★ recommended"
    assert line(screen, "Close it") =~ "· note"
    assert screen =~ "Runs the work again from where it stopped."
    assert screen =~ "Enter answer" and screen =~ "l Agent's log"

    {down, []} = Model.key(model, :down)
    assert down.choice == "c"
    assert screen(down) =~ "Closes the issue; you say why."
    refute screen(down) =~ "Runs the work again"
  end

  test "Enter answers the selected answer with the call its own key sends" do
    model = PanelFixture.model(:decision)
    {_, by_key} = Model.key(model, {:char, "t"})

    assert [{:send, %{"op" => "submit", "params" => %{"answer" => "retry"}}}] = by_key
    assert Model.key(model, :enter) |> elem(1) == by_key
  end

  test "Enter on an answer given with a note opens its note form, never submits" do
    {model, effects} = effects(PanelFixture.model(:decision), [:down, :enter])
    assert [{:send, %{"op" => "open", "to" => "/k/issue/K-1/answer/close"}}] = effects
    assert model.console.expected == "/k/issue/K-1/answer/close"
  end

  test "a panel fits any width" do
    for kind <- [:accept, :merge, :decision],
        width <- [1, 5, 12, 20, 40],
        do: assert(is_binary(screen(PanelFixture.model(kind), width)))
  end
end
