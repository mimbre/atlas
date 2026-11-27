defmodule AtlasTui.MarkdownTest do
  use ExUnit.Case, async: true

  alias AtlasTui.{Markdown, PanelFixture, View}

  defp plain(lines), do: Enum.map_join(lines, "\n", fn line -> Enum.map_join(line, &elem(&1, 1)) end)
  defp render(text, width \\ 100), do: Markdown.render(text, width, &String.length/1)

  test "all heading levels retain their hierarchy below the page title" do
    source = Enum.map_join(1..6, "\n", fn n -> String.duplicate("#", n) <> " Level #{n}" end)
    output = source |> render() |> plain()
    for n <- 1..6, do: assert(output =~ "H#{n} Level #{n}")
    assert "###### Start here\n## Skip" |> render() |> plain() =~ "H6 Start here\nH2 Skip"
  end

  test "emphasis, lists, links and fenced code are displayed, not executed" do
    source = """
    A **bold** and *emphasized* paragraph with [site](https://example.test).
    - first
    2. second
    ```sh
    echo **literal**
    ```
    <script>alert(1)</script>
    ![image](x)
    """
    lines = render(source)
    output = plain(lines)
    assert output =~ "A bold and emphasized paragraph with site (https://example.test)."
    assert output =~ "- first\n2. second"
    assert output =~ "echo **literal**"
    assert output =~ "<script>alert(1)</script>"
    assert output =~ "![image](x)"
    assert Enum.any?(List.flatten(lines), &match?({:bold, "bold"}, &1))
    refute output =~ "```"
  end

  test "wraps long text and strips terminal controls" do
    lines = render("# A long heading\n[a](javascript:alert)\n\e[2Jdanger", 8)
    refute plain(lines) =~ "\e"
    assert plain(lines) =~ "danger"
    for line <- lines, do: assert(String.length(plain([line])) <= 8)
  end

  test "item field Markdown is opt-in and retains plain fields" do
    page = %{
      "op" => "page", "path" => "/k/test", "title" => "Page",
      "blocks" => [%{
        "id" => "item", "type" => "item",
        "props" => %{"title" => "Details", "fields" => [
          %{"label" => "Description", "value" => "# Heading\n- **strong**"},
          %{"label" => "Plain", "value" => "**literal**"},
          %{"label" => "Unknown", "value" => "**unknown**"}
        ]}
      }], "markup" => []
    }
    model = PanelFixture.projected(page)
    [item] = model.blocks
    [marked, plain, unknown] = item.fields
    item = %{item | fields: [Map.put(marked, :format, "markdown"), plain, Map.put(unknown, :format, "other")]}
    model = %{model | blocks: [item]}

    for width <- [24, 80] do
      output = model |> View.render(width, 40, 30) |> View.plain()
      assert output =~ "H1 Heading"
      assert output =~ "- strong"
      assert output =~ "**literal**"
      assert output =~ "**unknown**"
    end
  end

  test "only the markdown format changes text blocks in either theme" do
    page = %{
      "op" => "page", "path" => "/k/test", "title" => "Page",
      "blocks" => [
        %{"id" => "marked", "type" => "text", "props" => %{"text" => "# Heading"}},
        %{"id" => "plain", "type" => "text", "props" => %{"text" => "# Literal"}},
        %{"id" => "unknown", "type" => "text", "props" => %{"text" => "**literal**"}}
      ], "markup" => []
    }
    model = PanelFixture.projected(page)
    [marked, plain, unknown] = model.blocks
    model = %{model | blocks: [Map.put(marked, :format, "markdown"), plain, Map.put(unknown, :format, "other")]}

    for width <- [24, 80] do
      rows = View.render(model, width, 40, 30)
      output = View.plain(rows)
      assert output =~ "H1 Heading"
      assert output =~ "# Literal"
      assert output =~ "**literal**"
      for theme <- [:light, :dark], do: assert(IO.iodata_to_binary(View.to_ansi(rows, theme)) =~ "Heading")
    end
  end
end
