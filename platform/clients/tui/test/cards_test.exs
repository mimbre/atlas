defmodule AtlasTui.CardsTest do
  @moduledoc """
  Cards (an option, a step, what went wrong, the details under a page): a filled surface,
  square, no lines; the selected one on the selected surface; their text
  readable on both surfaces in both themes; a left bar where the terminal has no truecolor.
  """
  use ExUnit.Case, async: true
  alias AtlasTui.{Palette, PanelFixture, View}

  @surfaces Palette.surfaces()
  @edges [:card_edge, :card_selected_edge]

  defp todo do
    step = fn n, lines ->
      %{"id" => "step-#{n}", "type" => "instruction", "props" => %{"n" => n, "lines" => lines}}
    end

    PanelFixture.projected(%{
      "op" => "page",
      "path" => "/k/todo/TD-1",
      "title" => "TD-1",
      "reason" => "open",
      "blocks" => [
        %{
          "id" => "header",
          "type" => "header",
          "props" => %{"eyebrow" => "TO DO FOR YOU", "key" => "TD-1", "title" => "Rotate"}
        },
        step.(1, [
          %{"kind" => "text", "text" => "Open it"},
          %{"kind" => "command", "text" => "cd ~"}
        ]),
        step.(2, [%{"kind" => "route", "parts" => ["Finder", "Home"]}]),
        %{
          "id" => "item",
          "type" => "item",
          "props" => %{
            "title" => "TD-1",
            "fields" => [%{"label" => "Status", "value" => "Open"}],
            "actions" => []
          }
        }
      ],
      "markup" => [
        %{
          "kind" => "part",
          "start" => "item",
          "end" => "item",
          "props" => %{"title" => "Details", "role" => "details"}
        }
      ]
    })
  end

  defp pages, do: [PanelFixture.model(:choice), PanelFixture.model(:stuck), todo()]

  defp render(model, width, truecolor \\ true),
    do: View.render(put_in(model.console.truecolor, truecolor), width, 80, 30)

  defp text(row), do: Enum.map_join(row, &elem(&1, 1))
  defp card_row?(row), do: Enum.any?(row, fn {style, _} -> card_style?(style) end)
  defp card_style?({surface, _}) when surface in @surfaces, do: true
  defp card_style?(style), do: style in @edges

  test "cards have no box-drawing characters, only a filled surface" do
    for model <- pages(), width <- [90, 160, 250] do
      rows = model |> render(width) |> Enum.filter(&card_row?/1)
      assert rows != []

      for row <- rows do
        refute text(row) =~ ~r/[\x{2500}-\x{257F}]/u, "a line in a card: #{text(row)}"
      end
    end
  end

  test "card rows fill their surface edge to edge" do
    for model <- pages() do
      rows = render(model, 90)

      for row <- rows, Enum.any?(row, &match?({{s, _}, _} when s in @surfaces, &1)) do
        [{:plain, " "} | card] = row
        assert Enum.all?(card, &match?({{s, _}, _} when s in @surfaces, &1))
        assert String.length(text(card)) == 89
      end
    end
  end

  test "the selected option is on the selected surface, the others on the card surface" do
    rows = render(PanelFixture.model(:choice), 90)
    selected = Enum.find(rows, &(text(&1) =~ "1. Use files"))
    other = Enum.find(rows, &(text(&1) =~ "2. Use memory"))

    assert text(selected) =~ "▸"
    assert Enum.all?(tl(selected), &match?({{:card_selected, _}, _}, &1))
    assert Enum.all?(tl(other), &match?({{:card, _}, _}, &1))

    at = Enum.find_index(rows, &(&1 == selected))
    assert [{:plain, " "}, {:card_selected_edge, _}] = Enum.at(rows, at - 1)
  end

  test "what went wrong is a card whose heading says it in the error colour" do
    rows = render(PanelFixture.model(:stuck), 90)
    heading = Enum.find(rows, &(text(&1) =~ "What went wrong"))
    assert {{:card, :error}, "What went wrong"} in heading
  end

  test "the page's eyebrow is light blue bold text on the page, the title bold under it" do
    rows = render(PanelFixture.model(:choice), 90)
    at = Enum.find_index(rows, &(text(&1) =~ "◆ YOUR DECISION · D-7"))

    assert {:eyebrow, "◆ YOUR DECISION · D-7"} in Enum.at(rows, at)
    assert {:bold, "How do we store examples?"} in Enum.at(rows, at + 1)

    refute Enum.any?(rows, fn row ->
             Enum.any?(row, &match?({:header, _}, &1)) and row != hd(rows)
           end)

    assert Palette.ansi(:eyebrow, :dark) |> IO.iodata_to_binary() =~ "\e[0;1;"
  end

  test "text on either card surface reaches 4.5:1 in both themes" do
    roles =
      for model <- pages(),
          row <- render(model, 90),
          {{surface, role}, text} <- row,
          surface in @surfaces,
          String.trim(text) not in ["", "▎"],
          uniq: true,
          do: role

    roles =
      Enum.uniq(roles ++ [:plain, :bold, :dim, :muted, :ok, :warning, :error, :pending, :info])

    for theme <- [:dark, :light], surface <- @surfaces, role <- roles do
      {fg, bg} = Palette.colors({surface, role}, theme)

      assert Palette.contrast(fg, bg) >= 4.5,
             "#{inspect(role)} on #{surface} in #{theme}: #{Palette.contrast(fg, bg)}"
    end
  end

  test "the surfaces differ from the page and each other, the eyebrow reads on the page" do
    for theme <- [:dark, :light] do
      {_, page} = Palette.colors(:plain, theme)
      {_, card} = Palette.colors({:card, :plain}, theme)
      {_, selected} = Palette.colors({:card_selected, :plain}, theme)
      assert Enum.uniq([page, card, selected]) == [page, card, selected]
      assert Palette.colors(:card_edge, theme) == {card, page}
      assert Palette.colors(:card_selected_edge, theme) == {selected, page}

      {fg, bg} = Palette.colors(:eyebrow, theme)
      assert bg == page and Palette.contrast(fg, bg) >= 4.5
    end
  end

  test "without truecolor a selected card has a distinct left bar" do
    for model <- pages() do
      rows = render(model, 90, false)
      refute Enum.any?(rows, &card_row?/1)
    end

    rows = render(PanelFixture.model(:choice), 90, false)
    assert [{:plain, " "}, {:frame, "▉"} | _] = Enum.find(rows, &(text(&1) =~ "1. Use files"))

    assert [{:plain, " "}, {:rest_frame, "▌"} | _] =
             Enum.find(rows, &(text(&1) =~ "2. Use memory"))

    stuck = render(PanelFixture.model(:stuck), 90, false)

    assert [{:plain, " "}, {:error_frame, "▌"} | _] =
             Enum.find(stuck, &(text(&1) =~ "What went wrong"))
  end
end
