defmodule AtlasTui.PanelFixture do
  @moduledoc false
  # Pages where its owner decides, as Control projects them: a panel, or a decision as a
  # stack of simple blocks (a choice, stuck work); and an action per answer of the same key
  # (one given with a note opens its note form; one with `submit_to` sends it), its actions
  # opening pages and its links web addresses.
  alias AtlasTui.ConsoleProjectionFixture

  def model(kind, props \\ %{}), do: kind |> page(props) |> projected()

  @decision "/k/decision/D-7"
  @stuck "/k/widget/K-1"
  # A Rule longer than one line, which a card shows in full.
  @long_rule "Store the private example in files next to the work, one per environment, so every client reads the same examples as cards below the question without a server to run."
  def long_rule, do: @long_rule

  def call(kind, key, answer),
    do: %{
      "endpoint" => "answer",
      "params" => %{"kind" => kind, "key" => key, "answer" => answer}
    }

  # A decision's choice (`:choice`): its question, why, a card per alternative (the
  # recommended one first), then the answers: Decline all (the decline, given with a note,
  # its text the detail) and the page's other answers; its details. One proposal
  # (`:proposal`): its card `alone`, then Accept and Decline. Stuck work (`:stuck`): its
  # title as the question, its byline, what went wrong, Retry as the one proposal, Accept
  # and Decline (Close it) and the agent's log.
  def page(kind, props \\ %{})

  def page(:choice, _props) do
    adopt = fn n, id, text, extra ->
      option(
        n,
        text,
        [{"Rule", "Store examples in #{id}."}, {"Consequences", "#{text} holds them."}],
        Map.merge(
          %{
            "label" => "Choose",
            "key" => "#{n}",
            "to" => @decision <> "/answer/option-#{id}",
            "submit_to" => call("decision", "D-7", "option-#{id}")
          },
          extra
        )
      )
    end

    decline_all = %{
      "label" => "Decline all",
      "weight" => "decline",
      "key" => "3",
      "to" => @decision <> "/answer/decline",
      "note" => true,
      "detail" => "None of these fits; say why."
    }

    blocks =
      [
        header("YOUR DECISION", "D-7", "How do we store examples?"),
        text("why", %{"text" => "Files need nothing to run."}),
        adopt.(1, "files", "Use files", %{
          "badge" => "★ Recommended",
          "tone" => "success",
          "weight" => "main"
        }),
        adopt.(2, "memory", "Use memory", %{"weight" => "other"}),
        answers([
          decline_all,
          %{"label" => "Inspector's log", "key" => "l", "to" => "/k/run/W-7"}
        ]),
        %{
          "id" => "actions",
          "type" => "actions",
          "props" => %{
            "actions" => [
              %{"label" => "Update decision", "key" => "u", "to" => @decision <> "/edit"}
            ]
          }
        },
        %{
          "id" => "item",
          "type" => "item",
          "props" => %{
            "title" => "",
            "fields" => [%{"label" => "Status", "value" => "Open"}],
            "actions" => []
          }
        }
      ]

    %{
      "op" => "page",
      "path" => @decision,
      "title" => "D-7",
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

  def page(:proposal, _props) do
    page = page(:choice)
    [header, why, files, _memory, _answers | rest] = page["blocks"]
    # The only proposal, as Control sends it: no number, no badge, its Rule in full.
    files =
      files
      |> put_in(["props", "alone"], true)
      |> update_in(["props"], &Map.drop(&1, ["badge", "tone"]))
      |> put_in(["props", "fields", Access.at(0), "value"], @long_rule)

    accept = Map.put(files["props"]["answer"], "label", "Accept")

    decline = %{
      "label" => "Decline",
      "weight" => "decline",
      "key" => "2",
      "to" => @decision <> "/answer/decline",
      "note" => true,
      "detail" => "None of these fits; say why."
    }

    %{page | "blocks" => [header, why, files, answers([accept, decline]) | rest]}
  end

  def page(:stuck, _props) do
    blocks = [
      header("YOUR DECISION", "IS-Atlas-134", "IS-Atlas-134 is stuck: what now?"),
      text("why", %{"text" => "inspect · attempt 2 failed · stuck", "since" => ago(26)}),
      text("failure", %{
        "label" => "What went wrong",
        "text" => "The worker stopped: the tests could not reach the database.",
        "role" => "error"
      }),
      option(1, "Retry", [{"Consequences", "Runs the work again from where it stopped."}], %{
        "label" => "Choose",
        "weight" => "main",
        "key" => "t",
        "to" => @stuck <> "/answer/retry",
        "submit_to" => call("widget", "K-1", "retry"),
        "alone" => true
      }),
      answers([
        %{
          "label" => "Accept",
          "weight" => "main",
          "key" => "t",
          "to" => @stuck <> "/answer/retry",
          "submit_to" => call("widget", "K-1", "retry")
        },
        %{
          "label" => "Decline",
          "weight" => "decline",
          "key" => "c",
          "to" => @stuck <> "/answer/close",
          "note" => true,
          "detail" => "Close it"
        },
        %{"label" => "Agent's log", "key" => "l", "to" => "/k/run/W-134"}
      ])
    ]

    %{
      "op" => "page",
      "path" => @stuck,
      "title" => "Widget K-1",
      "reason" => "open",
      "blocks" => blocks
    }
  end

  def page(kind, props) do
    path = @stuck

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

  defp header(eyebrow, key, title),
    do: %{
      "id" => "header",
      "type" => "header",
      "props" => %{"eyebrow" => eyebrow, "key" => key, "title" => title}
    }

  defp text(id, props), do: %{"id" => id, "type" => "text", "props" => props}

  defp answers(answers),
    do: %{"id" => "answers", "type" => "answers", "props" => %{"answers" => answers}}

  # An option; `answer` carries its badge and tone too.
  defp option(n, text, fields, answer) do
    {look, answer} = Map.split(answer, ["badge", "tone", "alone"])

    %{
      "id" => "option-#{n}",
      "type" => "option",
      "props" =>
        Map.merge(look, %{
          "n" => n,
          "text" => text,
          "fields" => for({label, value} <- fields, do: %{"label" => label, "value" => value}),
          "answer" => answer
        })
    }
  end

  defp call(answer), do: call("widget", "K-1", answer)

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

  defp ago(hours),
    do: DateTime.utc_now() |> DateTime.add(-hours * 3_600 - 60) |> DateTime.to_iso8601()

  # Control's actions for what the viewer can answer: a panel's or an answers block's
  # answers, an option's own answer (the recommended one, tone success, on 0 too; the
  # only proposal's, `alone`, on 0 only: its key is the answers' Accept).
  def projected(page) do
    projected = ConsoleProjectionFixture.project(page)

    scope = %{
      "page" => page["path"],
      "revision" => projected["actions_revision"],
      "context" => "browse"
    }

    answers =
      Enum.flat_map(page["blocks"], fn
        %{"type" => "option", "props" => %{"answer" => a, "alone" => true}} ->
          [Map.put(a, "key", "0")]

        %{"type" => "option", "props" => %{"answer" => a, "tone" => "success"}} ->
          [a, Map.put(a, "key", "0")]

        %{"type" => "option", "props" => %{"answer" => a}} ->
          [a]

        %{"props" => props} ->
          props["answers"] || []
      end)

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
