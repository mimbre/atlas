defmodule Model.ReviewRunsTest do
  @moduledoc """
  Slice 7: the review and the test of a pull request run on Flow's durable runs. Their
  selection, the import table from the facts as they were, the trusted verdict, the three
  days, and the revision a result counts for, on the compiled subflows of both
  environments; and the review pass of a reviewer with a Runtime.
  """
  use ExUnit.Case, async: true

  alias AtlasFlow.Activities.Pass
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

  # The review's digest as slice 7 selected it, without its pass.
  @selected "7291ab5579991c4083ad2d1f18c211a7cc7c85ec27735c8d00d0d99e8752542e"

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
               ~w(decide design_and_accept follow_through issue pr_review pr_test pull_request test_and_accept_scene test_and_accept_use_case to_do)

      for {name, _, _, _, _} <- @kinds do
        f = flow(env, name)
        assert Run.validate(f) == :ok
      end

      # The test has no activity. The review has one, its reviewer's pass in `working`,
      # which its people work in too: an import into it reruns nothing.
      t = flow(env, "pr_test")
      assert Enum.all?(t.states(), &(t.mechanism(&1) == nil))
      r = flow(env, "pr_review")
      assert [{"working", {:pass, spec}}] = for(s <- r.states(), m = r.mechanism(s), do: {s, m})
      assert Pass.with_person?(spec) and Run.importable?(r, "working")
      assert spec["request"]["permissions"] == "review-packet"
      assert spec["routing"]["machine_field"] == "machine"
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
      # The review's leads on to the pass's (below).
      m = hd(Model.AtlasEyra.selection(name)["migrations"])
      to = if name == "pr_review", do: @selected, else: f.digest()
      assert {m["from"], m["to"]} == {@base[name], to}
      assert m["states"] == Map.new(f.states(), &{&1, &1})
      refute Map.has_key?(m, "rekey") or Map.has_key?(m, "preserve_entry")

      # A quiescent run of the old digest would enter its state again under the new one.
      if name == "pr_test" do
        old = new(env, name, %{}) |> Map.merge(%{"definition_sha256" => @base[name]})
        old = put_in(old, ["deadlines", "timers"], [])
        assert {:ok, moved} = Run.migrate(old, f, [m], @now)

        assert {moved["state"], moved["entry"], moved["definition_sha256"]} ==
                 {"working", 2, f.digest()}
      end
    end
  end

  # -- The review pass ---------------------------------------------------------------------

  defp review(values \\ %{}),
    do:
      subject(
        Map.merge(
          %{
            "revision" => "r1",
            "packet_tree" => "/packets/p1/tree",
            "packet_id" => "p1",
            "packet_fingerprint" => "fpr_1"
          },
          values
        )
      )

  defp spec(env) do
    {:pass, spec} = flow(env, "pr_review").mechanism("working")
    spec
  end

  @agent %{"key" => "reviewer-agent", "values" => %{"machine" => "desk"}}

  defp frozen(env, run, subject \\ review(), owner \\ @agent) do
    {:ok, intent} = Pass.freeze(run, spec(env), subject, Map.take(subject, ~w(key values)), owner)
    put_in(run, ["pending", "pass"], intent)
  end

  defp completed(run, outcome) do
    r = run["pending"]["pass"]["request"]

    %{
      "version" => 1,
      "id" => r["id"],
      "digest" => run["pending"]["pass"]["digest"],
      "fingerprint" => r["fingerprint"],
      "packet" => r["request"]["packet"],
      "execution" => "turn-1",
      "status" => "completed",
      "outcome" => outcome
    }
  end

  test "the pass of a reviewer with a machine is frozen on the packet the review names" do
    for env <- @envs do
      run = new(env, "pr_review", %{}) |> Map.put("key", "R-1")
      r = frozen(env, run)["pending"]["pass"]["request"]
      assert {r["owner"], r["machine"]} == {"reviewer-agent", "desk"}
      assert r["request"]["cwd"] == "/packets/p1/tree"
      # The packet must be the one frozen for the revision the review is of.
      assert r["request"]["packet"] == %{
               "packet_id" => "p1",
               "fingerprint" => "fpr_1",
               "revision" => "r1"
             }

      assert r["request"]["permissions"] == "review-packet"

      # The contract selects Claude here; Runtime must preserve that frozen selection.
      assert {r["request"]["backend"], r["request"]["vendors"]} == {"claude", ["claude"]}

      # A person (no machine), or a review naming no packet yet: no pass; by hand.
      person = %{"key" => "melle", "values" => %{"name" => "Melle"}}
      no_packet = review(%{"packet_id" => nil})
      no_revision = review(%{"revision" => nil})

      for {subject, owner} <- [{review(), person}, {no_packet, @agent}, {no_revision, @agent}],
          do:
            assert(
              {:error, :invalid_pass_binding} =
                Pass.freeze(run, spec(env), subject, subject, owner)
            )

      # A changed revision or packet is another binding: the frozen pass is not current.
      intent = frozen(env, run)["pending"]["pass"]

      for change <- [%{"revision" => "r2"}, %{"packet_fingerprint" => "fpr_2"}] do
        changed = review(change)
        refute Pass.current?(intent, changed, Map.take(changed, ~w(key values)), @agent)
      end
    end
  end

  test "its findings' verdict is the reviewer's verdict; uncertain leaves it to them" do
    for env <- @envs do
      f = flow(env, "pr_review")
      run = frozen(env, new(env, "pr_review", %{}) |> Map.put("key", "R-1"))

      for {outcome, verdict} <- [{"pass", "approved"}, {"changes_required", "changes_requested"}] do
        assert {:ok, done} =
                 Run.pass_answer(run, f, review(), @now, completed(run, outcome), spec(env))

        assert {done["state"], done["status"], done["entry"]} == {verdict, "completed", 2}
        [write] = done["pending"]["writes"]
        assert write["kind"] == "pr_review" and write["content"]["key"] == "PRR-1"
        assert write["content"]["values"] == %{"verdict" => verdict}
        assert write["content"]["links"] == %{"verdict_by" => ["reviewer-agent"]}
        assert [%{"result" => %{"execution" => "turn-1"}}] = done["pending"]["passes"]
      end

      # Uncertain, or findings Runtime refused: no answer; the pass is done, the review waits.
      for outcome <- ~w(uncertain failed) do
        assert {:ok, waits} =
                 Run.pass_answer(run, f, review(), @now, completed(run, outcome), spec(env))

        assert {waits["state"], waits["entry"], waits["pending"]["writes"]} == {"working", 1, []}
        assert waits["pending"]["pass"]["result"]["outcome"] == outcome
        assert waits["deadlines"] == run["deadlines"]

        # The reviewer answers by hand, as before; the pass is kept with the run.
        assert {:ok, %{"state" => "approved"} = answered} =
                 Run.step(waits, f, review(), @now, [verdict(waits, "approved", ["reviewer"])])

        assert [%{"left" => true, "result" => %{"outcome" => ^outcome}}] =
                 answered["pending"]["passes"]
      end

      # A pass's late result for another revision is no answer.
      late = completed(run, "pass")

      assert {:error, :invalid_pass_result} =
               Run.pass_answer(run, f, review(%{"revision" => "r2"}), @now, late, spec(env))
    end
  end

  test "a review waiting in working keeps its entry and three days across the pass's migration" do
    for env <- @envs do
      f = flow(env, "pr_review")
      [first, m] = Model.AtlasEyra.selection("pr_review")["migrations"]
      assert {first["to"], m["from"], m["to"]} == {@selected, @selected, f.digest()}
      assert m["preserve_entry"] == true and m["states"] == Map.new(f.states(), &{&1, &1})

      old = new(env, "pr_review", %{}) |> Map.put("definition_sha256", @selected)
      assert {:ok, moved} = Run.migrate(old, f, [first, m], DateTime.add(@now, 1, :day))

      assert {moved["state"], moved["entry"], moved["deadlines"]} ==
               {"working", 1, old["deadlines"]}

      assert moved["definition_sha256"] == f.digest()
    end
  end
end
