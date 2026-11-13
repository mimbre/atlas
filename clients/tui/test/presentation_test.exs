defmodule AtlasTui.PresentationTest do
  use ExUnit.Case, async: true
  alias AtlasTui.{Console, Model, Palette, View}

  defp model do
    model = Model.new("test")

    model = %{
      model
      | connected: true,
        console: %{
          model.console
          | phase: :ready,
            stale: false,
            shell: %{
              "title" => "Atlas Console",
              "revision" => "fixture",
              "tabs" => [
                %{"id" => "widgets", "label" => "Widgets", "to" => "/k/widget"}
              ]
            }
        }
    }

    page = %{
      "op" => "page",
      "path" => "/k/widget",
      "title" => "Widgets",
      "blocks" => [
        %{
          "id" => "list",
          "type" => "list",
          "props" => %{
            "title" => "Widgets",
            "rows" => [
              %{
                "id" => "W-01",
                "to" => "/k/widget/W-01",
                "label" => "A title that remains readable at narrow widths",
                "detail" => "Descriptive metadata without workflow inference"
              },
              %{
                "id" => "W-02",
                "to" => "/k/widget/W-02",
                "label" => "Second title",
                "detail" => "Another detail"
              }
            ]
          }
        }
      ]
    }

    actual =
      __DIR__ |> Path.join("fixtures/console-actions.json") |> File.read!() |> JSON.decode!()

    page = actual |> Map.merge(page) |> Map.put("blocks", page["blocks"] ++ actual["blocks"])
    {model, []} = Console.receive(model, page)
    assert model.console.action_error == nil
    model
  end

  test "both themes keep all text roles above 4.5:1 contrast on their own surface" do
    for theme <- [:light, :dark],
        role <- [
          :plain,
          :bold,
          :dim,
          :selected,
          :cursor,
          :prod,
          :ok,
          :pending,
          :error,
          :info,
          :muted,
          {:selected, :muted},
          :pending_selected
        ] do
      {fg, bg} = Palette.colors(role, theme)
      [low, high] = Enum.sort([luminance(fg), luminance(bg)])
      assert (high + 0.05) / (low + 0.05) >= 4.5, "#{theme} #{inspect(role)}"
    end
  end

  test "theme selection is deterministic and unknown settings retain dark default" do
    assert Palette.theme("light") == :light
    assert Palette.theme("dark") == :dark
    assert Palette.theme(nil) == :dark
    assert Palette.theme("other") == :dark
  end

  test "actual rendering preserves labels, selection marker and status in either palette" do
    model = model()

    for width <- [20, 38, 100] do
      rows = View.render(model, width, 40, 5)
      text = View.plain(rows)
      assert text =~ "Widgets · 2"
      assert text =~ "› W-01"
      assert text =~ "Second"
      assert text =~ "connected"
      for row <- rows, do: assert(Enum.sum(Enum.map(row, &String.length(elem(&1, 1)))) <= width)
      assert Enum.any?(rows, &Enum.any?(&1, fn {style, _} -> style == :border end))

      for theme <- [:light, :dark] do
        ansi = rows |> View.to_ansi(theme) |> IO.iodata_to_binary()
        assert String.replace(ansi, ~r/\e\[[0-9;]*[mKHJ]/, "") |> String.contains?("› W-01")
        assert ansi =~ "48;2;"
      end
    end

    assert model.values == %{}
  end

  test "empty content remains visible and disconnected/error status keeps literal meaning" do
    model = model()

    model = %{
      model
      | blocks: [%AtlasTui.Blocks.List{title: "Widgets", rows: [], empty: "No widgets yet."}]
    }

    assert model |> View.render(60, 20, 5) |> View.plain() =~ "No widgets yet."
    model = %{model | connected: false, notice: %{tone: "error", text: "Cannot save"}}
    text = model |> View.render(60, 20, 5) |> View.plain()
    assert text =~ "not connected"
    assert text =~ "✗ Cannot save"
  end

  test "supplied highlight tones remain labeled without color and do not infer workflow state" do
    for {tone, label, style} <- [
          {"ok", "OK", :ok},
          {"pending", "Pending", :pending},
          {"error", "Error", :error},
          {"info", "Info", :info},
          {"custom", "custom", :dim}
        ] do
      m = model()

      m = %{
        m
        | markup: [
            %{
              "kind" => "highlight",
              "start" => "list",
              "end" => "list",
              "value" => %AtlasTui.Blocks.Highlight{tone: tone}
            }
          ]
      }

      rows = View.render(m, 60, 40, 5)
      assert View.plain(rows) =~ "[#{label}]"
      assert Enum.any?(rows, &Enum.member?(&1, {style, "[#{label}]"}))
      assert View.plain(rows) =~ "W-01"
      refute model() |> View.render(60, 40, 5) |> View.plain() =~ "[#{label}]"
    end
  end

  test "list headings retain their count across the minimum framing width" do
    for width <- 1..20 do
      rows = View.render(model(), width, 240, 5)
      heading = for row <- rows, {:bold, text} <- row, into: "", do: text
      assert String.replace(heading, ~r/\s/u, "") =~ "Widgets·2"
      for row <- rows, do: assert(Enum.sum(Enum.map(row, &String.length(elem(&1, 1)))) <= width)
    end
  end

  test "pending targets keep the shell but hide previous content and action affordances" do
    model = model()

    for legend <- [nil, %{scroll: 0}],
        width <- [60, 150] do
      pending = %{
        model
        | console: %{model.console | expected: "/k/part", restoring: false, legend: legend}
      }

      text = pending |> View.render(width, 30, 5) |> View.plain()
      assert text =~ "Atlas Console"
      assert text =~ "Loading…"
      refute text =~ "W-01"
      refute text =~ "Second title"
      refute text =~ "Keys"
    end
  end

  test "reconnection restoration retains the actual request draft rather than a loading body" do
    model = model()
    {model, []} = Model.agent_action(model, "Ask", nil)
    {model, []} = Model.literal(model, {:char, "Draft request"})

    restoring = %{
      model
      | console: %{model.console | expected: model.path, restoring: true}
    }

    text = restoring |> View.render(90, 30, 5) |> View.plain()
    assert text =~ "Draft request"
    assert text =~ "W-01"
    refute text =~ "Loading…"
  end

  test "detail labels and values remain complete and separated across widths" do
    for width <- [24, 38, 80, 140],
        label <- ["Short", "Context window tokens", "Exactly16Letters", "実行状況 é の長いフィールド名"] do
      value = "VALUE" <> String.duplicate("界é", 12) <> "_END"
      origin = %{since: nil, by: "tester", cause: "原因界é_END"}

      item = %AtlasTui.Blocks.Item{
        title: "Details",
        fields: [%{label: label, value: value, origin: origin}]
      }

      rows = View.render(%{model() | blocks: [item], markup: []}, width, 80, 5)
      text = View.plain(rows) |> String.replace(~r/\s/u, "")
      assert text =~ String.replace(label, ~r/\s/u, "")
      assert text =~ value
      assert text =~ "bytester·原因界é_END"

      for row <- rows,
          {left, right} <- Enum.zip(row, Enum.drop(row, 1)),
          elem(left, 0) == :dim and elem(right, 0) == :plain,
          String.contains?(elem(right, 1), "VALUE") do
        assert String.ends_with?(elem(left, 1), " ")
      end
    end
  end

  defp luminance({r, g, b}) do
    [r, g, b]
    |> Enum.map(fn value ->
      value = value / 255
      if value <= 0.04045, do: value / 12.92, else: :math.pow((value + 0.055) / 1.055, 2.4)
    end)
    |> Enum.zip([0.2126, 0.7152, 0.0722])
    |> Enum.sum_by(fn {value, weight} -> value * weight end)
  end

  defp narrow_content(width, framed, label, detail) do
    m = model()
    row = %AtlasTui.Blocks.Row{id: "ID12345", label: label, detail: detail, to: "/k/widget/one"}

    markup =
      if framed,
        do: [
          %{
            "kind" => "part",
            "start" => "items",
            "end" => "items",
            "value" => %AtlasTui.Blocks.Part{title: "Part", role: "related"}
          }
        ],
        else: []

    m = %{
      m
      | blocks: [%AtlasTui.Blocks.List{title: "Items", rows: [row]}],
        ids: ["items"],
        markup: markup,
        console: %{m.console | shell: nil},
        updated: nil
    }

    View.render(m, width, 160, 5)
  end

  test "each item occupies one adjacent row with inline metadata and no separators" do
    rows = View.render(model(), 110, 40, 5)
    lines = String.split(View.plain(rows), "\n")
    first = Enum.find_index(lines, &String.contains?(&1, "W-01"))
    second = Enum.find_index(lines, &String.contains?(&1, "W-02"))
    assert second == first + 1
    assert Enum.at(lines, first) =~ "Descriptive"
    assert Enum.at(lines, second) =~ "Second title"
    assert Enum.at(lines, second) =~ "Another detail"

    assert Enum.any?(Enum.at(rows, first), fn {style, text} ->
             style == :dim and String.contains?(text, "Descriptive")
           end)
  end

  test "ID title and compact summary columns align without displaying provenance prose" do
    m = model()
    [list] = m.blocks

    rows = [
      %AtlasTui.Blocks.Row{
        id: "I1",
        label: "Short",
        detail: "Test it · since yesterday · Flow: completed",
        to: "/k/widget/one"
      },
      %AtlasTui.Blocks.Row{
        id: "LONG-ID",
        label: "界語é longer title",
        detail: "Build it · 3/4 · since today · Assigned by someone",
        to: "/k/widget/two"
      },
      %AtlasTui.Blocks.Row{id: nil, label: "No ID", detail: nil, to: "/k/widget/three"}
    ]

    rendered = View.render(%{m | blocks: [%{list | rows: rows}]}, 90, 30, 5) |> View.plain()
    lines = String.split(rendered, "\n")
    first = Enum.find(lines, &String.contains?(&1, "Short"))
    second = Enum.find(lines, &String.contains?(&1, "界語"))
    third = Enum.find(lines, &String.contains?(&1, "No ID"))

    column = fn line, text ->
      line
      |> String.split(text, parts: 2)
      |> hd()
      |> String.graphemes()
      |> Enum.sum_by(&if(&1 in ["界", "語"], do: 2, else: 1))
    end

    assert column.(first, "Short") == column.(second, "界語")
    assert column.(first, "Short") == column.(third, "No ID")
    assert column.(first, "Test it") == column.(second, "Build it")
    assert second =~ "Build it · 3/4"
    refute rendered =~ "since"
    refute rendered =~ "Flow:"
    refute rendered =~ "Assigned by someone"
  end

  test "narrow and framed items stay single-line without splitting wide or combining graphemes" do
    for framed <- [false, true],
        width <- if(framed, do: 8..40, else: 1..40) do
      rows = narrow_content(width, framed, String.duplicate("界語é❤️1️⃣", 20), "meta\nstatus")
      selected = Enum.filter(rows, &Enum.any?(&1, fn {style, _} -> style == :selected end))
      assert length(selected) == 1
      assert View.plain(selected) =~ "›"

      for row <- rows do
        text = Enum.map_join(row, &elem(&1, 1))
        refute text =~ "\n"
        assert String.valid?(text)

        cells =
          text
          |> String.graphemes()
          |> Enum.sum_by(&if(&1 in ["界", "語", "❤️", "1️⃣"], do: 2, else: 1))

        assert cells <= width
      end
    end
  end

  test "embedded whitespace in item labels and metadata cannot create extra terminal rows" do
    rows = narrow_content(100, false, "first\nsecond\ttitle", "status\r\nmetadata")
    [selected] = Enum.filter(rows, &Enum.any?(&1, fn {style, _} -> style == :selected end))
    text = Enum.map_join(selected, &elem(&1, 1))
    assert text =~ "first second title"
    assert text =~ "status metadata"
  end
end
