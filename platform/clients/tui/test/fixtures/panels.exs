defmodule AtlasTui.PanelFixture do
  @moduledoc false
  # Pages with a panel where its owner decides, as Control projects them: the panel, and
  # an action per answer of the same key (one given with a note opens its note form; one
  # with `submit_to` sends it), its actions opening pages and its links web addresses.
  alias AtlasTui.ConsoleProjectionFixture

  def model(kind, props \\ %{}), do: kind |> page(props) |> projected()

  def page(kind, props \\ %{}) do
    path = "/k/widget/K-1"

    panel = %{
      "id" => "panel",
      "type" => "panel",
      "props" => Map.merge(props(kind, path), props)
    }

    %{
      "op" => "page",
      "path" => path,
      "title" => "Widget K-1",
      "reason" => "open",
      "blocks" => [panel]
    }
  end

  def call(answer),
    do: %{
      "endpoint" => "answer",
      "params" => %{"kind" => "widget", "key" => "K-1", "answer" => answer}
    }

  defp props(:accept, path) do
    item = fn n, what, done, needs ->
      %{
        "key" => "IS-Atlas-#{n}",
        "label" => what,
        "to" => "/k/widget/IS-Atlas-#{n}",
        "details" => [
          %{"label" => "What", "value" => what},
          %{"label" => "Done", "value" => done},
          %{"label" => "Needs", "value" => needs}
        ]
      }
    end

    %{
      "heading" => "TO ACCEPT",
      "title" => "Plan for UC-Atlas-23 · Every item has a producer",
      "aside" => "3 widgets",
      "byline" => [%{"text" => "Proposed by planner"}, %{"text" => "waiting", "since" => ago(3)}],
      "items" => [
        item.(162, "Record who produced each item", "Every new item names its producer.", "—"),
        item.(
          163,
          "Show the producer on an item's page",
          "The page says who made it.",
          "IS-Atlas-162"
        ),
        item.(
          164,
          "Items from before keep working without a producer",
          "Old items open as before.",
          "IS-Atlas-162"
        )
      ],
      "answers" => [
        %{
          "label" => "Accept",
          "key" => "a",
          "to" => path <> "/answer/accept",
          "submit_to" => call("accept")
        },
        %{
          "label" => "Not accepted",
          "key" => "n",
          "to" => path <> "/answer/reject",
          "note" => true
        }
      ],
      "actions" => [%{"label" => "Full proposal", "key" => "i", "to" => "/k/proposal/P-23"}]
    }
  end

  defp props(:merge, _path) do
    %{
      "heading" => "TO MERGE",
      "title" => "#605 Items from before keep working without a producer",
      "byline" => [%{"text" => "IS-Atlas-164"}, %{"text" => "waiting", "since" => ago(1)}],
      "checks" => [
        %{"label" => "CI", "state" => "success", "text" => "Passed"},
        %{"label" => "Review", "state" => "none", "text" => "—"},
        %{"label" => "GitHub", "state" => "success", "text" => "Merged · Mergeable"}
      ],
      "actions" => [%{"label" => "Full review", "key" => "v", "to" => "/k/review/R-605"}],
      "links" => [
        %{"label" => "Open on GitHub", "key" => "o", "url" => "https://github.com/o/r/pull/605"}
      ]
    }
  end

  defp props(:decision, path) do
    %{
      "heading" => "YOUR DECISION",
      "title" => "IS-Atlas-134 is stuck: what now?",
      "byline" => [%{"text" => "", "since" => ago(26)}],
      "box" => %{
        "title" => "What went wrong",
        "text" => "The worker stopped: the tests could not reach the database.",
        "tone" => "error"
      },
      "choose" => true,
      "answers" => [
        %{
          "label" => "Retry",
          "key" => "t",
          "to" => path <> "/answer/retry",
          "submit_to" => call("retry"),
          "recommended" => true,
          "detail" => "Runs the work again from where it stopped."
        },
        %{
          "label" => "Close it",
          "key" => "c",
          "to" => path <> "/answer/close",
          "note" => true,
          "detail" => "Closes the widget; you say why."
        }
      ],
      "actions" => [%{"label" => "Agent's log", "key" => "l", "to" => "/k/run/W-134"}]
    }
  end

  defp ago(hours),
    do: DateTime.utc_now() |> DateTime.add(-hours * 3_600 - 60) |> DateTime.to_iso8601()

  # Control's actions for the answers (of a panel or an answers block): the recommended
  # one again on 0, in a choice.
  def projected(page) do
    props = Enum.find_value(page["blocks"], %{}, &(&1["props"]["answers"] && &1["props"]))
    projected = ConsoleProjectionFixture.project(page)

    scope = %{
      "page" => page["path"],
      "revision" => projected["actions_revision"],
      "context" => "browse"
    }

    answers = props["answers"] || []

    answers =
      answers ++
        if(props["choose"] == true and answers != [],
          do: [Map.put(hd(answers), "key", "0")],
          else: []
        )

    actions =
      for answer <- answers do
        operation =
          if answer["submit_to"],
            do: %{"name" => "invoke", "call" => answer["submit_to"]},
            else: %{"name" => "open", "to" => answer["to"]}

        %{
          "id" => "answer-" <> answer["key"],
          "type" => "console_action",
          "props" => %{
            "label" => answer["label"],
            "keys" => [answer["key"]],
            "available" => true,
            "operation" => operation,
            "scope" => scope
          }
        }
      end

    legend =
      for [_ | _] <- [actions],
          do: %{
            "kind" => "legend",
            "start" => hd(actions)["id"],
            "end" => List.last(actions)["id"],
            "props" => %{"title" => "Answers", "context" => "browse"}
          }

    message =
      projected
      |> Map.update!("blocks", &(&1 ++ actions))
      |> Map.update!("markup", &(&1 ++ legend))

    ConsoleProjectionFixture.projected(page, message)
  end
end
