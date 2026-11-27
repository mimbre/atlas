defmodule AtlasTui.MachinesPageTest do
  @moduledoc """
  A machine's page as Control sends it: only blocks the TUI already knows (a header with
  the gears icon, a state line, a list of slots, the upgrade answer, the actions, and its
  details beside it). Nothing on it is special to machines.
  """
  use ExUnit.Case, async: true
  alias AtlasTui.{PanelFixture, View}

  @path "/machines/mac-mini"

  defp page(health_role) do
    %{
      "op" => "page",
      "path" => @path,
      "title" => "mac-mini",
      "reason" => "open",
      "blocks" => [
        %{
          "id" => "header",
          "type" => "header",
          "props" => %{
            "eyebrow" => "MACHINE",
            "key" => "mac-mini",
            "title" => "Melle's Mac mini",
            "icon" => "gears"
          }
        },
        %{
          "id" => "state",
          "type" => "text",
          "props" =>
            Map.merge(
              %{"text" => "Not heard from in 10 minutes. Start Atlas on the machine."},
              if(health_role, do: %{"role" => health_role}, else: %{})
            )
        },
        %{
          "id" => "slots",
          "type" => "list",
          "props" => %{
            "rows" => [
              %{"label" => "Slot 1", "detail" => "free", "to" => @path <> "/slot-1"}
            ],
            "empty" => "No slots."
          }
        },
        %{
          "id" => "answers",
          "type" => "answers",
          "props" => %{
            "answers" => [
              %{
                "label" => "Upgrade to the newest build",
                "key" => "u",
                "to" => @path <> "/upgrade",
                "weight" => "main"
              }
            ]
          }
        },
        %{
          "id" => "actions",
          "type" => "actions",
          "props" => %{
            "actions" => [
              %{"label" => "Edit configuration", "key" => "e", "to" => "/machines"}
            ]
          }
        },
        %{
          "id" => "item",
          "type" => "item",
          "props" => %{
            "title" => "mac-mini",
            "fields" => [%{"label" => "Build", "value" => "0.41.0"}],
            "actions" => []
          }
        }
      ],
      "markup" => [
        %{
          "kind" => "section",
          "start" => "slots",
          "end" => "slots",
          "props" => %{"title" => "Slots"}
        },
        %{
          "kind" => "part",
          "start" => "item",
          "end" => "item",
          "props" => %{"title" => "Details", "role" => "details"}
        }
      ]
    }
  end

  defp screen(model),
    do: View.render(model, 90, 60, 30) |> View.plain()

  test "the machine page shows its header with the gears glyph, slots, and both commands in the key line" do
    text = screen(PanelFixture.projected(page(nil)))

    assert text =~ " ▣ MACHINE · mac-mini\n Melle's Mac mini\n"
    assert text =~ "Not heard from in 10 minutes."
    assert text =~ "Slot 1"
    assert text =~ "Build"
    assert text =~ "u Upgrade to the newest build"
    assert text =~ "e Edit configuration"
  end

  test "an unhealthy machine's state line stands in a card; a healthy one is a plain line" do
    on_card? = fn model ->
      View.render(model, 90, 60, 30)
      |> List.flatten()
      |> Enum.any?(fn {style, text} -> text =~ "Not heard" and match?({:card, _}, style) end)
    end

    assert on_card?.(PanelFixture.projected(page("error")))
    refute on_card?.(PanelFixture.projected(page(nil)))
  end
end
