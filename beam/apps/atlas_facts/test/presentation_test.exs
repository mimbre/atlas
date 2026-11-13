defmodule AtlasFacts.PresentationTest do
  @moduledoc """
  The presentation of work on a fact, derived from its runs (`AtlasFacts.Presentation`),
  with neutral nouns: work on a parcel is written on its label (`on`), owned through
  `held_by`; two phases run on it, `sorting` and `shipping`.
  """
  use ExUnit.Case, async: true

  alias AtlasFacts.Presentation

  @presenter %{
    "subject" => "parcel",
    "kind" => "label",
    "on" => "label",
    "field" => "todo",
    "state_field" => "step",
    "handover_field" => "later",
    "deadline_field" => "due",
    "owner_relation" => "held_by",
    "legacy" => nil,
    "flows" => [
      %{
        "name" => "sorting",
        "follow_through" => nil,
        "reopen" => "explicit",
        "admission" => %{"phase" => ["first"]}
      },
      %{
        "name" => "shipping",
        "follow_through" => %{"state" => "shipped", "when" => %{"status" => ["sent"]}},
        "reopen" => "explicit",
        "admission" => %{"phase" => ["second", nil]}
      }
    ],
    "states" => %{
      "weigh" => %{
        "expected" => "Weigh it",
        "why" => "it is new",
        "todo" => %{"instructions" => "Use the scale."}
      },
      "track" => %{
        "expected" => "Track it",
        "why" => "it is sent",
        "todo" => %{"instructions" => "Follow it."}
      }
    }
  }

  @subject %{"key" => "P-1", "values" => %{"phase" => "first"}}

  defp label(values, links \\ %{"held_by" => ["ada"]}, origins \\ %{}),
    do: %{"key" => "L-P-1", "values" => values, "links" => links, "origins" => origins}

  defp run(flow, generation, status, state),
    do: %{
      "key" => "#{flow}-#{generation}",
      "flow" => flow,
      "generation" => generation,
      "status" => status,
      "state" => state
    }

  defp view(target, runs, subject \\ @subject, completed? \\ false),
    do: Presentation.view(@presenter, target, subject, runs, fn -> completed? end)

  test "an active run presents its state, what is expected and the state's todo" do
    shown =
      view(label(%{"step" => "weigh", "todo" => "Weigh it", "due" => "2026-11-04T10:00:00Z"}), [
        run("sorting", 1, "active", "weigh")
      ])

    assert %{
             "flow" => "sorting",
             "run" => "sorting-1",
             "generation" => 1,
             "status" => "active",
             "state" => "weigh",
             "actionable" => true,
             "expected" => "Weigh it",
             "why" => "it is new",
             "todo" => %{"instructions" => "Use the scale."},
             "owner" => ["ada"],
             "deadline" => "2026-11-04T10:00:00Z",
             "handover" => nil,
             "follow_through" => false,
             "reopened" => false
           } = shown

    assert shown["subject"] == %{"kind" => "parcel", "key" => "P-1"}
  end

  test "the latest generation presents" do
    runs = [run("sorting", 1, "completed", "done"), run("sorting", 2, "active", "weigh")]

    assert %{"run" => "sorting-2", "actionable" => true} =
             view(label(%{"step" => "weigh", "todo" => "Weigh it"}), runs)
  end

  test "a run whose projection Flow has not written yet offers nothing to do" do
    shown =
      view(label(%{"step" => "other", "todo" => "Something else"}), [
        run("sorting", 1, "active", "weigh")
      ])

    assert %{"state" => "weigh", "actionable" => false, "expected" => nil, "todo" => nil} = shown
  end

  test "a final run offers nothing, whatever is still written: no stale actionable item" do
    stale = label(%{"step" => "weigh", "todo" => "Weigh it"})
    shown = view(stale, [run("sorting", 1, "completed", "done")])

    assert %{"status" => "completed", "state" => nil, "actionable" => false, "expected" => nil} =
             shown

    assert shown["todo"] == nil
  end

  test "a completed run that follows through presents what Flow still writes" do
    subject = %{"key" => "P-1", "values" => %{"phase" => "second", "status" => "sent"}}
    target = label(%{"step" => "track", "todo" => "Track it"})

    assert %{
             "follow_through" => true,
             "state" => "track",
             "actionable" => true,
             "expected" => "Track it",
             "status" => "completed"
           } =
             view(target, [run("shipping", 1, "completed", "shipped")], subject)

    # Once Flow cleared it (the follow-through ended), nothing is presented.
    assert %{"follow_through" => false, "actionable" => false} =
             view(label(%{}), [run("shipping", 1, "completed", "shipped")], subject)

    # Nor once the subject no longer holds its condition.
    assert %{"follow_through" => false, "actionable" => false} =
             view(
               target,
               [run("shipping", 1, "completed", "shipped")],
               %{subject | "values" => %{"phase" => "second"}},
               true
             )
  end

  test "an owner set by hand is manual; one Flow, a migration or nobody set is not" do
    for {by, manual} <- [
          {"bob", true},
          {"agent-1", true},
          {"flow", false},
          {"migration", false},
          {nil, false}
        ] do
      target = label(%{"step" => "weigh"}, %{"held_by" => ["bob"]}, %{"held_by" => %{"by" => by}})

      assert %{"owner" => ["bob"], "manual" => ^manual} =
               view(target, [run("sorting", 1, "active", "weigh")])
    end
  end

  test "a deferred handover is presented with what Flow holds; an unreadable one still bars" do
    held = JSON.encode!(%{"from" => ["ada"], "position" => 7})
    target = label(%{"step" => "weigh", "later" => held})

    assert %{"handover" => %{"from" => ["ada"], "position" => 7}, "actionable" => true} =
             view(target, [run("sorting", 1, "active", "weigh")])

    assert %{"handover" => %{}} =
             view(label(%{"step" => "weigh", "later" => "?"}), [
               run("sorting", 1, "active", "weigh")
             ])
  end

  test "reopened work: its run ended, a phase admits it, and it is not completed" do
    target = label(%{})
    ended = [run("sorting", 1, "completed", "done")]

    assert %{
             "reopened" => true,
             "actionable" => false,
             "flow" => "sorting",
             "status" => "completed"
           } =
             view(target, ended)

    # Completed, it is simply done; a phase that no longer admits it is not its own.
    assert %{"reopened" => false} = view(target, ended, @subject, true)

    assert %{"reopened" => false, "flow" => nil} =
             view(target, ended, %{@subject | "values" => %{"phase" => "second"}})

    # A selection that starts a new generation by itself is not left reopened.
    presenter =
      update_in(@presenter, ["flows"], fn [f | rest] ->
        [%{f | "reopen" => "new_generation"} | rest]
      end)

    assert %{"reopened" => false} =
             Presentation.view(presenter, target, @subject, ended, fn -> false end)
  end

  test "a blocked run presents as it stood" do
    assert %{"status" => "blocked", "state" => "weigh", "actionable" => true} =
             view(label(%{"step" => "weigh", "todo" => "Weigh it"}), [
               run("sorting", 1, "blocked", "weigh")
             ])
  end

  test "no run: nothing to do" do
    assert %{"run" => nil, "actionable" => false, "reopened" => false} =
             view(label(%{"step" => "weigh"}), [])
  end

  test "a legacy flow's work is open while its state is written, or always without a state field" do
    legacy = %{@presenter | "legacy" => "old", "flows" => []}

    assert %{
             "legacy" => "old",
             "state" => "weigh",
             "actionable" => true,
             "expected" => "Weigh it"
           } =
             Presentation.view(
               legacy,
               label(%{"step" => "weigh", "todo" => "Weigh it"}),
               @subject,
               [],
               fn -> false end
             )

    assert %{"actionable" => false} =
             Presentation.view(legacy, label(%{}), @subject, [], fn -> false end)

    stateless = %{legacy | "state_field" => nil}

    assert %{"actionable" => true} =
             Presentation.view(stateless, label(%{}), @subject, [], fn -> false end)
  end
end
