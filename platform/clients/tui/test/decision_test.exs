defmodule AtlasTui.DecisionTest do
  @moduledoc """
  A page where its owner decides, as Control sends it (D-0104): a stack of simple blocks,
  one job each (the question, why, what went wrong, an option per answer, the other
  answers) and its details. Every answer is Control's action on its key.
  """
  use ExUnit.Case, async: true
  alias AtlasTui.{Model, PanelFixture, View}

  defp rows(model, width \\ 90), do: View.render(model, width, 60, 30)
  defp lines(model, width \\ 90), do: model |> rows(width) |> View.plain() |> String.split("\n")
  defp screen(model, width \\ 90), do: model |> lines(width) |> Enum.join("\n")
  defp at(lines, text), do: Enum.find_index(lines, &(&1 =~ text))
  defp line(model, text), do: model |> lines() |> Enum.find(&(&1 =~ text))

  # The styles of the row that shows `text`.
  defp styles(model, text) do
    model
    |> rows()
    |> Enum.find(fn row -> Enum.map_join(row, &elem(&1, 1)) =~ text end)
    |> Enum.map(&elem(&1, 0))
  end

  defp press(model, keys) do
    Enum.reduce(keys, {model, []}, fn key, {model, effects} ->
      {model, more} = Model.key(model, key)
      {model, effects ++ more}
    end)
  end

  test "a decision's blocks top down: question, why, each option, the other answers, details" do
    lines = lines(PanelFixture.model(:choice))

    order =
      Enum.map(
        [
          "◆ YOUR DECISION · D-7",
          "How do we store examples?",
          "Why: Files need nothing to run.",
          "1. Use files",
          "2. Use memory",
          "3. Decline",
          "l Inspector's log",
          ~r/^  Details$/,
          "Status"
        ],
        &at(lines, &1)
      )

    assert Enum.all?(order, &is_integer/1)
    assert order == Enum.sort(order)
  end

  test "on a wide terminal the details stand beside the decision" do
    lines = lines(PanelFixture.model(:choice), 160)
    assert at(lines, "Status") < at(lines, "1. Use files")
  end

  test "every option shows its rule and what then follows, a decline its details" do
    screen = screen(PanelFixture.model(:choice))

    for id <- ["files", "memory"] do
      assert screen =~ "Rule: Store examples in #{id}."
      assert screen =~ "Then: Use #{id} holds them."
    end

    assert screen =~ "Details: None of these fits; say why."
  end

  test "each option has its badge and its own answer on its key" do
    model = PanelFixture.model(:choice)

    assert line(model, "1. Use files") =~ "★ Recommended"
    assert line(model, "3. Decline") =~ "Decline · note"
    refute line(model, "2. Use memory") =~ "★"

    assert line(model, "1 Choose")
    assert line(model, "2 Choose")
    assert line(model, "3 Decline…")
  end

  test "the selection starts on the first option, on the selected surface, and the arrows move it" do
    model = PanelFixture.model(:choice)
    assert line(model, "1. Use files") =~ "▸"
    assert {:card_selected, :bold} in styles(model, "1. Use files")
    assert {:card, :bold} in styles(model, "2. Use memory")

    {down, []} = Model.key(model, :down)
    refute line(down, "1. Use files") =~ "▸"
    assert line(down, "2. Use memory") =~ "▸"
    assert {:card_selected, :bold} in styles(down, "2. Use memory")
    assert {:card, :bold} in styles(down, "1. Use files")

    {last, []} = press(down, [:down, :down, :down])
    assert line(last, "3. Decline") =~ "▸"
    {first, []} = press(last, [:up, :up, :up, :up])
    assert line(first, "1. Use files") =~ "▸"
  end

  test "Enter answers the selected option exactly as its key does" do
    model = PanelFixture.model(:choice)
    {_, by_one} = Model.key(model, {:char, "1"})
    assert [{:send, %{"op" => "submit", "params" => %{"answer" => "option-files"}}}] = by_one
    assert Model.key(model, :enter) |> elem(1) == by_one
    assert Model.key(model, {:char, "0"}) |> elem(1) == by_one

    {_, by_two} = Model.key(model, {:char, "2"})
    assert [{:send, %{"params" => %{"answer" => "option-memory"}}}] = by_two
    assert press(model, [:down, :enter]) |> elem(1) == by_two
  end

  test "Enter on a decline opens its note form, as its key does, and never submits" do
    model = PanelFixture.model(:choice)
    note_form = "/k/decision/D-7/answer/decline"
    {by_key, by_three} = Model.key(model, {:char, "3"})
    {by_enter, by_arrows} = press(model, [:down, :down, :enter])

    assert [{:send, %{"op" => "open", "to" => ^note_form}}] = by_three
    assert by_arrows == by_three
    assert by_enter.console.expected == note_form and by_key.console.expected == note_form
  end

  test "the arrows never answer" do
    for kind <- [:choice, :stuck] do
      model = PanelFixture.model(kind)
      {moved, effects} = press(model, [:down, :down, :down, :up, :up, :up, :up, :down])
      assert effects == []
      assert moved.console.expected == model.console.expected
    end
  end

  test "stuck work: the question, its byline, what went wrong in an error card, then its options" do
    model = PanelFixture.model(:stuck)
    lines = lines(model)

    order =
      Enum.map(
        [
          "◆ YOUR DECISION · IS-Atlas-134",
          "inspect · attempt 2 failed · stuck · 1d ago",
          "What went wrong",
          "the tests could not reach the database.",
          "1. Retry",
          "Then: Runs the work again from where it stopped.",
          "2. Close it",
          "Details: Closes the widget; you say why.",
          "l Agent's log"
        ],
        &at(lines, &1)
      )

    assert Enum.all?(order, &is_integer/1)
    assert order == Enum.sort(order)

    assert {:card, :error} in styles(model, "What went wrong")
    assert {:card, :plain} in styles(model, "could not reach the database")
    assert line(model, "1. Retry") =~ "★ Recommended"
    assert line(model, "2. Close it") =~ "Decline · note"
  end

  test "stuck work: Enter retries as t does; on Close it, opens its note form as c does" do
    model = PanelFixture.model(:stuck)
    {_, by_key} = Model.key(model, {:char, "t"})

    assert [{:send, %{"op" => "submit", "params" => %{"answer" => "retry"}}}] = by_key
    assert Model.key(model, :enter) |> elem(1) == by_key

    {_, by_c} = Model.key(model, {:char, "c"})
    assert [{:send, %{"op" => "open", "to" => "/k/widget/K-1/answer/close"}}] = by_c
    assert press(model, [:down, :enter]) |> elem(1) == by_c
  end

  test "a decision fits any width" do
    for kind <- [:choice, :stuck], width <- [1, 5, 12, 20, 40] do
      assert is_binary(screen(PanelFixture.model(kind), width))
    end
  end
end
