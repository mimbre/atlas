defmodule Model.ReviewRunsTest do
  @moduledoc """
  Slice 7: the review and the test of a pull request run on Flow's durable runs. Their
  selection, the import table from the facts as they were, the trusted verdict, the three
  days, and the revision a result counts for, on the compiled subflows of both
  environments; and the migrations of the review's runs, also of those that held its
  reviewer's pass, which F0 removed: its verdict is given by hand.
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

  # The review's digest as slice 7 selected it, without its pass.
  @selected "7291ab5579991c4083ad2d1f18c211a7cc7c85ec27735c8d00d0d99e8752542e"

  # The review's digest with its reviewer's pass, before F0 removed it.
  @with_pass "05019b5d840dc936ea1f6f59f7be2849967f321a975b62bba01dacde16fa1682"

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

      # Neither has an activity (F0 removed the review's pass): people give the verdict,
      # and an import into the wait reruns nothing.
      for name <- ~w(pr_test pr_review) do
        f = flow(env, name)
        assert Enum.all?(f.states(), &(f.mechanism(&1) == nil))
        assert Run.importable?(f, "working")
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
      # The review's leads on to the pass's, and that one to F0's (below).
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

  # -- The review pass removed (F0) ------------------------------------------------------

  @agent "reviewer-agent"

  # A frozen pass as Flow froze it for an agent reviewer with a machine, on the packet
  # the review named; `extra` is what came of it (its execution, its result).
  defp pass(extra \\ %{}),
    do:
      Map.merge(
        %{
          "request" => %{
            "version" => 1,
            "id" => "pass-1",
            "name" => "review",
            "subject" => "PRR-1",
            "owner" => @agent,
            "machine" => "desk",
            "machine_field" => "machine",
            "request" => %{
              "mode" => "start",
              "permissions" => "review-packet",
              "packet" => %{"packet_id" => "p1", "fingerprint" => "fpr_1", "revision" => "r1"}
            }
          },
          "digest" => "sha256:pass-1"
        },
        extra
      )

  defp migrations, do: Model.AtlasEyra.selection("pr_review")["migrations"]

  test "the pass's digest and the one before it each move to F0's, keeping entries and timers" do
    for env <- @envs do
      f = flow(env, "pr_review")
      [first, to_pass, from_pass, from_selected] = migrations()
      assert {first["to"], to_pass["from"], to_pass["to"]} == {@selected, @selected, @with_pass}
      assert {from_pass["from"], from_pass["to"]} == {@with_pass, f.digest()}
      assert {from_selected["from"], from_selected["to"]} == {@selected, f.digest()}

      for m <- [to_pass, from_pass, from_selected] do
        assert m["preserve_entry"] == true and m["states"] == Map.new(f.states(), &{&1, &1})
      end

      # A review waiting in working from either digest: its entry and three days kept.
      for from <- [@selected, @with_pass] do
        old = new(env, "pr_review", %{}) |> Map.put("definition_sha256", from)
        assert {:ok, moved} = Run.migrate(old, f, migrations(), DateTime.add(@now, 1, :day))

        assert {moved["state"], moved["entry"], moved["deadlines"]} ==
                 {"working", 1, old["deadlines"]}

        assert moved["definition_sha256"] == f.digest()
        assert [%{"from" => ^from} = audit] = moved["pending"]["migrations"]
        refute Map.has_key?(audit, "retired")
      end
    end
  end

  test "a run that held its reviewer's pass: the pass is retired, the reviewer answers by hand" do
    for env <- @envs do
      f = flow(env, "pr_review")
      old = fn run -> Map.put(run, "definition_sha256", @with_pass) end
      waiting = new(env, "pr_review", %{}) |> Map.put("key", "R-1") |> old.()

      cases = [
        # Frozen, its Runtime running it, or offline.
        put_in(waiting, ["pending", "pass"], pass(%{"execution" => "turn-1"})),
        put_in(waiting, ["pending", "pass"], pass()),
        # Done, answering nothing (uncertain): the reviewer was to answer by hand.
        put_in(
          waiting,
          ["pending", "pass"],
          pass(%{
            "execution" => "turn-1",
            "result" => %{"id" => "pass-1", "status" => "completed", "outcome" => "uncertain"}
          })
        ),
        # Left for another revision, and the new one frozen.
        waiting
        |> put_in(["pending", "passes"], [Map.put(Map.take(pass(), ["request"]), "left", true)])
        |> put_in(["pending", "pass"], pass())
      ]

      for run <- cases do
        assert {:ok, moved} = Run.migrate(run, f, migrations(), DateTime.add(@now, 1, :day))

        assert Map.take(moved, ~w(state status entry entered_at deadlines last_input)) ==
                 Map.take(run, ~w(state status entry entered_at deadlines last_input))

        assert Map.take(moved["pending"], ~w(pass passes pass_result)) == %{}
        assert [%{"from" => @with_pass, "retired" => retired}] = moved["pending"]["migrations"]
        assert retired == Map.take(run["pending"], ~w(pass passes pass_result))

        # The reviewer's verdict by hand ends it; nothing of the pass is written.
        assert {:ok, done} =
                 Run.step(moved, f, review(), @now, [verdict(moved, "approved", ["reviewer"])])

        assert {done["state"], done["status"], done["entry"]} == {"approved", "completed", 2}
        assert done["pending"]["writes"] == []
        refute Map.has_key?(done["pending"], "pass") or Map.has_key?(done["pending"], "passes")

        # Three days without one escalate it, as before.
        due = DateTime.add(@now, 3, :day)
        assert {:ok, %{"state" => "escalated", "entry" => 2}} = Run.step(moved, f, review(), due)
      end

      # Escalated with the pass it left, and approved by the pass's answer: kept as they are.
      escalated =
        waiting
        |> Map.merge(%{"state" => "escalated", "entry" => 2})
        |> put_in(["deadlines", "timers"], [])
        |> put_in(["pending", "passes"], [Map.put(Map.take(pass(), ["request"]), "left", true)])

      approved =
        waiting
        |> Map.merge(%{"state" => "approved", "status" => "completed", "entry" => 2})
        |> put_in(["deadlines", "timers"], [])
        |> put_in(["pending", "passes"], [
          %{"request" => pass()["request"], "result" => %{"id" => "pass-1", "outcome" => "pass"}}
        ])
        |> Map.put("last_input", %{"version" => 1, "pass" => "pass-1", "execution" => "turn-1"})

      for run <- [escalated, approved] do
        assert {:ok, moved} = Run.migrate(run, f, migrations(), @now)

        assert Map.take(moved, ~w(state status entry last_input)) ==
                 Map.take(run, ~w(state status entry last_input))

        assert moved["pending"]["passes"] == nil
        assert {:ok, ^moved} = Run.step(moved, f, review(), @now)
      end

      # The escalated one still takes a maintainer's verdict, in the entry it kept.
      {:ok, moved} = Run.migrate(escalated, f, migrations(), @now)
      changes = [verdict(moved, "changes_requested", ["maintainer"], 9)]

      assert {:ok, %{"state" => "changes_requested"}} =
               Run.step(moved, f, review(), @now, changes)
    end
  end

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
end
