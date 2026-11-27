defmodule AtlasTui.ItemPageBlocksTest do
  use ExUnit.Case, async: true
  alias AtlasTui.{Model, PanelFixture, View}

  defp page(rows, aside \\ "2 of 3 done", detail \\ "Refine") do
    %{
      "op" => "page",
      "path" => "/k/widget/W-1",
      "title" => "Widget",
      "reason" => "open",
      "blocks" => [
        %{"id" => "header", "type" => "header", "props" => %{
          "title" => "Widget", "detail" => detail, "since" => "2026-11-24T09:00:00Z"
        }},
        %{"id" => "parts", "type" => "list", "props" => %{
          "title" => "Parts", "aside" => aside, "empty" => "No parts yet", "rows" => rows
        }}
      ]
    }
  end

  defp model(rows, aside \\ "2 of 3 done", detail \\ "Refine") do
    %{PanelFixture.projected(page(rows, aside, detail)) | now: ~U[2026-11-27 12:00:00Z]}
  end

  defp rendered(model, width \\ 90), do: View.render(model, width, 60, 30)
  defp plain(model, width \\ 90), do: model |> rendered(width) |> View.plain()

  test "header state and list aside are presented" do
    model = model([])
    text = plain(model)
    assert text =~ "Refine · 3d"
    assert text =~ "Parts · 2 of 3 done"
    assert text =~ "No parts yet"

    refute plain(model([], nil, nil)) =~ "· 3d"
    assert plain(model([], nil)) =~ "Parts · 0"
  end

  test "list rows remain selectable and pages fit narrow widths" do
    rows = [%{"id" => "P-1", "label" => "First", "to" => "/k/part/P-1"}]
    model = model(rows)
    assert plain(model) =~ "First"
    assert {_, [{:send, %{"op" => "open", "to" => "/k/part/P-1"}}]} = Model.key(model, :enter)
    for width <- [40, 60, 90, 160], do: assert(length(rendered(model, width)) == 60)
  end
end
