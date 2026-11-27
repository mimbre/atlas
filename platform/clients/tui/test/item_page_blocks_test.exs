defmodule AtlasTui.ItemPageBlocksTest do
  @moduledoc """
  An item's page as Control sends it (D-0104, contract 0.41.0): a stack of simple blocks
  (its header with where it stands, its intro, what is built already, its parts, the
  answer that suggests one) and its details. Every property optional (D-0105).
  """
  use ExUnit.Case, async: true
  alias AtlasTui.{Model, PanelFixture, View}

  @widget "/k/widget/W-40"

  defp rows(model, width \\ 90), do: View.render(model, width, 60, 30)
  defp lines(model, width \\ 90), do: model |> rows(width) |> View.plain() |> String.split("\n")
  defp at(lines, text), do: Enum.find_index(lines, &(&1 =~ text))
  defp line(model, text), do: model |> lines() |> Enum.find(&(&1 =~ text))

  # The styles of the segments of the row that shows `text`.
  defp styles(model, text) do
    model
    |> rows()
    |> Enum.find(fn row -> Enum.map_join(row, &elem(&1, 1)) =~ text end)
    |> Enum.map(&elem(&1, 0))
  end

  defp ago(hours),
    do: DateTime.utc_now() |> DateTime.add(-hours * 3_600 - 60) |> DateTime.to_iso8601()

  defp row(key, label, detail, tone, hours),
    do: %{
      "id" => key,
      "kind" => "Part",
      "icon" => "route",
      "label" => label,
      "detail" => detail,
      "tone" => tone,
      "since" => ago(hours),
      "to" => "/k/part/" <> key,
      "key" => key
    }

  defp page(rows, list, header \\ %{}) do
    blocks = [
      %{
        "id" => "header",
        "type" => "header",
        "props" =>
          Map.merge(
            %{
              "eyebrow" => "WIDGET",
              "key" => "W-40",
              "icon" => "frame",
              "title" => "A newcomer finds their way around",
              "detail" => "Break down · Refine",
              "since" => ago(72)
            },
            header
          )
      },
      %{
        "id" => "intro",
        "type" => "text",
        "props" => %{"text" => "Ada joins the team and opens Atlas for the first time."}
      },
      %{
        "id" => "built",
        "type" => "text",
        "props" => %{
          "label" => "Already built",
          "role" => "context",
          "text" => "The Assigned to you tab and its counts."
        }
      },
      %{
        "id" => "items",
        "type" => "list",
        "props" =>
          Map.merge(
            %{
              "title" => "Parts",
              "aside" => "2 of 3 done",
              "empty" => "Once Design is picked up, its agent proposes them here.",
              "rows" => rows
            },
            list
          )
      },
      %{
        "id" => "answers",
        "type" => "answers",
        "props" => %{
          "answers" => [
            %{
              "label" => "Suggest a part",
              "key" => "s",
              "to" => @widget <> "/answer/s",
              "note" => true,
              "weight" => "main",
              "icon" => "suggest"
            }
          ]
        }
      },
      %{
        "id" => "item",
        "type" => "item",
        "props" => %{
          "title" => "",
          "fields" => [
            %{"label" => "Phase", "value" => "Break down"},
            %{"label" => "Flux group", "value" => "Refine"}
          ]
        }
      }
    ]

    %{
      "op" => "page",
      "path" => @widget,
      "title" => "Widget W-40",
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

  defp parts,
    do: [
      row("P-50", "Ada sees what is hers", "Accepted", "done", 48),
      row("P-51", "Ada finds the docs", "Accepted", "done", 30),
      row("P-52", "Ada asks for help", "Proposed", "attention", 5)
    ]

  defp model(rows \\ parts(), list \\ %{}), do: PanelFixture.projected(page(rows, list))

  test "an item's blocks top down: header and its state, intro, already built, parts, answer, details" do
    lines = lines(model())

    order =
      Enum.map(
        [
          "□ WIDGET · W-40",
          "A newcomer finds their way around",
          "Break down · Refine · 3d",
          "Ada joins the team",
          "ALREADY BUILT",
          "The Assigned to you tab and its counts.",
          "Parts · 2 of 3 done",
          "P-50",
          "P-52",
          "s Suggest a part · note",
          ~r/^  Details$/,
          "Flux group"
        ],
        &at(lines, &1)
      )

    assert Enum.all?(order, &is_integer/1)
    assert order == Enum.sort(order)
  end

  test "the header's state line is dim under its title; without a detail there is none" do
    assert :dim in styles(model(), "Break down · Refine · 3d")

    lines = lines(PanelFixture.projected(page(parts(), %{}, %{"detail" => nil})))
    assert at(lines, "A newcomer finds their way around")
    refute Enum.any?(lines, &(&1 =~ "· 3d"))
  end

  test "what is built already is a calm card under its label, not an error" do
    model = model()
    heading = styles(model, "ALREADY BUILT")
    assert Enum.any?(heading, &match?({:card, _}, &1)) or :rest_frame in heading
    refute Enum.any?(heading, &(&1 in [:error, {:card, :error}, :error_frame]))
    assert Enum.any?(styles(model, "Assigned to you tab"), &match?({:card, _}, &1))
  end

  test "the list's rows are drawn as the list column's: dot, kind glyph, key, age, title, state" do
    line = line(model(), "P-52")
    assert line =~ ~r/● ◇ P-52\s+5h\s+Ada asks for help\s+Proposed/
    assert line(model(), "P-50") =~ "Ada sees what is hers"
  end

  test "the arrows select a row and Enter opens it" do
    model = model()
    {_, opened} = Model.key(model, :enter)
    assert [{:send, %{"op" => "open", "to" => "/k/part/P-50"}}] = opened

    {moved, []} = Model.key(model, :down)
    assert line(moved, "P-51") =~ "›"
    {_, opened} = Model.key(moved, :enter)
    assert [{:send, %{"op" => "open", "to" => "/k/part/P-51"}}] = opened
  end

  test "the suggestion answer opens its note form on its key" do
    {_, by_s} = Model.key(model(), {:char, "s"})
    assert [{:send, %{"op" => "open", "to" => @widget <> "/answer/s"}}] = by_s
  end

  test "no rows yet: the heading, then what comes next, dim" do
    model = model([], %{"aside" => nil})
    assert line(model, "Parts")
    assert :dim in styles(model, "Once Design is picked up")
  end

  test "an item page fits any width" do
    for width <- [40, 60, 90, 160, 220] do
      assert length(View.render(model(), width, 60, 30)) == 60
    end
  end
end
