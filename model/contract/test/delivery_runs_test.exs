defmodule Model.DeliveryRunsTest do
  @moduledoc """
  Slice 8: the pull request runs on Flow's durable runs, in place of the legacy flow
  `review_and_merge`. Its selection and takeover of the presentation, the import table
  from the pull request as it was, the review and test it waits for through the
  composition's links (only those of its current revision), the merge by hand that ends
  it, and the migration from the base's digest, on the compiled subflow of both
  environments.
  """
  use ExUnit.Case, async: true

  alias AtlasFlow.Composition.Links
  alias AtlasFlow.Runs.{Run, Store}

  @now ~U[2026-11-13 00:00:00Z]
  @envs [:prod, :test]
  @name "pull_request"

  # The digest the base recorded before slice 8 (the same in prod and test).
  @base "0d65d9a4aa1cdf916e022547e3f4a1974505cd94c349e9809f1a441f13cd8335"

  # The model as composed, with the pull request's selection changed by the function the
  # calling test puts in its process: what Flow's runner would be given.
  defmodule Altered do
    @moduledoc false
    defdelegate runs(), to: Model.AtlasEyra
    defdelegate composition(), to: Model.AtlasEyra
    defdelegate legacy(), to: Model.AtlasEyra

    def selection(name) do
      s = Model.AtlasEyra.selection(name)
      if name == "pull_request", do: Process.get(:alter).(s), else: s
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

  test "selected in both environments, runnable, and the one writer of a pull request" do
    for env <- @envs do
      runner = AtlasFlow.Model.load(Model.AtlasEyra, env, %{"decider" => "someone"})
      assert runner.refusal == nil

      assert Enum.sort(Map.keys(runner.config["selection"])) ==
               ~w(decide pr_review pr_test pull_request)

      f = flow(env)
      assert Run.validate(f) == :ok
      # No activity and no create: nothing is dispatched or made for it.
      assert Enum.all?(f.states(), &(f.mechanism(&1) == nil))
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
      Process.put(:alter, alter)
      assert {_config, {:two_writers, @name}} = Store.activate(Altered, flows(env))
    end

    Process.put(:alter, & &1)
    assert {_config, nil} = Store.activate(Altered, flows(:test))
  end

  test "every import row; any other open pull request starts its checks" do
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
               "state" => "integrating"
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

      # An open one whose outcomes say where it is joins that wait, writing nothing.
      for {values, state} <- [
            {%{"state" => "open", "review_outcome" => "changes_requested"}, "changes_requested"},
            {%{"state" => "open", "test_outcome" => "failed"}, "changes_requested"},
            {%{"review_outcome" => "approved", "test_outcome" => "passed"}, "integrating"}
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
      assert merge["pending"]["writes"] == []
      assert f.present("integrating", both)["expected"] == "Merge it"

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
    for env <- @envs, state <- ["changes_requested", "integrating"] do
      f = flow(env)
      run = new(env, %{"review_outcome" => "approved", "test_outcome" => "passed"})
      run = if state == "integrating", do: run, else: new(env, %{"test_outcome" => "failed"})
      assert run["state"] == state

      for late <- [%{"review_outcome" => "approved"}, %{"test_outcome" => "failed"}] do
        values = Map.merge(%{"state" => "open"}, late)
        assert {:ok, same} = Run.synthetic(offered(run, late), f, subject(values), @now)
        assert same == run
      end
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

  test "merged or closed ends it from every open state; restarted, a waiting run stays" do
    for env <- @envs do
      f = flow(env)

      waiting = [
        sent(new(env, %{"state" => "open"})),
        new(env, %{"test_outcome" => "failed"}),
        new(env, %{"review_outcome" => "approved", "test_outcome" => "passed"})
      ]

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

      for state <- ~w(checking changes_requested integrating) do
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

  test "the change from the base's digest is a declared state migration, never a re-key" do
    for env <- @envs do
      f = flow(env)
      [m] = selection()["migrations"]
      assert {m["from"], m["to"]} == {@base, f.digest()}

      assert m["states"] ==
               Map.put(Map.new(f.states(), &{&1, &1}), "blocked", "integrating")

      refute Map.has_key?(m, "rekey") or Map.has_key?(m, "preserve_entry")

      # A quiescent run of the old digest waiting in blocked would wait for the merge.
      old =
        new(env, %{"test_outcome" => "failed"})
        |> Map.merge(%{"definition_sha256" => @base, "state" => "blocked"})

      assert {:ok, moved} = Run.migrate(old, f, [m], @now)
      assert at(moved) == {"integrating", "active", 2}
      assert moved["definition_sha256"] == f.digest()
    end
  end
end
