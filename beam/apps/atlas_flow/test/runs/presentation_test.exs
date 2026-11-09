defmodule AtlasFlow.Runs.PresentationTest do
  @moduledoc """
  What a run presents (`AtlasFlow.Runs.Presentation`), on the depot's subflow `sort`
  (`AtlasFlow.Depot`): its active state, its final state, the follow-through of a
  completed run, and how an owner set by hand and a deferred handover read back.
  """
  use ExUnit.Case, async: true

  alias AtlasFlow.Runs.Presentation

  @box %{"key" => "B-1", "values" => %{"phase" => "first"}}
  @owner &__MODULE__.owner/1

  def owner(default), do: default && Map.put(default, "resolved", true)

  defp sort, do: AtlasFlow.TestModel.sort()

  defp run(status, state, timers \\ []),
    do: %{
      "status" => status,
      "state" => state,
      "deadlines" => %{"version" => 1, "timers" => timers}
    }

  test "an active run presents its state: what is expected, its owner and the deadline it shows" do
    timers = [%{"name" => "retry", "due" => "2026-11-04T10:05:00Z"}]

    assert %{"name" => "waiting", "expected" => "Sort it", "owner" => owner} =
             shown =
             Presentation.of_run(run("active", "waiting", timers), sort(), %{}, @box, @owner)

    assert owner["resolved"]
    assert Map.has_key?(shown, "preserve_kind")
    refute shown["done"]
  end

  test "a final run presents nothing to do" do
    assert Presentation.of_run(run("completed", "done"), sort(), %{}, @box, @owner) ==
             %{"name" => "done", "done" => true}
  end

  test "a completed run follows through while its subject holds the condition" do
    selection = %{"follow_through" => %{"state" => "done", "when" => %{"result" => ["ok"]}}}
    ok = put_in(@box, ["values", "result"], "ok")

    assert Presentation.of_run(run("completed", "done"), sort(), selection, ok, @owner) ==
             :follow_through

    assert %{"done" => true} =
             Presentation.of_run(run("completed", "done"), sort(), selection, @box, @owner)

    assert %{"done" => true} =
             Presentation.of_run(run("completed", "discarded"), sort(), selection, ok, @owner)
  end

  test "a blocked or idle run presents nothing" do
    for status <- ["blocked", "idle"],
        do: assert(Presentation.of_run(run(status, "waiting"), sort(), %{}, @box, @owner) == nil)
  end

  test "an owner set by a user or an agent is set by hand; by Flow, a migration or nobody not" do
    for {origin, manual} <- [
          {%{"by" => "bob"}, true},
          {%{"by" => "flow"}, false},
          {%{"by" => "migration"}, false},
          {%{}, false},
          {nil, false}
        ] do
      fact = %{"origins" => %{"owned_by" => origin}}
      assert Presentation.manual?(fact, "owned_by") == manual
    end

    refute Presentation.manual?(%{"origins" => %{"owned_by" => %{"by" => "bob"}}}, nil)
  end

  test "a deferred handover holds while its owners and their link are those it waited on" do
    held = %{"values" => %{"later" => JSON.encode!(%{"from" => ["bob"], "position" => 4})}}
    handover = Presentation.handover(held, "later")
    assert handover == %{"from" => ["bob"], "position" => 4}
    assert Presentation.deferred?(handover, ["bob"], 4)

    # A later manual assignment (another owner, or another link) cancels it.
    refute Presentation.deferred?(handover, ["ada"], 4)
    refute Presentation.deferred?(handover, ["bob"], 5)

    assert Presentation.handover(%{"values" => %{}}, "later") == %{}
    assert Presentation.handover(held, nil) == %{}
    refute Presentation.deferred?(%{}, [], nil)
  end
end
