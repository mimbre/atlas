defmodule AtlasTui.ConsoleProjectionFixture do
  @moduledoc false
  alias AtlasTui.{Console, Model}

  # Captured Console actions provide the local editor/plan vocabulary. Tests add
  # explicit page actions below; no production client derives keys from blocks.
  @captured __DIR__ |> Path.join("console-actions.json") |> File.read!() |> JSON.decode!()

  def model(page) do
    model = Model.new("test")

    model = %{
      model
      | connected: true,
        console: %{
          model.console
          | phase: :ready,
            stale: false,
            shell: %{
              "revision" => "fixture",
              "title" => "Atlas Console",
              "tabs" => [%{"id" => "content", "label" => "Content", "to" => page["path"]}]
            }
        }
    }

    {model, []} = Console.receive(model, project(page))
    model
  end

  def receive(model, page), do: Console.receive(model, project(page))

  def project(page) do
    blocks =
      page["blocks"]
      |> Enum.with_index()
      |> Enum.map(fn {block, index} -> Map.put_new(block, "id", "##{index}") end)

    rows = Enum.flat_map(blocks, &(&1["props"]["rows"] || []))

    actions =
      Enum.map(@captured["blocks"], fn action ->
        action = put_in(action, ["props", "scope", "page"], page["path"])

        case action["props"]["operation"]["name"] do
          name when name in ["list_next", "list_previous", "open_selected"] ->
            put_in(action, ["props", "available"], rows != [])

          _ ->
            action
        end
      end)

    form_actions =
      if Enum.any?(blocks, &(&1["type"] == "form")) do
        actions
        |> Enum.filter(&(&1["props"]["scope"]["context"] == "step_form"))
        |> Enum.reject(&(&1["props"]["operation"]["name"] == "quit"))
        |> Enum.map(fn action ->
          name = action["props"]["operation"]["name"]
          name = %{"step_save" => "submit_form", "step_cancel" => "cancel_form"}[name] || name

          action
          |> Map.update!("id", &(&1 <> ":form"))
          |> put_in(["props", "scope", "context"], "form")
          |> put_in(["props", "operation", "name"], name)
        end)
      else
        []
      end

    confirm_actions =
      case Enum.find(blocks, &(&1["type"] == "confirm")) do
        nil ->
          []

        block ->
          if block["props"]["confirm_to"] do
            [
              action("confirm", ["y", "Enter"], "submit_form", "confirm"),
              action("cancel", ["n", "Esc"], "cancel_form", "confirm")
            ]
          else
            [action("cancel", ["Enter", "Esc"], "cancel_form", "confirm")]
          end
      end

    page_actions = Enum.flat_map(blocks, &page_actions/1)
    extra = form_actions ++ confirm_actions ++ page_actions

    extra =
      Enum.map(extra, fn action ->
        update_in(action, ["props", "scope"], fn scope ->
          Map.merge(scope, %{"page" => page["path"], "revision" => @captured["actions_revision"]})
        end)
      end)

    extra_groups =
      extra
      |> Enum.chunk_by(& &1["props"]["scope"]["context"])
      |> Enum.map(fn actions ->
        %{
          "kind" => "legend",
          "start" => hd(actions)["id"],
          "end" => List.last(actions)["id"],
          "props" => %{"title" => "Page", "context" => hd(actions)["props"]["scope"]["context"]}
        }
      end)

    page
    |> Map.put("actions_revision", @captured["actions_revision"])
    |> Map.put("blocks", blocks ++ actions ++ extra)
    |> Map.put("markup", (page["markup"] || []) ++ @captured["markup"] ++ extra_groups)
  end

  def action(id, keys, name, context \\ "browse", extra \\ %{}) do
    %{
      "id" => "fixture:" <> id,
      "type" => "console_action",
      "props" => %{
        "label" => id,
        "keys" => keys,
        "available" => true,
        "operation" => Map.merge(%{"name" => name}, extra),
        "scope" => %{"context" => context}
      }
    }
  end

  defp page_actions(block) do
    props = block["props"]

    commands =
      Enum.with_index(props["actions"] || [], fn command, index ->
        {name, extra} =
          case command["to"] do
            "agent:" <> intent -> {"agent_ask", %{"intent" => intent}}
            to -> {"open", %{"to" => to}}
          end

        action(block["id"] <> ":command:#{index}", [command["key"]], name, "browse", extra)
        |> put_in(["props", "label"], command["label"])
      end)

    links = links(props["links"] || [], block["id"] <> ":link")

    row_links =
      Enum.flat_map(props["rows"] || [], fn row ->
        links(row["links"] || [], block["id"] <> ":row:" <> row["to"])
        |> Enum.map(fn action ->
          update_in(
            action,
            ["props", "scope"],
            &Map.merge(&1, %{
              "on" => block["id"],
              "row" => row["id"] || row["to"]
            })
          )
        end)
      end)

    commands ++ links ++ row_links
  end

  defp links(links, prefix) do
    Enum.with_index(links, fn link, index ->
      action(prefix <> ":#{index}", [link["key"]], "open_url", "browse", %{"url" => link["url"]})
      |> put_in(["props", "label"], link["label"])
    end)
  end
end
