defmodule Model.DeliveryRunsTest do
  @moduledoc """
  Slice 8: the pull request runs on Flow's durable runs, in place of the legacy flow
  `review_and_merge`. Its selection and takeover of the presentation, the import table
  from the pull request as it was, the review and test it waits for through the
  composition's links (only those of its current revision), its integration by Code's
  receiver (approved by its own run's links, of its current revision only), `blocked` and
  its exits, and the migrations from the base's digests, on the compiled subflow of both
  environments.

  Slice 9: the issue too, in place of the legacy flow `build_and_merge`: the same, with
  what it presents and to whom kept from the legacy flow, and its pull request's outcome
  through the composition's link.
  """
  use ExUnit.Case, async: true

  alias AtlasFlow.Activities.Effect
  alias AtlasFlow.Composition.Links
  alias AtlasFlow.Runs.{Run, Store}

  @now ~U[2026-11-13 00:00:00Z]
  @envs [:prod, :test]
  @name "pull_request"

  # The digest the base recorded before slice 8 (the same in prod and test).
  @base "0d65d9a4aa1cdf916e022547e3f4a1974505cd94c349e9809f1a441f13cd8335"
  # And the one slice 8 recorded, merged by hand (the same in prod and test).
  @by_hand "e183d55ea7eb411d29dd812053dff89078b4ef131068a3223d40c22617bffbd0"
  @url "https://github.com/o/r/pull/1"
  @r2 "2222222222222222222222222222222222222222"

  # The model as composed, with one subflow's selection changed by the function the calling
  # test puts in its process (`{name, fun}`): what Flow's runner would be given.
  defmodule Altered do
    @moduledoc false
    defdelegate runs(), to: Model.AtlasEyra
    defdelegate composition(), to: Model.AtlasEyra
    defdelegate legacy(), to: Model.AtlasEyra

    def selection(name) do
      s = Model.AtlasEyra.selection(name)
      {altered, alter} = Process.get(:alter)
      if name == altered, do: alter.(s), else: s
    end
  end

  defp flow(env), do: Enum.find(Model.AtlasEyra.subflows(env), &(&1.name() == @name))
  defp flows(env), do: Map.new(Model.AtlasEyra.subflows(env), &{&1.name(), &1})
  defp selection, do: Model.AtlasEyra.selection(@name)
  defp legacy, do: Enum.find(Model.AtlasEyra.legacy(), &(&1.name() == "review_and_merge"))

  defp subject(values),
    do: %{"key" => "PR-o-r-1", "version" => "v1", "position" => 7, "values" => values}

  defp new(env, values),
    do: Run.new(@name, flow(env), subject(values), selection()["imports"], @now)

  # A run whose entry writes Facts acknowledged.
  defp sent(run), do: put_in(run, ["pending", "writes"], [])

  # What the composition's links offer the run: the values they wrote on its subject.
  defp offered(run, values),
    do:
      put_in(run, ["pending", "synthetic"], %{
        "id" => "S-#{run["entry"]}-#{Enum.join(Map.values(values))}",
        "values" => values,
        "sources" => []
      })

  defp at(run), do: {run["state"], run["status"], run["entry"]}

  # The links its run applied, as the run store records them: the review and the test
  # current for `revision`, each ended in `states` (approved and passed by default).
  defp approved(run, revision, states \\ %{}) do
    states = Map.merge(%{"review_outcome" => "approved", "test_outcome" => "passed"}, states)

    links =
      Map.new(states, fn {field, state} ->
        {field, %{"child" => "C-" <> field, "state" => state, "current" => revision}}
      end)

    put_in(run, ["pending", "composition"], %{"version" => 1, "links" => links})
  end

  # The composition's links of a pull request, as the run store gives them to the effect.
  defp links,
    do: for(l <- Model.AtlasEyra.composition()["links"], l["parent_subject"] == @name, do: l)

  defp freeze(run, spec, values),
    do: Effect.freeze(run, spec, subject(values), Effect.receivers(), links())

  # Code's answer for the run's frozen request.
  defp answer(intent, status) do
    r = intent["request"]

    base = %{
      "version" => 1,
      "id" => r["id"],
      "digest" => intent["digest"],
      "fingerprint" => r["fingerprint"]
    }

    if status == "done",
      do:
        Map.merge(base, %{"status" => "done", "reference" => "m", "outputs" => %{"sha" => "m"}}),
      else: Map.merge(base, %{"status" => "refused", "reason" => "ci_failed", "details" => %{}})
  end

  test "selected in both environments, runnable, and the one writer of a pull request" do
    for env <- @envs do
      runner = AtlasFlow.Model.load(Model.AtlasEyra, env, %{"decider" => "someone"})
      assert runner.refusal == nil

      assert Enum.sort(Map.keys(runner.config["selection"])) ==
               ~w(decide design_and_accept issue pr_review pr_test pull_request test_and_accept_scene test_and_accept_use_case)

      f = flow(env)
      assert Run.validate(f) == :ok
      # One activity, Code's integrate effect; no create: nothing else is dispatched or made.
      assert {:effect, spec} = f.mechanism("integrating")

      assert {spec["service"], spec["operation"], spec["target"], spec["approved"]} ==
               {"code", "integrate", "url", "revision"}

      # Approved by its review approving and its test passing, as their links write them.
      assert spec["approving"] == %{
               "review_outcome" => ["approved"],
               "test_outcome" => ["passed"]
             }

      assert spec["payload"] == ["revision"] and spec["fingerprint"]["fields"] == ["revision"]
      assert {spec["field"], spec["outputs"], spec["records"]} == {"integration", nil, nil}
      # Run only through a receiver Flow is told of (the core's `code` settings).
      assert Effect.valid?(spec) and not Effect.valid?(spec, %{})
      assert Enum.all?(f.states() -- ["integrating"], &(f.mechanism(&1) == nil))
      assert for(s <- f.states(), {:create, _} <- f.enter(s, %{}), do: s) == []

      # Every pull request, whatever it holds, is the run's: the legacy flow presents none.
      for values <- [%{}, %{"state" => "open"}, %{"state" => "merged"}, %{"state" => "closed"}],
          do: assert({@name, _} = Store.selected(runner.config, @name, %{"values" => values}))
    end

    s = selection()
    assert {s["subject"], s["legacy"], s["admission"]} == {@name, "review_and_merge", []}
    # No choice of people: Facts captures no write on a pull request as one.
    assert {s["choices"], s["choice_states"]} == {[], []}
    # It presents where the legacy flow did, the only legacy flow on the kind.
    assert Map.take(legacy().writes(), Map.keys(s["projection"])) == s["projection"]

    assert for(l <- Model.AtlasEyra.legacy(), @name in l.kinds(), do: l.name()) == [
             legacy().name()
           ]
  end

  test "a selection that does not take the pull request from its legacy flow is refused" do
    for env <- @envs,
        alter <- [
          &Map.delete(&1, "legacy"),
          &Map.delete(&1, "projection"),
          &Map.put(&1, "legacy", "build_and_merge")
        ] do
      Process.put(:alter, {@name, alter})
      assert {_config, {:two_writers, @name}} = Store.activate(Altered, flows(env))
    end

    Process.put(:alter, {@name, & &1})
    assert {_config, nil} = Store.activate(Altered, flows(:test))
  end

  test "every import row, none integrating; any other open pull request starts its checks" do
    assert selection()["imports"] == [
             %{"when" => %{"state" => ["merged"]}, "state" => "integrated"},
             %{"when" => %{"state" => ["closed"]}, "state" => "closed"},
             %{
               "when" => %{"review_outcome" => ["changes_requested"]},
               "state" => "changes_requested"
             },
             %{"when" => %{"test_outcome" => ["failed"]}, "state" => "changes_requested"},
             %{
               "when" => %{"review_outcome" => ["approved"], "test_outcome" => ["passed"]},
               "state" => "blocked"
             }
           ]

    for env <- @envs do
      # Completed history: nothing written, nothing armed, never moved again.
      for {values, state} <- [
            {%{"state" => "merged"}, "integrated"},
            {%{"state" => "merged", "review_outcome" => "changes_requested"}, "integrated"},
            {%{"state" => "closed"}, "closed"},
            {%{"state" => "closed", "test_outcome" => "passed"}, "closed"}
          ] do
        run = new(env, values)
        assert at(run) == {state, "completed", 1}
        assert run["pending"]["writes"] == [] and run["deadlines"]["timers"] == []
        assert run["last_input"]["import"] == true
        assert {:ok, ^run} = Run.step(run, flow(env), subject(%{"state" => "open"}), @now)
      end

      # An open one whose outcomes say where it is joins that wait, writing nothing; one
      # approved and passed waits blocked: an import never integrates.
      for {values, state} <- [
            {%{"state" => "open", "review_outcome" => "changes_requested"}, "changes_requested"},
            {%{"state" => "open", "test_outcome" => "failed"}, "changes_requested"},
            {%{"review_outcome" => "approved", "test_outcome" => "passed"}, "blocked"}
          ] do
        run = new(env, values)
        assert at(run) == {state, "active", 1}
        assert run["pending"] == %{"version" => 1, "writes" => []}
        assert run["deadlines"]["timers"] == []
        assert run["last_input"]["import"] == true
      end

      # Any other (every open pull request today: no flow wrote an outcome) matches no
      # row: it starts in checking as a new one does, writing only the reset outcomes.
      for values <- [
            %{},
            %{"state" => "open"},
            %{"state" => "open", "review_outcome" => "approved"},
            %{"review_outcome" => "none", "test_outcome" => "none"}
          ] do
        run = new(env, values)
        assert at(run) == {"checking", "active", 1}
        refute Map.has_key?(run["last_input"], "import")

        assert [%{"kind" => @name, "content" => %{"op" => "change", "values" => reset}}] =
                 run["pending"]["writes"]

        assert reset == %{
                 "review_outcome" => "none",
                 "test_outcome" => "none",
                 "update" => "none"
               }
      end
    end
  end

  test "approved and passed together integrate it; changes requested or failed send it back" do
    for env <- @envs do
      f = flow(env)
      checking = sent(new(env, %{"state" => "open"}))
      none = %{"state" => "open", "review_outcome" => "none", "test_outcome" => "none"}

      # The review alone is not enough: taken, the run waits on.
      approved = Map.put(none, "review_outcome", "approved")

      assert {:ok, waiting} =
               Run.synthetic(
                 offered(checking, %{"review_outcome" => "approved"}),
                 f,
                 subject(approved),
                 @now
               )

      assert at(waiting) == {"checking", "active", 1}
      refute Map.has_key?(waiting["pending"], "synthetic")

      both = Map.put(approved, "test_outcome", "passed")

      assert {:ok, merge} =
               Run.synthetic(
                 offered(waiting, %{"test_outcome" => "passed"}),
                 f,
                 subject(both),
                 @now
               )

      assert at(merge) == {"integrating", "active", 2}
      assert merge["last_input"]["synthetic"] == "S-1-passed"
      # Entering the effect resets its result, as every mechanism's.
      assert [%{"content" => %{"values" => %{"integration" => "none"}}}] =
               merge["pending"]["writes"]

      for {field, value} <- [{"review_outcome", "changes_requested"}, {"test_outcome", "failed"}] do
        values = Map.put(none, field, value)

        assert {:ok, back} =
                 Run.synthetic(offered(checking, %{field => value}), f, subject(values), @now)

        assert at(back) == {"changes_requested", "active", 2}
      end

      # Outcomes written by hand are no result of a review or test: nothing moves.
      assert {:ok, ^checking} = Run.step(checking, f, subject(both), @now)
    end
  end

  test "a late result moves nothing once the pull request moved on" do
    for env <- @envs, state <- ["changes_requested", "blocked"] do
      f = flow(env)
      run = new(env, %{"review_outcome" => "approved", "test_outcome" => "passed"})
      run = if state == "blocked", do: run, else: new(env, %{"test_outcome" => "failed"})
      assert run["state"] == state

      for late <- [%{"review_outcome" => "approved"}, %{"test_outcome" => "failed"}] do
        values = Map.merge(%{"state" => "open"}, late)
        assert {:ok, same} = Run.synthetic(offered(run, late), f, subject(values), @now)
        assert same == run
      end
    end
  end

  test "Code integrates the revision its own run approved, and only that one" do
    for env <- @envs do
      f = flow(env)
      {:effect, spec} = f.mechanism("integrating")
      both = %{"url" => @url, "review_outcome" => "approved", "test_outcome" => "passed"}
      at_r2 = Map.put(both, "revision", @r2)

      run =
        new(env, Map.put(at_r2, "state", "open"))
        |> sent()
        |> Map.merge(%{"state" => "integrating", "entry" => 2})

      # Outcomes alone, a review and test of another revision, a revision that moved
      # after them, or a review or test of r2 that rejected it: nothing is asked of Code.
      assert {:error, :not_ready} = freeze(run, spec, at_r2)
      assert {:error, :not_ready} = freeze(approved(run, "r1"), spec, at_r2)

      assert {:error, :not_ready} =
               freeze(approved(run, @r2), spec, Map.put(both, "revision", "r3"))

      for rejected <- [%{"review_outcome" => "changes_requested"}, %{"test_outcome" => "failed"}],
          do: assert({:error, :not_ready} = freeze(approved(run, @r2, rejected), spec, at_r2))

      # Its review and test were of r2, and it is at r2: Code is asked to integrate r2.
      assert {:ok, intent} = freeze(approved(run, @r2), spec, at_r2)
      r = intent["request"]
      assert {r["service"], r["operation"], r["target"]} == {"code", "integrate", @url}
      assert r["payload"] == %{"revision" => @r2}
      assert r["approved"] == r["fingerprint"]

      assert r["fingerprint"] ==
               AtlasBus.SubjectFingerprint.of(
                 %{"values" => r["payload"]},
                 r["fingerprint_definition"]
               )

      # Once Code is asked, merging or closing it by hand moves nothing: Code's answer does.
      waiting = put_in(approved(run, @r2), ["pending", "effect"], intent)

      for changes <- [%{"state" => "merged"}, %{"state" => "closed"}, %{"update" => "updated"}] do
        values = subject(Map.merge(at_r2, changes))
        assert {:ok, ^waiting} = Run.step(waiting, f, values, @now)
        assert :stay = Run.unfrozen(waiting, f, values, @now)
      end

      assert {:ok, done} =
               Run.effect_result(waiting, f, subject(at_r2), @now, answer(intent, "done"))

      assert at(done) == {"integrated", "completed", 3}

      assert [%{"content" => %{"values" => %{"integration" => "done"}}}] =
               done["pending"]["writes"]

      assert [%{"result" => %{"reference" => "m"}}] = done["pending"]["effects"]

      assert {:ok, blocked} =
               Run.effect_result(waiting, f, subject(at_r2), @now, answer(intent, "refused"))

      assert at(blocked) == {"blocked", "active", 3}
      assert [%{"result" => %{"reason" => "ci_failed"}}] = blocked["pending"]["effects"]
    end
  end

  test "blocked: a retry integrates again, a new revision checks again, by hand it ends" do
    for env <- @envs do
      f = flow(env)
      open = %{"state" => "open", "url" => @url, "revision" => @r2, "integration" => "refused"}
      blocked = sent(new(env, %{"review_outcome" => "approved", "test_outcome" => "passed"}))
      assert at(blocked) == {"blocked", "active", 1}
      assert {:ok, ^blocked} = Run.step(blocked, f, subject(open), @now)

      for {changes, state, status} <- [
            {%{"integration" => "retry"}, "integrating", "active"},
            {%{"update" => "updated"}, "checking", "active"},
            {%{"state" => "merged"}, "integrated", "completed"},
            {%{"state" => "closed"}, "closed", "completed"}
          ] do
        assert {:ok, moved} = Run.step(blocked, f, subject(Map.merge(open, changes)), @now)
        assert at(moved) == {state, status, 2}
      end

      # A retry is a new entry: a new request, never the refused one again.
      {:ok, retried} = Run.step(blocked, f, subject(Map.put(open, "integration", "retry")), @now)
      {:effect, spec} = f.mechanism("integrating")
      values = Map.merge(open, %{"review_outcome" => "approved", "test_outcome" => "passed"})
      {:ok, again} = freeze(approved(retried, @r2), spec, values)
      refute again["request"]["id"] == Effect.id(blocked, spec)
    end
  end

  test "a new revision starts its checks again; the replaced revision's results never count" do
    links = Model.AtlasEyra.composition()["links"]

    for env <- @envs do
      f = flow(env)
      back = new(env, %{"state" => "open", "review_outcome" => "changes_requested"})
      assert {:ok, ^back} = Run.step(back, f, subject(%{"state" => "open"}), @now)

      assert {:ok, again} =
               Run.step(back, f, subject(%{"state" => "open", "update" => "updated"}), @now)

      assert at(again) == {"checking", "active", 2}

      assert [%{"content" => %{"values" => %{"review_outcome" => "none", "update" => "none"}}}] =
               again["pending"]["writes"]
    end

    # The pull request is at r2 now: a review or test of r1, however it ended, is no
    # longer current; only r2's own result is written.
    for {child, field, yes} <- [
          {"pr_review", "review_outcome", "approved"},
          {"pr_test", "test_outcome", "passed"}
        ] do
      link = Enum.find(links, &(&1["child"] == child and &1["parent_subject"] == @name))
      assert {link["field"], link["stale"]} == {field, "drop"}
      parent = %{"key" => "PR-o-r-1", "values" => %{"revision" => "r2"}}
      old = %{"key" => "C-1", "values" => %{"revision" => "r1"}}
      new = %{"key" => "C-2", "values" => %{"revision" => "r2"}}

      run = fn key, state ->
        %{"key" => "run-" <> key, "flow" => child, "entry" => 2, "state" => state}
      end

      assert Links.select(link, parent, [old], %{"C-1" => run.("C-1", yes)}, nil) == :none

      runs = %{"C-1" => run.("C-1", yes), "C-2" => run.("C-2", "working")}
      assert Links.select(link, parent, [old, new], runs, nil) == :waiting

      runs = %{runs | "C-2" => run.("C-2", yes)}
      assert {:write, ^yes, source} = Links.select(link, parent, [old, new], runs, nil)
      assert {source["child"], source["current"]} == {"C-2", "r2"}
      # Applied once: the same completion again writes nothing.
      assert {:applied, ^source} = Links.select(link, parent, [old, new], runs, source)
    end
  end

  test "until Code is asked, integrating ends by hand; a run never approved does not wait for ever" do
    for env <- @envs do
      f = flow(env)
      # Reached through a retry, with no links of its revision (or links of another one).
      open = %{"state" => "open", "url" => @url, "revision" => @r2}

      for run <- [
            new(env, open) |> sent() |> Map.merge(%{"state" => "integrating", "entry" => 2}),
            new(env, open)
            |> sent()
            |> Map.merge(%{"state" => "integrating", "entry" => 2})
            |> approved("r1")
          ] do
        {:effect, spec} = f.mechanism("integrating")
        assert {:error, :not_ready} = freeze(run, spec, open)
        assert :stay = Run.unfrozen(run, f, subject(open), @now)

        for {changes, state, status} <- [
              {%{"state" => "merged"}, "integrated", "completed"},
              {%{"state" => "closed"}, "closed", "completed"},
              {%{"update" => "updated"}, "checking", "active"}
            ] do
          assert {:ok, moved} = Run.unfrozen(run, f, subject(Map.merge(open, changes)), @now)
          assert at(moved) == {state, status, 3}
          assert moved["last_input"]["branch"] == state
          refute Map.has_key?(moved["pending"], "effect")
        end

        # Its entry writes not acknowledged yet: nothing moves before them.
        unsent = put_in(run, ["pending", "writes"], [%{"id" => "w"}])
        assert :stay = Run.unfrozen(unsent, f, subject(Map.put(open, "state", "merged")), @now)
      end
    end
  end

  test "merged or closed ends it from every open state; restarted, a waiting run stays" do
    for env <- @envs do
      f = flow(env)

      # Every open state but integrating, whose exits by hand hold until Code is asked (above).
      waiting = [
        sent(new(env, %{"state" => "open"})),
        new(env, %{"test_outcome" => "failed"}),
        new(env, %{"review_outcome" => "approved", "test_outcome" => "passed"})
      ]

      assert Enum.map(waiting, & &1["state"]) == ~w(checking changes_requested blocked)

      for run <- waiting do
        # A restart rebuilds nothing but the compiled subflow: the same run is unmoved.
        assert {:ok, ^run} = Run.step(run, flow(env), subject(%{"state" => "open"}), @now)

        for {state, final} <- [{"merged", "integrated"}, {"closed", "closed"}] do
          assert {:ok, ended} = Run.step(run, f, subject(%{"state" => state}), @now)
          assert {ended["state"], ended["status"]} == {final, "completed"}
          assert ended["entry"] == run["entry"] + 1
          assert ended["pending"]["writes"] == []
        end
      end
    end
  end

  test "each open state presents its move to the coordinator; checking as the legacy flow did" do
    for env <- @envs do
      f = flow(env)

      for state <- ~w(checking changes_requested integrating blocked) do
        assert %{"expected" => text, "why" => why} = f.present(state, %{})
        assert text != "" and why != ""
        assert f.owner(state)["default"] == %{"kind" => "agent", "key" => "coordinator"}
      end

      # Started or imported in checking, a pull request keeps what it showed and its owner.
      assert f.present("checking", %{})["expected"] == legacy().expected("open", %{})
      assert f.present("checking", %{})["why"] == legacy().why("open")
      assert legacy().owner("open") == f.owner("checking")["default"]
    end
  end

  test "the changes from the base's digests are declared state migrations, never a re-key" do
    for env <- @envs do
      f = flow(env)
      [first, m] = selection()["migrations"]
      # Slice 8's, kept: its `to` is the `from` of the next one.
      assert {first["from"], first["to"]} == {@base, @by_hand}
      assert {m["from"], m["to"]} == {@by_hand, f.digest()}
      kept = ~w(changes_requested checking closed integrated)
      assert m["states"] == Map.put(Map.new(kept, &{&1, &1}), "integrating", "blocked")

      for x <- [first, m],
          do: refute(Map.has_key?(x, "rekey") or Map.has_key?(x, "preserve_entry"))

      migrations = selection()["migrations"]

      old = fn values, state ->
        new(env, values)
        |> sent()
        |> Map.merge(%{"definition_sha256" => @by_hand, "state" => state})
      end

      # A run waiting for the merge by hand waits blocked, with links approving its revision
      # or none: nothing is integrated at the deploy, nothing is written, and merged or
      # closed by hand still ends it (a retry integrates it).
      open = %{"state" => "open", "url" => @url, "revision" => @r2}

      for waiting <- [
            old.(open, "integrating"),
            old.(open, "integrating") |> approved(@r2)
          ] do
        assert {:ok, moved} = Run.migrate(waiting, f, migrations, @now)
        assert at(moved) == {"blocked", "active", 2}
        assert moved["definition_sha256"] == f.digest()
        assert moved["pending"]["writes"] == []
        assert moved["pending"]["composition"] == waiting["pending"]["composition"]
        assert f.mechanism("blocked") == nil
        assert {:ok, ^moved} = Run.step(moved, f, subject(open), @now)

        for {state, final} <- [{"merged", "integrated"}, {"closed", "closed"}] do
          assert {:ok, ended} = Run.step(moved, f, subject(Map.put(open, "state", state)), @now)
          assert {ended["state"], ended["status"]} == {final, "completed"}
        end

        assert {:ok, retried} =
                 Run.step(moved, f, subject(Map.put(open, "integration", "retry")), @now)

        assert at(retried) == {"integrating", "active", 3}
      end

      # The others re-enter where they were; history stays as it was.
      for state <- ~w(checking changes_requested) do
        assert {:ok, again} = Run.migrate(old.(%{"state" => "open"}, state), f, migrations, @now)
        assert at(again) == {state, "active", 2}
      end

      done = new(env, %{"state" => "merged"}) |> Map.put("definition_sha256", @by_hand)
      assert {:ok, ^done} = Run.migrate(done, f, migrations, @now)

      # No run kept the first digest (none had it); one that did would be refused, blocked.
      older = old.(%{"state" => "open"}, "blocked") |> Map.put("definition_sha256", @base)
      assert {:error, :definition_changed} = Run.migrate(older, f, migrations, @now)
    end
  end

  # -- Slice 9: the issue -------------------------------------------------------------------

  @issue "issue"
  # The digest the base recorded before slice 9 (the same in prod and test).
  @issue_base "99b406f1da0c908d703acd82c37c2bd07ec5c103e352809afed37b676693ed5e"

  defp issue_flow(env), do: Enum.find(Model.AtlasEyra.subflows(env), &(&1.name() == @issue))
  defp issue_selection, do: Model.AtlasEyra.selection(@issue)
  defp builder, do: Enum.find(Model.AtlasEyra.legacy(), &(&1.name() == "build_and_merge"))

  defp issue(values),
    do: %{"key" => "IS-Atlas-01", "version" => "v1", "position" => 9, "values" => values}

  defp issue_new(env, values),
    do: Run.new(@issue, issue_flow(env), issue(values), issue_selection()["imports"], @now)

  # As the issues on test and prod are today: in Specification, nothing a flow wrote.
  @live %{"title" => "An issue", "description" => "What it is", "stage" => "specification"}

  test "the issue is selected in both environments, runnable, and the one writer of an issue" do
    for env <- @envs do
      runner = AtlasFlow.Model.load(Model.AtlasEyra, env, %{"decider" => "someone"})
      assert runner.refusal == nil
      assert Map.has_key?(runner.config["selection"], @issue)

      f = issue_flow(env)
      assert Run.validate(f) == :ok
      # No pass, gate or effect, no create and no timer: nothing is dispatched or made for
      # an issue, and nothing is due.
      assert Enum.all?(f.states(), &(f.mechanism(&1) == nil))
      assert for(s <- f.states(), {:create, _} <- f.enter(s, %{}), do: s) == []
      assert Enum.all?(f.states(), &(f.timers(&1) == []))

      # Every issue, whatever its stage, is the run's: the legacy flow presents none.
      for stage <- [nil, "specification", "design", "development"],
          do:
            assert(
              {@issue, _} =
                Store.selected(runner.config, @issue, %{"values" => %{"stage" => stage}})
            )

      # The use case counts its issues (slice 10 selects its design, a subflow on a use
      # case): an issue's run moving drains the run on its use case. The scene counts its
      # use cases (slice 12 selects a subflow on the scene).
      assert Enum.map(runner.config["composition"]["counts"], & &1["child"]) ==
               [@issue, "test_and_accept_use_case"]
    end

    s = issue_selection()
    assert {s["subject"], s["legacy"], s["admission"]} == {@issue, "build_and_merge", []}
    # No choice of people: Facts captures no write on an issue as one.
    assert {s["choices"], s["choice_states"]} == {[], []}
    # It presents where the legacy flow did, the only legacy flow on the kind.
    assert Map.take(builder().writes(), Map.keys(s["projection"])) == s["projection"]

    assert for(l <- Model.AtlasEyra.legacy(), @issue in l.kinds(), do: l.name()) == [
             builder().name()
           ]
  end

  test "a selection that does not take the issue from its legacy flow is refused" do
    for env <- @envs,
        alter <- [
          &Map.delete(&1, "legacy"),
          &Map.delete(&1, "projection"),
          &Map.put(&1, "legacy", "review_and_merge")
        ] do
      Process.put(:alter, {@issue, alter})
      assert {_config, {:two_writers, @issue}} = Store.activate(Altered, flows(env))
    end

    Process.put(:alter, {@issue, & &1})
    assert {_config, nil} = Store.activate(Altered, flows(:prod))
  end

  test "every import row of the issue; any other issue starts building, writing nothing" do
    assert issue_selection()["imports"] == [
             %{"when" => %{"pr_outcome" => ["integrated"]}, "state" => "done"}
           ]

    for env <- @envs do
      f = issue_flow(env)

      # Completed history: nothing written, nothing armed, never moved again.
      for values <- [
            %{"pr_outcome" => "integrated"},
            Map.put(@live, "pr_outcome", "integrated")
          ] do
        run = issue_new(env, values)
        assert at(run) == {"done", "completed", 1}
        assert run["pending"]["writes"] == [] and run["deadlines"]["timers"] == []
        assert run["last_input"]["import"] == true
        assert {:ok, ^run} = Run.step(run, f, issue(@live), @now)

        # A late outcome of a pull request moves a completed run no more.
        assert {:ok, ^run} =
                 Run.synthetic(offered(run, %{"pr_outcome" => "closed"}), f, issue(@live), @now)
      end

      # Every other issue (each one on test and prod today) matches no row: it starts in
      # author as a new one does, at once, whatever its stage; with nothing to write and
      # nothing due, what it showed and its owner stay.
      for values <- [
            %{},
            @live,
            Map.put(@live, "stage", "design"),
            Map.put(@live, "stage", "development"),
            Map.put(@live, "pr_outcome", "none"),
            Map.put(@live, "pr_outcome", "open"),
            Map.put(@live, "pr_outcome", "changes_requested"),
            Map.put(@live, "pr_outcome", "closed"),
            # Results no pass, gate or effect of this subflow wrote are no history of it.
            Map.merge(@live, %{
              "pass_result" => "delivered",
              "gate_result" => "ready",
              "effect_result" => "done"
            })
          ] do
        run = issue_new(env, values)
        assert at(run) == {"author", "active", 1}
        refute Map.has_key?(run["last_input"], "import")
        assert run["pending"] == %{"version" => 1, "writes" => []}
        assert run["deadlines"]["timers"] == []
      end
    end
  end

  test "building presents what the legacy flow did, to the same owner" do
    for env <- @envs do
      f = issue_flow(env)
      present = f.present("author", @live)

      assert {present["expected"], present["why"]} ==
               {builder().expected("building", %{}), builder().why("building")}

      assert present["todo"]["instructions"] ==
               "Build it in one pull request and get that merged; link the pull request to it."

      assert f.owner("author")["default"] == builder().owner("building")
      assert f.owner("author")["default"] == %{"kind" => "agent", "key" => "coordinator"}
      # Done presents nothing: the projection clears what is expected, as for v1's done.
      assert f.present("done", @live) == nil and f.final?("done")
    end
  end

  test "its pull request's outcome, through the link: merged ends it; anything else builds on" do
    for env <- @envs do
      f = issue_flow(env)
      building = issue_new(env, @live)

      assert {:ok, done} =
               Run.synthetic(
                 offered(building, %{"pr_outcome" => "integrated"}),
                 f,
                 issue(Map.put(@live, "pr_outcome", "integrated")),
                 @now
               )

      assert at(done) == {"done", "completed", 2}
      assert done["pending"]["writes"] == [] and done["deadlines"]["timers"] == []
      assert done["last_input"]["synthetic"] == "S-1-integrated"

      # Changes requested, or closed: built again (a new entry), nothing written, the same
      # presentation, so the projection moves nothing.
      for outcome <- ["changes_requested", "closed"] do
        values = Map.put(@live, "pr_outcome", outcome)

        assert {:ok, again} =
                 Run.synthetic(
                   offered(building, %{"pr_outcome" => outcome}),
                   f,
                   issue(values),
                   @now
                 )

        assert at(again) == {"author", "active", 2}
        assert again["pending"]["writes"] == [] and again["deadlines"]["timers"] == []
        assert f.present("author", values) == f.present("author", @live)

        # And merged later, through the same link: done.
        assert {:ok, later} =
                 Run.synthetic(
                   offered(again, %{"pr_outcome" => "integrated"}),
                   f,
                   issue(Map.put(@live, "pr_outcome", "integrated")),
                   @now
                 )

        assert at(later) == {"done", "completed", 3}
      end

      # An outcome written by hand is no result of a pull request's run: nothing moves.
      assert {:ok, ^building} =
               Run.step(building, f, issue(Map.put(@live, "pr_outcome", "integrated")), @now)
    end
  end

  test "the pull request's link to its issue: what it writes, and when it writes nothing" do
    link = Enum.find(Model.AtlasEyra.composition()["links"], &(&1["child"] == "pull_request"))

    assert {link["parent_subject"], link["relation"], link["field"], link["current"]} ==
             {@issue, "in_issue", "pr_outcome", nil}

    parent = %{"key" => "IS-Atlas-01", "values" => @live}
    pr = %{"key" => "PR-eyra-atlas-4", "values" => %{}}

    run = fn state, entry ->
      %{"key" => "run-pr-4", "flow" => "pull_request", "entry" => entry, "state" => state}
    end

    # A pull request in its checks, or being merged, reports nothing yet: its issue builds on.
    for state <- ["checking", "integrating"],
        do:
          assert(
            Links.select(link, parent, [pr], %{pr["key"] => run.(state, 1)}, nil) == :waiting
          )

    # Each outcome its run reaches is written once.
    for {state, value} <- [
          {"changes_requested", "changes_requested"},
          {"integrated", "integrated"},
          {"closed", "closed"}
        ] do
      runs = %{pr["key"] => run.(state, 2)}
      assert {:write, ^value, source} = Links.select(link, parent, [pr], runs, nil)
      assert {source["child"], source["state"]} == {pr["key"], state}
      assert {:applied, ^source} = Links.select(link, parent, [pr], runs, source)
    end

    # An issue without a pull request: nothing.
    assert Links.select(link, parent, [], %{}, nil) == :none

    # Two pull requests on one issue (a closed one and the next): every one is current
    # without an identity, so the link refuses to choose and writes nothing (a risk named
    # in the slice's report, not a behaviour to keep).
    other = %{"key" => "PR-eyra-atlas-5", "values" => %{}}
    runs = %{pr["key"] => run.("closed", 2), other["key"] => run.("integrated", 3)}

    assert Links.select(link, parent, [pr, other], runs, nil) ==
             {:refused, :ambiguous, ["PR-eyra-atlas-4", "PR-eyra-atlas-5"]}
  end

  test "restarted, a building issue stays as it was, and so does a done one" do
    for env <- @envs do
      config = AtlasFlow.Model.load(Model.AtlasEyra, env, %{"decider" => "someone"}).config

      for run <- [issue_new(env, @live), issue_new(env, %{"pr_outcome" => "integrated"})] do
        # What Facts keeps, read back by a new Flow with a freshly compiled subflow.
        stored = %{"key" => run["key"], "values" => Store.encode(config, run)}
        assert {:ok, ^run} = Store.decode(config, stored)

        assert {:ok, ^run} =
                 Run.migrate(run, issue_flow(env), issue_selection()["migrations"], @now)

        assert {:ok, ^run} = Run.step(run, issue_flow(env), issue(@live), @now)
      end
    end
  end

  test "the issue's change from the base's digest is a declared state migration, never a re-key" do
    for env <- @envs do
      f = issue_flow(env)
      [m] = issue_selection()["migrations"]
      assert {m["from"], m["to"]} == {@issue_base, f.digest()}
      refute Map.has_key?(m, "rekey") or Map.has_key?(m, "preserve_entry")

      old_states =
        ~w(author closed delivery_gate done in_pr needs_person publish review review_gate rework)

      assert Enum.sort(Map.keys(m["states"])) == old_states
      assert Enum.all?(Map.values(m["states"]), &(&1 in f.states()))

      old = fn state, status, pending ->
        issue_new(env, @live)
        |> Map.merge(%{"definition_sha256" => @issue_base, "state" => state, "status" => status})
        |> update_in(["pending"], &Map.merge(&1, pending))
      end

      # A quiescent open run of the old digest builds on, in a new entry.
      for state <- ~w(author in_pr needs_person) do
        assert {:ok, moved} = Run.migrate(old.(state, "active", %{}), f, [m], @now)
        assert at(moved) == {"author", "active", 2}
        assert moved["definition_sha256"] == f.digest()
        assert [%{"from" => @issue_base, "state" => ^state}] = moved["pending"]["migrations"]
      end

      # One with a frozen activity is not quiescent: it blocks, nothing is redone.
      for {state, pending} <- [
            {"delivery_gate", %{"gate" => %{"id" => "g"}}},
            {"review", %{"pass" => %{"request" => %{}}}},
            {"publish", %{"effect" => %{"request" => %{}}}}
          ],
          do:
            assert(
              {:error, :definition_changed} =
                Run.migrate(old.(state, "active", pending), f, [m], @now)
            )

      # A done run stays done; a closed (cancelled) one is never taken for done: it blocks.
      assert {:ok, done} = Run.migrate(old.("done", "completed", %{}), f, [m], @now)
      assert {done["state"], done["status"]} == {"done", "completed"}

      assert {:error, :definition_changed} =
               Run.migrate(old.("closed", "completed", %{}), f, [m], @now)
    end
  end
end
