defmodule Model.PipelineRunsTest do
  @moduledoc """
  A person supervises a flow, never a step (D-0099): every pickup point is a subflow of
  its own, whose span is the whole flow. A scene and a use case each go from their
  break-down flow to their acceptance flow by `phase`, which gives each one writer at any
  moment; with nothing under it, the acceptance hands it back to a new round of its
  break-down and waits for it. A scene or use case from before the split has no `phase`:
  the acceptance imports it.
  """
  use ExUnit.Case, async: true

  alias AtlasFlow.Runs.{Run, Store}

  @now ~U[2026-11-23 00:00:00Z]
  @envs [:prod, :test]

  defp flow(env, name), do: Enum.find(Model.AtlasEyra.subflows(env), &(&1.name() == name))

  defp config(env),
    do: AtlasFlow.Model.load(Model.AtlasEyra, env, %{"decider" => "someone"}).config

  defp fact(key, values, extra \\ %{}),
    do: Map.merge(%{"key" => key, "version" => "v1", "position" => 11, "values" => values}, extra)

  defp new(env, name, key, values, extra \\ %{}),
    do:
      Run.new(
        name,
        flow(env, name),
        fact(key, values, extra),
        Model.AtlasEyra.selection(name)["imports"],
        @now
      )

  defp step(env, name, run, key, values),
    do:
      Run.step(run, flow(env, name), fact(key, values), @now, [],
        reopen: Model.AtlasEyra.selection(name)["reopen"]
      )

  defp sent(run), do: put_in(run, ["pending", "writes"], [])
  defp at(run), do: {run["state"], run["status"]}
  defp written(run), do: for(w <- run["pending"]["writes"], do: w["content"]["values"])

  # The count of what is under it, as the composition gives it to a run on it.
  defp counted(env, name, run, key, values, children, open) do
    counts = %{"children" => children, "open_children" => open}
    offered = put_in(run, ["pending", "synthetic"], %{"id" => "S", "values" => counts})

    {:ok, moved} =
      Run.synthetic(offered, flow(env, name), fact(key, Map.merge(values, counts)), @now)

    moved
  end

  # Its break-down from its start: its agent proposed, its supervisor accepted.
  defp broken_down(env, name, key, values) do
    run = new(env, name, key, values)
    assert at(run) == {"break_down", "active"}
    proposed = %{"key" => "TK-#{key}-1", "outcome" => "completed"}

    {:ok, accepting} =
      Run.task_result(run, flow(env, name), fact(key, values), @now, "completed", proposed, [])

    assert at(accepting) == {"accepting", "active"}
    {:ok, done} = step(env, name, sent(accepting), key, Map.put(values, "verdict", "accept"))
    assert at(done) == {"broken_down", "completed"}
    assert written(done) == [%{"phase" => "accept"}]
    sent(done)
  end

  defp writer(env, kind, values) do
    {name, _} = Store.selected(config(env), kind, %{"values" => values})
    name
  end

  test "every pickup point is a subflow of its own, its span the whole flow (D-0099)" do
    spans = Model.AtlasEyra.supervision()["spans"]

    assert Enum.sort(Map.keys(spans)) ==
             ~w(break_down_scene break_down_use_case design_and_accept issue)

    for env <- @envs, {name, [span]} <- spans do
      f = flow(env, name)
      assert Enum.sort(span["states"]) == Enum.sort(Enum.reject(f.states(), &f.final?/1))
    end
  end

  test "the scene pipeline is horseshoe-shaped: it starts and ends on the scene" do
    assert [%{name: :scene, flows: flows}] = Model.AtlasEyra.__composition__().pipelines

    assert flows ==
             ~w(break_down_scene design_and_accept break_down_use_case issue accept_use_case accept_scene)a

    # An issue counts as done only when its run ended done, never stuck.
    count = Enum.find(Model.AtlasEyra.composition()["counts"], &(&1["child"] == "issue"))
    assert count["done"] == ["done"]
  end

  test "a scene: its break-down, then its producer's acceptance; not accepted, a new round" do
    for env <- @envs do
      assert writer(env, "scene", %{"phase" => "break_down"}) == "break_down_scene"
      assert writer(env, "scene", %{"phase" => "accept"}) == "accept_scene"
      assert writer(env, "scene", %{}) == "accept_scene"

      # A new scene is broken down; its accepted break-down hands it to its acceptance.
      round = broken_down(env, "break_down_scene", "SC-1", %{"phase" => "break_down"})
      accept = %{"phase" => "accept"}
      accepting = new(env, "accept_scene", "SC-1", accept)
      assert at(accepting) == {"building", "active"}
      refute Map.has_key?(accepting["last_input"], "import")

      # Nothing under it: back to a new round of its break-down, which this run waits for.
      waiting = counted(env, "accept_scene", accepting, "SC-1", accept, 0, 0)
      assert at(waiting) == {"breaking_down", "active"}
      assert written(waiting) == [%{"phase" => "break_down"}]
      {:ok, round} = step(env, "break_down_scene", round, "SC-1", accept)
      {:ok, again} = step(env, "break_down_scene", round, "SC-1", %{"phase" => "break_down"})
      assert {again["generation"], at(again)} == {2, {"break_down", "active"}}

      # Broken down again: built; all its use cases accepted: to its producer.
      {:ok, building} = step(env, "accept_scene", sent(waiting), "SC-1", accept)
      assert at(building) == {"building", "active"}
      to_accept = sent(counted(env, "accept_scene", sent(building), "SC-1", accept, 2, 0))
      assert at(to_accept) == {"to_accept", "active"}

      # Not accepted: the producer's note stays on the scene, and a new round of its
      # break-down starts, which this run waits for.
      rejected = Map.merge(accept, %{"verdict" => "reject", "note" => "Add an export"})
      {:ok, rejected_run} = step(env, "accept_scene", to_accept, "SC-1", rejected)
      assert at(rejected_run) == {"breaking_down", "active"}
      assert written(rejected_run) == [%{"phase" => "break_down"}]
      # Its next break-down's agent reads the producer's note.
      {:task, spec} = flow(env, "break_down_scene").mechanism("break_down")
      assert "note" in spec["fields"]

      # Accept ends the pipeline.
      {:ok, done} =
        step(env, "accept_scene", to_accept, "SC-1", Map.put(accept, "verdict", "accept"))

      assert at(done) == {"accepted", "completed"}

      # From before the split: building, or accepted history.
      assert at(new(env, "accept_scene", "SC-2", %{})) == {"building", "active"}
      done = new(env, "accept_scene", "SC-3", %{}, %{"completion" => %{"by" => "accepted_by"}})
      assert at(done) == {"accepted", "completed"}
    end
  end

  test "a use case: its design, its break-down, then its acceptance" do
    for env <- @envs do
      designed = %{"design_status" => "accepted", "phase" => "break_down"}
      assert writer(env, "use_case", %{"design_status" => "writing"}) == "design_and_accept"
      assert writer(env, "use_case", designed) == "break_down_use_case"
      accept = %{designed | "phase" => "accept"}
      assert writer(env, "use_case", accept) == "accept_use_case"
      assert writer(env, "use_case", %{"design_status" => "approved"}) == "accept_use_case"
      assert writer(env, "use_case", %{}) == "accept_use_case"

      broken_down(env, "break_down_use_case", "UC-1", designed)
      building = new(env, "accept_use_case", "UC-1", accept)
      assert at(building) == {"building", "active"}

      # All its issues done: accepted by itself, which completes it.
      done = counted(env, "accept_use_case", building, "UC-1", accept, 2, 0)
      assert at(done) == {"accepted", "completed"}
      assert written(done) == [%{"phase" => "accepted"}]

      # Approved before the split, nothing under it: imported, then broken down anew.
      old = %{"design_status" => "approved"}
      imported = new(env, "accept_use_case", "UC-2", old)
      assert imported["last_input"]["import"]
      waiting = counted(env, "accept_use_case", imported, "UC-2", old, 0, 0)
      assert at(waiting) == {"breaking_down", "active"}
      assert written(waiting) == [%{"phase" => "break_down"}]
    end
  end
end
