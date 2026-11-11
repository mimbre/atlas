defmodule AtlasControl.ConsoleProjectionTest do
  use ExUnit.Case, async: true
  alias AtlasBFFContract.Console

  defp native do
    %{
      "path" => "/k/widget",
      "blocks" => [
        %{
          "id" => "items",
          "type" => "list",
          "props" => %{
            "rows" => [
              %{
                "id" => "one",
                "to" => "/k/widget/one",
                "links" => [
                  %{"label" => "External", "key" => "o", "url" => "https://example.org/one"}
                ]
              },
              %{
                "id" => "two",
                "to" => "/k/widget/two",
                "links" => [
                  %{"label" => "External", "key" => "o", "url" => "https://example.org/two"}
                ]
              }
            ]
          }
        }
      ],
      "markup" => []
    }
  end

  defp current,
    do: %{path: "/k/widget", context: "browse", generation: 1, on: "items", row: "one"}

  test "declared worker operations share normal action scope, availability and validation" do
    execution = %{
      "worker" => %{"environment" => "test", "machine" => "machine", "worker" => "worker"},
      "turn" => "turn",
      "attempt" => "1"
    }

    declaration = %{
      label: "Connect or retry output",
      keys: ["o"],
      operation: %{
        "name" => "worker_output_subscribe",
        "execution" => execution,
        "cursor" => "accepted-output-cursor"
      },
      on: "items",
      row: nil,
      available: false,
      reason: "Output unavailable"
    }

    page = put_in(native(), ["blocks", Access.at(0), "props", "rows"], [])
    assert {:ok, projected} = AtlasControl.Console.project(page, 1, [declaration])
    assert {:ok, projection} = Console.compile(projected)
    action = Enum.find(projection.actions, &(&1["props"]["label"] == declaration.label))
    assert action["props"]["operation"] == declaration.operation
    assert action["props"]["scope"]["on"] == "items"
    refute action["props"]["available"]
    assert {:error, :unavailable_binding} = Console.capture(projection, "o", current())

    enabled = %{declaration | available: true, reason: nil}
    assert {:ok, projected} = AtlasControl.Console.project(page, 1, [enabled])
    assert {:ok, projection} = Console.compile(projected)
    assert {:ok, event} = Console.capture(projection, "o", current())
    assert {:ok, action} = Console.resolve(projection, event, current())
    assert action["props"]["operation"] == declaration.operation

    assert {:error, :stale_or_unavailable_action} =
             Console.resolve(projection, event, %{current() | path: "/workers"})

    for operation <- [
          Map.put(declaration.operation, "interaction", "wrong-cursor-domain"),
          Map.put(declaration.operation, "execution", %{"turn" => "turn"}),
          %{
            "name" => "worker_output_next",
            "subscription" => "viewer-token",
            "cursor" => "cursor"
          },
          %{
            "name" => "worker_receipts",
            "execution" => execution,
            "interaction_source" => "arbitrary"
          }
        ] do
      assert {:error, _} =
               AtlasControl.Console.project(page, 1, [%{enabled | operation: operation}])
    end
  end

  test "bindings and legend consume the same scoped action objects" do
    assert {:ok, page} = AtlasControl.Console.project(native(), 2)
    assert {:ok, projection} = Console.compile(page)
    assert {:ok, bindings} = Console.bindings(projection, current())
    action = bindings["o"]
    assert action in projection.actions
    assert action["props"]["scope"]["row"] == "one"
    assert {:ok, event} = Console.capture(projection, "o", current())
    assert {:ok, ^action} = Console.resolve(projection, event, current())
    assert {:ok, other} = Console.bindings(projection, %{current() | row: "two"})
    refute other["o"]["id"] == action["id"]

    refute Enum.any?(
             projection.actions,
             &(&1["props"]["scope"]["context"] == "form" and
                 &1["props"]["operation"]["name"] == "submit")
           )
  end

  test "captured actions are denied after any page context row or generation change" do
    {:ok, page} = AtlasControl.Console.project(native(), 2)
    {:ok, p} = Console.compile(page)
    {:ok, event} = Console.capture(p, "o", current())

    for changed <- [
          %{current() | row: "two"},
          %{current() | generation: 2},
          %{current() | context: "ask"},
          %{current() | path: "/"}
        ] do
      assert {:error, :stale_or_unavailable_action} = Console.resolve(p, event, changed)
    end

    {:ok, refreshed} = AtlasControl.Console.project(native(), 2)
    {:ok, next} = Console.compile(refreshed)
    assert {:error, :stale_or_unavailable_action} = Console.resolve(next, event, current())
    assert {:error, :unavailable_binding} = Console.capture(p, "F999", current())
  end

  test "unknown operations tokens scopes duplicate bindings and malformed legends fail closed" do
    {:ok, page} = AtlasControl.Console.project(native(), 2)
    first = Enum.find_index(page["blocks"], &(&1["type"] == "console_action"))

    for {field, value} <- [
          {"operation", %{"name" => "system"}},
          {"keys", ["Ctrl+Nonsense"]},
          {"scope", %{}},
          {"available", "yes"}
        ] do
      invalid = put_in(page, ["blocks", Access.at(first), "props", field], value)
      assert {:error, :invalid_console_projection} = Console.compile(invalid)
    end

    assert {:error, _} = Console.compile(%{page | "markup" => []})

    duplicate =
      update_in(page, ["blocks", Access.at(first + 1), "props", "keys"], fn _ -> ["Tab"] end)

    assert {:error, _} = Console.compile(duplicate)
    missing = put_in(page, ["blocks", Access.at(first), "props", "scope", "on"], "absent")
    assert {:error, _} = Console.compile(missing)

    assert {:error, _} =
             Console.compile(%{page | "blocks" => List.duplicate(hd(page["blocks"]), 513)})
  end

  test "finite operations validate destinations without evaluating them" do
    for to <- ["/k/widget/W%201", "/k/widget/%C3%A9", "/"] do
      assert Console.operation?(%{"name" => "open", "to" => to})
    end

    for to <- ["k/widget", "/k/widget/", "/k/widget/%FF", "/k/widget/%61"] do
      refute Console.operation?(%{"name" => "open", "to" => to})
    end

    for url <- [
          "javascript:alert(1)",
          "file:///tmp/a",
          "https://example.org:bad",
          "https://example.org/a b"
        ] do
      refute Console.operation?(%{"name" => "open_url", "url" => url})
    end

    refute Console.operation?(%{"name" => "quit", "to" => "/"})
    refute Console.key?("\n")
    refute Console.key?("\e")
  end

  defp panes do
    page = native()
    content = %{"id" => "content", "type" => "item", "props" => %{"title" => "Content"}}

    %{
      page
      | "blocks" => [content | page["blocks"]],
        "markup" => [
          %{
            "kind" => "part",
            "start" => "content",
            "end" => "content",
            "props" => %{"role" => "main", "title" => "Content"}
          },
          %{
            "kind" => "part",
            "start" => "items",
            "end" => "items",
            "props" => %{"role" => "related", "title" => "References"}
          }
        ]
    }
  end

  test "complete panes expose browse-only focus bindings without replacing tab navigation" do
    {:ok, page} = AtlasControl.Console.project(panes(), 2)
    {:ok, projection} = Console.compile(page)
    {:ok, bindings} = Console.bindings(projection, current())
    assert bindings["["]["props"]["operation"]["name"] == "part_previous"
    assert bindings["]"]["props"]["operation"]["name"] == "part_next"
    assert bindings["Tab"]["props"]["operation"]["name"] == "tab_next"
    assert bindings["Shift+Tab"]["props"]["operation"]["name"] == "tab_previous"

    for context <- ["form", "ask", "step_form"] do
      {:ok, editing} = Console.bindings(projection, %{current() | context: context})
      refute Map.has_key?(editing, "[")
      refute Map.has_key?(editing, "]")
    end
  end

  test "absent single nested and incomplete panes do not offer focus cycling" do
    page = panes()
    [content, references] = page["markup"]
    whole = %{content | "end" => "items"}

    for markup <- [[], [whole], [content], [whole, content, references]] do
      {:ok, projected} = AtlasControl.Console.project(%{page | "markup" => markup}, 2)
      {:ok, projection} = Console.compile(projected)
      {:ok, bindings} = Console.bindings(projection, current())
      refute Map.has_key?(bindings, "[")
      refute Map.has_key?(bindings, "]")
    end
  end

  test "native view bindings retain precedence over pane aliases" do
    page =
      put_in(panes(), ["blocks", Access.at(0), "props", "actions"], [
        %{"key" => "]", "label" => "Open", "to" => "/k/widget/one"}
      ])

    {:ok, projected} = AtlasControl.Console.project(page, 2)
    {:ok, projection} = Console.compile(projected)
    {:ok, bindings} = Console.bindings(projection, current())
    assert bindings["]"]["props"]["operation"] == %{"name" => "open", "to" => "/k/widget/one"}
    assert bindings["["]["props"]["operation"]["name"] == "part_previous"
  end

  test "projection expansion is bounded before materializing row actions" do
    page =
      put_in(
        native(),
        ["blocks", Access.at(0), "props", "rows"],
        for i <- 1..300 do
          %{
            "id" => "row#{i}",
            "links" => [%{"key" => "o", "label" => "Open", "url" => "https://example.org"}]
          }
        end
      )

    assert {:error, "Console projection exceeds action limit"} =
             AtlasControl.Console.project(page, 2)
  end
end
