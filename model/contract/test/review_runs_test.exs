defmodule Model.ReviewRunsTest do
  @moduledoc """
  Slice 7: the review and the test of a pull request run on Flow's durable runs. Their
  selection, the import table from the facts as they were, the trusted verdict, the three
  days, and the revision a result counts for, on the compiled subflows of both
  environments.
  """
  use ExUnit.Case, async: true

  alias AtlasFlow.Composition.Links
  alias AtlasFlow.Runs.Run

  @now ~U[2026-11-13 00:00:00Z]
  @envs [:prod, :test]

  # subflow, the role that gives its verdict, its two verdicts, the parent's field.
  @kinds [
    {"pr_review", "reviewer", "approved", "changes_requested", "review_outcome"},
    {"pr_test", "tester", "passed", "failed", "test_outcome"}
  ]

  # The digests the base recorded before slice 7 (the same in prod and test).
  @base %{
    "pr_review" => "ee1314e80a41b4d4102923cc46d08126403ea5fc3c58bcf49d88617823acd86b",
    "pr_test" => "43fcbbf9a95d4e5bbac5c72d2dc878c28e56b48f7dd865e43d57cdb5e6bd5644"
  }

  defp flow(env, name), do: Enum.find(Model.AtlasEyra.subflows(env), &(&1.name() == name))

  defp subject(values, version \\ "v1"),
    do: %{"key" => "PRR-1", "version" => version, "values" => values}

  defp new(env, name, values) do
    Run.new(
      name,
      flow(env, name),
      subject(values),
      Model.AtlasEyra.selection(name)["imports"],
      @now
    )
  end

  defp verdict(run, value, roles, position \\ 5),
    do: %{
      "key" => "I-#{run["entry"]}-#{Enum.join(roles)}",
      "run" => run["key"],
      "entry" => run["entry"],
      "status" => "applied",
      "roles" => roles,
      "changed_fields" => %{"verdict" => value},
      "position" => position,
      "subject_version" => "v1",
      "prepared_at" => "2026-11-13T00:01:00Z"
    }

  test "selected in both environments next to decide, runnable, with nothing refused" do
    for env <- @envs do
      runner = AtlasFlow.Model.load(Model.AtlasEyra, env, %{"decider" => "someone"})
      assert runner.refusal == nil

      assert Enum.sort(Map.keys(runner.config["selection"])) ==
               ~w(decide design_and_accept issue pr_review pr_test pull_request test_and_accept_scene test_and_accept_use_case)

      for {name, _, _, _, _} <- @kinds do
        f = flow(env, name)
        assert Run.validate(f) == :ok
        # No activity: nothing is dispatched, so an import reruns nothing.
        assert Enum.all?(f.states(), &(f.mechanism(&1) == nil))
        # No legacy flow drives these subjects: the run is their one writer.
        assert Enum.all?(Model.AtlasEyra.legacy(), &(name not in &1.kinds()))
      end
    end

    inputs = Model.AtlasEyra.runs()["inputs"]

    for role <- ~w(reviewer tester maintainer),
        do: assert(inputs["roles"][role] == "verdict_by")

    for {name, role, _, _, _} <- @kinds do
      selection = Model.AtlasEyra.selection(name)
      assert selection["subject"] == name
      assert selection["choices"] == ["verdict"]
      assert selection["choice_states"] == ["working", "escalated"]
      assert selection["admission"] == []
      assert name in inputs["acl"][role]["update"]
      assert name in inputs["acl"]["maintainer"]["update"]
      refute Map.has_key?(selection, "projection")
    end

    assert Model.AtlasEyra.relations()["verdict_by"]["only_target"]
  end

  test "every import row: superseded, each verdict, and every open one into its wait" do
    for env <- @envs, {name, _, yes, no, _} <- @kinds do
      assert Model.AtlasEyra.selection(name)["imports"] == [
               %{"when" => %{"superseded" => [true]}, "state" => "superseded"},
               %{"when" => %{"verdict" => [yes]}, "state" => yes},
               %{"when" => %{"verdict" => [no]}, "state" => no},
               %{"when" => [], "state" => "working"}
             ]

      for {values, state} <- [
            {%{"superseded" => true, "verdict" => yes}, "superseded"},
            {%{"superseded" => true}, "superseded"},
            {%{"verdict" => yes, "superseded" => false}, yes},
            {%{"verdict" => no}, no}
          ] do
        run = new(env, name, values)
        assert {run["state"], run["status"], run["entry"]} == {state, "completed", 1}
        assert run["pending"]["writes"] == [] and run["deadlines"]["timers"] == []
        assert run["last_input"]["import"] == true
        assert {:ok, ^run} = Run.step(run, flow(env, name), subject(%{"verdict" => no}), @now)
      end

      for values <- [%{}, %{"superseded" => false}, %{"verdict" => "unclear"}] do
        run = new(env, name, values)
        assert {run["state"], run["status"], run["entry"]} == {"working", "active", 1}
        assert run["pending"] == %{"version" => 1, "writes" => []}
        assert run["last_input"]["import"] == true

        assert [%{"name" => "stalled", "to" => "escalated", "due" => "2026-11-16T00:00:00.000Z"}] =
                 run["deadlines"]["timers"]
      end
    end
  end

  test "a verdict counts as the trusted choice of who gives it; a plain write moves nothing" do
    for env <- @envs, {name, role, yes, no, _} <- @kinds do
      f = flow(env, name)
      run = new(env, name, %{}) |> Map.put("key", "R-1")
      written = subject(%{"verdict" => yes})

      # The verdict on the fact alone, without its input, is no choice.
      assert {:ok, ^run} = Run.step(run, f, written, @now)

      assert {:ok, %{"state" => ^yes, "status" => "completed"}} =
               Run.step(run, f, written, @now, [verdict(run, yes, [role])])

      # Three days without one: escalated; the old entry's verdict is stale.
      due = DateTime.add(@now, 3, :day)
      assert {:ok, escalated} = Run.step(run, f, subject(%{}), due)
      assert {escalated["state"], escalated["entry"]} == {"escalated", 2}
      stale = [verdict(run, no, [role])]
      assert {:ok, ^escalated} = Run.step(escalated, f, subject(%{"verdict" => no}), due, stale)

      assert {:ok, %{"state" => ^no}} =
               Run.step(escalated, f, subject(%{"verdict" => no}), due, [
                 verdict(escalated, no, ["maintainer"], 9)
               ])
    end
  end

  test "superseded ends it as written; a late verdict then moves nothing" do
    for env <- @envs, {name, role, yes, _, _} <- @kinds do
      f = flow(env, name)
      run = new(env, name, %{}) |> Map.put("key", "R-1")
      assert {:ok, gone} = Run.step(run, f, subject(%{"superseded" => true}), @now)
      assert {gone["state"], gone["status"]} == {"superseded", "completed"}
      late = subject(%{"superseded" => true, "verdict" => yes})
      assert {:ok, ^gone} = Run.step(gone, f, late, @now, [verdict(gone, yes, [role])])
    end
  end

  test "only a result for the pull request's current revision counts; a replaced one never" do
    links = Model.AtlasEyra.composition()["links"]

    for {name, _, yes, _, field} <- @kinds do
      link = Enum.find(links, &(&1["child"] == name))
      assert link["current"] == %{"child" => "revision", "parent" => "revision"}
      assert {link["field"], link["stale"]} == {field, "drop"}
      assert Links.valid?(link) == :ok

      parent = %{"key" => "PR-1", "values" => %{"revision" => "r2"}}
      older = %{"key" => "C-1", "values" => %{"revision" => "r1"}}
      newer = %{"key" => "C-2", "values" => %{"revision" => "r2"}}

      run = fn key, state ->
        %{"key" => "run-" <> key, "flow" => name, "entry" => 2, "state" => state}
      end

      # The replaced child ended with a verdict; the current one still waits: nothing.
      runs = %{"C-1" => run.("C-1", yes), "C-2" => run.("C-2", "working")}
      assert Links.select(link, parent, [older, newer], runs, nil) == :waiting

      runs = %{runs | "C-2" => run.("C-2", yes)}

      assert {:write, ^yes, %{"child" => "C-2", "current" => "r2"}} =
               Links.select(link, parent, [older, newer], runs, nil)

      # A pull request that names no revision yet is not ready; two for one is ambiguous.
      assert Links.select(link, %{parent | "values" => %{}}, [newer], runs, nil) == :waiting
      twin = %{"key" => "C-3", "values" => %{"revision" => "r2"}}

      assert {:refused, :ambiguous, ["C-2", "C-3"]} =
               Links.select(link, parent, [older, newer, twin], runs, nil)
    end
  end

  test "the change from the base's digest is a declared state migration, never a re-key" do
    for env <- @envs, {name, _, _, _, _} <- @kinds do
      f = flow(env, name)
      [m] = Model.AtlasEyra.selection(name)["migrations"]
      assert {m["from"], m["to"]} == {@base[name], f.digest()}
      assert m["states"] == Map.new(f.states(), &{&1, &1})
      refute Map.has_key?(m, "rekey") or Map.has_key?(m, "preserve_entry")

      # A quiescent run of the old digest would enter its state again under the new one.
      old = new(env, name, %{}) |> Map.merge(%{"definition_sha256" => @base[name]})
      old = put_in(old, ["deadlines", "timers"], [])
      assert {:ok, moved} = Run.migrate(old, f, [m], @now)

      assert {moved["state"], moved["entry"], moved["definition_sha256"]} ==
               {"working", 2, f.digest()}
    end
  end
end
