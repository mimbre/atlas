defmodule AtlasFlow.Activities.LadderEscalationTest do
  @moduledoc """
  F2-E (F2/F3 plan rev 3 §3.3 rows 1–2, Main's B-3 and B-4): rung (e) on the Engine.
  The ladder escalates, and Flow writes no `decision` fact: the run is in the non-final
  `awaiting_decision`, whose owner (the configured decider, without `preserve_kind`)
  goes to the run's supervisor after a projection pass. The supervisor answers on the
  bin and hands it back to its robot: the bin goes on with a fresh author on the original
  base, with no decision and no other run (no `follow_through`). Without the hand-back
  no task runs (E1). The lease bench of `AtlasFlow.Sorts.Loop`; asserted on states, run
  fields, links and the facts Facts holds, never on wording.
  """
  use ExUnit.Case, async: false
  @moduletag :capture_log

  import AtlasFlow.Sorts.Loop.Bench

  alias AtlasFlow.FakeFacts
  alias AtlasFlow.Runs.{Projection, Store}

  @mini {"mini", "ada"}
  @author [{"load.txt", "one\n"}]
  @fixed [{"load.txt", "one\n"}, {"fix.txt", "two\n"}]

  # The environment needs access, and the supervisor must choose (#297 §4.1, rung e).
  @needs_access %{
    "cause" => "environment",
    "evidence" => "the robot cannot reach the shelf",
    "advice" => "grant it the shelf",
    "needs" => "access",
    "decision" => %{
      "question" => "Grant the robot the shelf?",
      "rationale" => "it cannot load without it",
      "options" => [
        %{
          "id" => "grant",
          "text" => "grant it",
          "details" => "the shelf",
          "rule" => "only this shelf",
          "consequences" => "it can load"
        }
      ],
      "safe_to_continue" => false,
      "touches" => ["credentials"]
    }
  }

  setup do
    setup!() |> source!()
  end

  # Author, two fixes, all failing their check, then a diagnosis that needs access: rung
  # (e). The run's first author's base, and the escalated run.
  defp escalated(c) do
    original = started(c)["pending"]["task"]["work"]["input"]["base"]
    assert {:ok, _} = Projection.project(c.runner, "bin", "B-1")
    finish(@mini, files: @author, check: 1)

    for _ <- 1..2 do
      assert settle(c)["state"] == "fixing"
      assert owner("B-1") == ["mini"]
      finish(@mini, files: @fixed, check: 1)
    end

    assert settle(c)["state"] == "diagnosing"
    finish(@mini, answer: diagnosis(@needs_access))
    {original, settle(c)}
  end

  # The supervisor answers on the bin: a field they set by hand.
  defp answer(key, answer) do
    fact = FakeFacts.get("bin", key)

    FakeFacts.put(
      "bin",
      Map.merge(fact, %{
        "values" => Map.put(fact["values"], "answer", answer),
        "version" => fact["version"] + 1
      })
    )
  end

  defp flows(c) do
    {:ok, %{runs: runs}} = Store.plan(c.runner.config, c.runner.flows)
    runs |> Enum.map(& &1["flow"]) |> Enum.uniq()
  end

  test "rung (e) writes no decision: the run awaits the supervisor's answer, who owns the bin after a projection pass",
       c do
    {_original, run} = escalated(c)

    assert {run["state"], run["status"]} == {"awaiting_decision", "active"}
    assert run["pending"]["task"] == nil
    assert run["last_input"]["outcome"] == "escalate"

    assert %{"on" => "escalation", "question" => q} = run["pending"]["ladder"]["awaiting"]
    assert q["rung"] == "e" and q["answers"] == ["grant", "fresh", "abandon"]
    assert decisions() == []

    # The robot someone linked stayed while the loop ran; entering awaiting_decision moved
    # the bin to the supervisor (the settle's projection pass).
    assert owner("B-1") == ["ada"]
    assert {:ok, _} = Projection.project(c.runner, "bin", "B-1")
    assert owner("B-1") == ["ada"]
    assert decisions() == [] and flows(c) == ["work"]
  end

  test "the supervisor answers and hands the bin back: a fresh author on the original base, no decision, no other run",
       c do
    {original, _} = escalated(c)
    assert {:ok, _} = Projection.project(c.runner, "bin", "B-1")
    tasks = length(run(c)["pending"]["tasks"])

    bin("B-1", "mini", "ada")
    answer("B-1", "fresh")
    run = settle(c)

    assert run["state"] == "fresh"
    next_key = "TK-B-1-#{tasks + 1}"
    assert %{"key" => ^next_key} = intent = run["pending"]["task"]
    assert intent["work"]["input"]["base"] == original
    refute Map.has_key?(intent["work"]["input"], "change_set")
    assert intent["work"]["input"]["permissions"] == "workspace-write"
    assert run["pending"]["ladder"]["awaiting"] == nil
    assert run["pending"]["ladder"]["rung"] == "e"
    assert decisions() == [] and flows(c) == ["work"]

    # The robot, handed back, stays the owner in the task state.
    assert {:ok, _} = Projection.project(c.runner, "bin", "B-1")
    assert owner("B-1") == ["mini"]
  end

  test "the supervisor's answer alone runs the fresh author", c do
    escalated(c)
    tasks = length(run(c)["pending"]["tasks"])

    answer("B-1", "fresh")
    run = settle(c)
    key = "TK-B-1-#{tasks + 1}"
    assert {run["state"], run["pending"]["task"]["key"]} == {"fresh", key}
    assert task_values(key)["kind"] == "author"
  end

  test "the answer stronger, deep_coding_max offered: a stronger author on the original base",
       c do
    Application.put_env(:atlas_flow, :ladder_profiles, ["deep_coding_max"])
    on_exit(fn -> Application.delete_env(:atlas_flow, :ladder_profiles) end)

    {original, run} = escalated(c)
    assert %{"question" => q} = run["pending"]["ladder"]["awaiting"]
    assert "stronger" in q["answers"]
    assert {:ok, _} = Projection.project(c.runner, "bin", "B-1")

    bin("B-1", "mini", "ada")
    answer("B-1", "stronger")
    run = settle(c)

    assert run["state"] == "stronger"
    intent = run["pending"]["task"]
    # The ladder took the answer's step (the state's spec alone would give the profile).
    assert intent["loop"]["step"] == "stronger"
    assert intent["work"]["after_check"] == %{"command" => ["loop/bin/check"]}

    assert {intent["work"]["profile"], intent["work"]["cost_class"]} ==
             {"deep_coding_max", "high"}

    assert intent["work"]["input"]["base"] == original
    refute Map.has_key?(intent["work"]["input"], "change_set")
    assert task_values(intent["key"])["kind"] == "author"
    assert run["pending"]["ladder"]["awaiting"] == nil
    assert decisions() == [] and flows(c) == ["work"]
  end

  test "abandon: the bin is stuck; nothing runs, nothing is decided", c do
    escalated(c)
    answer("B-1", "abandon")
    run = settle(c)
    assert {run["state"], run["status"]} == {"stuck", "completed"}
    assert decisions() == []
  end
end
