defmodule Model.FlowWritersTest do
  @moduledoc """
  M3 P5 (decision 2026-11-17 §6.4; Flow plan decision 11): Flow's work source leaser
  (`flow/dispatch`) and its report receiver (`flow/delivery`) are Flow, the same writer
  (`by: "flow"`), from their own Bus endpoints. Facts stores what they write on Flow's own
  `task` fields (both) and `task_attempt` fields (the receiver only), and nothing else:
  never a run, never another kind, never with another `by`. Flow's Landing
  (`flow/landing`, F3-L) was retired with the package kind (IS-Atlas-100): its endpoint
  writes nothing any more. Asserted on
  `:ok` or `{:refuse, _}` through the composed model, as Facts holds a write to it.
  """
  use ExUnit.Case, async: true

  alias Model.AtlasEyra

  @dispatch "flow/dispatch"
  @delivery "flow/delivery"
  @landing "flow/landing"

  defp description, do: AtlasEyra.__rela__(:description)

  defp lookup do
    %{
      "current" => fn -> nil end,
      "fact" => fn _, _ -> nil end,
      "list" => fn _ -> {:ok, []} end,
      "incoming" => fn _, _, _ -> [] end,
      "fingerprint" => &AtlasBus.SubjectFingerprint.of/2
    }
  end

  defp as(sender, by \\ "flow"), do: %{"by" => by, "writer" => by, "sender" => sender}

  defp create(kind, key, values, links \\ %{}),
    do: {kind, %{"op" => "create", "key" => key, "values" => values, "links" => links}}

  defp check({kind, change}, env), do: AtlasEyra.check(kind, change, env, lookup())

  defp refused?(result), do: match?({:refuse, [_ | _]}, result)

  # A lease write on a task, as the leaser grants it.
  defp task,
    do: create("task", "TK-IS-1-1", %{"lease_id" => "TK-IS-1-1~1~x", "lease_state" => "offered"})

  test "the run mapping names the endpoints, per kind, beside the single writer" do
    assert description().flow_runtime
           |> RelaDSL.Description.Plain.unorder()
           |> get_in(["flow_runtime", "writer"]) == %{
             "sender" => "flow",
             "by" => "flow",
             "senders" => %{
               "task" => [@dispatch, @delivery],
               "task_attempt" => [@delivery]
             }
           }
  end

  test "1. a task's lease fields, by Flow, from the leaser, the receiver or the Engine" do
    for sender <- [@dispatch, @delivery, "flow"],
        do: assert(check(task(), as(sender)) == :ok, sender)
  end

  test "1b. Landing's endpoint is no writer any more: results travel over Git (IS-Atlas-100)" do
    assert refused?(check(task(), as(@landing)))
  end

  test "2. the same write from another endpoint, or with another by, is refused" do
    assert refused?(check(task(), as("tui")))
    assert refused?(check(task(), as("control/session-1")))
    assert refused?(check(task(), as(@dispatch, "someone")))
    assert refused?(check(task(), as(@delivery, "someone")))
  end

  test "3. an attempt record with its links: from the receiver, never from the leaser" do
    attempt =
      create(
        "task_attempt",
        "TA-TK-IS-1-1-1",
        %{"lease_id" => "TK-IS-1-1~1~x", "state" => "running", "turn_id" => "t-1"},
        %{"attempt_of" => ["TK-IS-1-1"], "ran_on" => ["mac-mini"]}
      )

    assert check(attempt, as(@delivery)) == :ok
    assert check(attempt, as("flow")) == :ok
    assert refused?(check(attempt, as(@dispatch)))
    assert refused?(check(attempt, as(@landing)))
    assert refused?(check(attempt, as(@delivery, "someone")))
  end

  test "4. a run is the Engine's alone: refused from the leaser, the receiver and Landing" do
    kind = description().flow_runtime |> RelaDSL.Description.Plain.unorder()
    kind = kind["flow_runtime"]["kind"]
    run = create(kind, "RUN-1", %{"state" => "a", "generation" => 1})

    assert check(run, as("flow")) == :ok
    assert refused?(check(run, as(@dispatch)))
    assert refused?(check(run, as(@delivery)))
    assert refused?(check(run, as(@landing)))
  end

  test "5. every other kind with Flow's fields stays the Engine's alone" do
    extension = description().extension

    others =
      for {kind, spec} <- extension["entities"] || %{},
          kind not in ["task", "task_attempt"],
          {field, p} <- spec["properties"] || %{},
          p["set_by"] == ["flow"],
          do: {kind, field}

    # The model has such kinds besides these two; else this case proves nothing.
    assert others != []

    for {kind, field} <- others, sender <- [@dispatch, @delivery, @landing] do
      assert refused?(check(create(kind, "X-1", %{field => "x"}), as(sender))),
             "#{kind}.#{field} from #{sender}"
    end
  end

  test "6. the issue's CI gate fences the CI status itself: Flow may set the connector's pr_checks" do
    entry = %{"pr_checks" => "pending", "ci_fixes" => "one"}
    change = {"issue", %{"op" => "change", "key" => "IS-1", "values" => entry, "links" => %{}}}
    assert check(change, as("flow")) == :ok
  end
end
