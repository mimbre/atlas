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
  defp screen(model, width), do: model |> lines(width) |> Enum.join("\n")
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

  test "a decision's blocks top down: question, why, each alternative, the answers, details" do
    lines = lines(PanelFixture.model(:choice))

    order =
      Enum.map(
        [
          "◆ YOUR DECISION · D-7",
          "How do we store examples?",
          "Files need nothing to run.",
          "1. Use files",
          "2. Use memory",
          "3 Decline all",
          "Decline all: None of these fits; say why.",
          ~r/^  Details$/,
          "Status"
        ],
        &at(lines, &1)
      )

    assert Enum.all?(order, &is_integer/1)
    assert order == Enum.sort(order)
    # The decline is no card.
    refute at(lines, "3. ")
  end

  test "read-only alternatives retain their content without answer buttons" do
    model = PanelFixture.model(:choice)

    blocks =
      Enum.map(model.blocks, fn
        %AtlasTui.Blocks.Option{} = option -> %{option | answer: nil}
        block -> block
      end)

    model = %{model | blocks: blocks}
    assert line(model, "1. Use files")
    assert line(model, "2. Use memory")
    assert line(model, "Store examples in files.")
    assert Model.options(model) == []
  end

  test "on a wide terminal the details stand beside the decision" do
    lines = lines(PanelFixture.model(:choice), 160)
    assert at(lines, "Status") < at(lines, "1. Use files")
  end

  test "every alternative shows its Rule and Consequences, each a heading with its text under it" do
    model = PanelFixture.model(:choice)
    lines = lines(model)
    bare = Enum.map(lines, &(&1 |> String.replace(~r/[│|▸]/u, " ") |> String.trim()))

    for id <- ["files", "memory"] do
      rule = Enum.find_index(bare, &(&1 == "Store examples in #{id}."))
      then = Enum.find_index(bare, &(&1 == "Use #{id} holds them."))
      assert Enum.at(bare, rule - 1) == "Rule"
      assert Enum.at(bare, then - 1) == "Consequences"
    end

    refute Enum.any?(lines, &(&1 =~ ~r/Rule:|Then:|Consequences:/))
  end

  test "each alternative has its badge and its own Choose; Decline all with the answers" do
    model = PanelFixture.model(:choice)

    assert line(model, "1. Use files") =~ "★ Recommended"
    refute line(model, "2. Use memory") =~ "★"

    assert line(model, "1 Choose")
    assert line(model, "2 Choose")
    assert line(model, "3 Decline all") =~ "l Inspector's log"

    # The main answer and the decline in the primary colour, another Choose dim.
    role =
      &Enum.map(styles(model, &1), fn
        {_surface, role} -> role
        role -> role
      end)

    assert :info in role.("1 Choose") and :info in role.("3 Decline all")
    assert :dim in role.("2 Choose") and :info not in role.("2 Choose")
  end

  test "one proposal: its card without an answer, then Accept and Decline" do
    model = PanelFixture.model(:proposal)
    lines = lines(model)

    # The only proposal: no number, no badge, its Rule in full.
    assert line(model, "Use files") =~ "▸ Use files"
    refute at(lines, "1. Use files")
    refute Enum.any?(lines, &(&1 =~ "★"))
    flat = lines |> Enum.join(" ") |> String.replace(~r/[│|]/u, " ") |> String.split()
    rule = String.split("Rule " <> PanelFixture.long_rule())
    assert Enum.join(flat, " ") =~ Enum.join(rule, " ")
    refute at(lines, "1 Choose")
    assert line(model, "1 Accept") =~ "2 Decline"
    assert line(model, "Decline: None of these fits; say why.")

    {_, by_one} = Model.key(model, {:char, "1"})
    assert [{:send, %{"op" => "submit", "params" => %{"answer" => "option-files"}}}] = by_one
    assert Model.key(model, :enter) |> elem(1) == by_one
    assert Model.key(model, {:char, "0"}) |> elem(1) == by_one

    note_form = "/k/decision/D-7/answer/decline"
    assert {_, [{:send, %{"op" => "open", "to" => ^note_form}}]} = Model.key(model, {:char, "2"})
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

    {last, []} = press(down, [:down, :down])
    assert line(last, "2. Use memory") =~ "▸"
    {first, []} = press(last, [:up, :up, :up])
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

  test "Decline all opens its note form and never submits" do
    model = PanelFixture.model(:choice)
    note_form = "/k/decision/D-7/answer/decline"
    {by_key, by_three} = Model.key(model, {:char, "3"})

    assert [{:send, %{"op" => "open", "to" => ^note_form}}] = by_three
    assert by_key.console.expected == note_form
  end

  test "the arrows never answer" do
    for kind <- [:choice, :stuck] do
      model = PanelFixture.model(kind)
      {moved, effects} = press(model, [:down, :down, :down, :up, :up, :up, :up, :down])
      assert effects == []
      assert moved.console.expected == model.console.expected
    end
  end

  test "stuck work: the question, its byline, what went wrong in an error card, then its proposal" do
    model = PanelFixture.model(:stuck)
    lines = lines(model)

    order =
      Enum.map(
        [
          "◆ YOUR DECISION · IS-Atlas-134",
          "inspect · attempt 2 failed · stuck · 1d ago",
          "What went wrong",
          "the tests could not reach the database.",
          "Retry",
          "Consequences",
          "Runs the work again from where it stopped.",
          "t Accept",
          "Decline: Close it"
        ],
        &at(lines, &1)
      )

    assert Enum.all?(order, &is_integer/1)
    assert order == Enum.sort(order)

    assert {:card, :error} in styles(model, "What went wrong")
    assert {:card, :plain} in styles(model, "could not reach the database")
    refute line(model, "Retry") =~ "★"
    assert line(model, "t Accept") =~ "c Decline"
  end

  test "stuck work: Enter retries as t does; c opens its note form" do
    model = PanelFixture.model(:stuck)
    {_, by_key} = Model.key(model, {:char, "t"})

    assert [{:send, %{"op" => "submit", "params" => %{"answer" => "retry"}}}] = by_key
    assert Model.key(model, :enter) |> elem(1) == by_key

    {_, by_c} = Model.key(model, {:char, "c"})
    assert [{:send, %{"op" => "open", "to" => "/k/widget/K-1/answer/close"}}] = by_c
  end

  test "a decision fits any width" do
    for kind <- [:choice, :stuck], width <- [1, 5, 12, 20, 40] do
      assert is_binary(screen(PanelFixture.model(kind), width))
    end
  end
end
