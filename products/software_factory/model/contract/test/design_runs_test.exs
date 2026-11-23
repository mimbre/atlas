defmodule Model.DesignRunsTest do
  @moduledoc """
  A use case's design runs on `design_and_accept`: its import table mapped onto the use
  cases on test and prod; its agent's design and its supervisor's acceptance, which ends
  the run and hands the use case to its break-down (`phase: break_down`).
  """
  use ExUnit.Case, async: true

  alias AtlasFlow.Runs.{Run, Store}

  @now ~U[2026-11-13 00:00:00Z]
  @envs [:prod, :test]
  @name "design_and_accept"
  @kind "use_case"

  defp flow(env), do: Enum.find(Model.AtlasEyra.subflows(env), &(&1.name() == @name))
  defp selection, do: Model.AtlasEyra.selection(@name)

  defp config(env),
    do: AtlasFlow.Model.load(Model.AtlasEyra, env, %{"decider" => "someone"}).config

  defp actors,
    do: elem(AtlasBus.Actors.resolve(Model.AtlasEyra.actors(), %{"decider" => "someone"}), 1)

  defp use_case(values),
    do: %{"key" => "UC-Atlas-01", "version" => "v1", "position" => 11, "values" => values}

  defp new(env, values),
    do: Run.new(@name, flow(env), use_case(values), selection()["imports"], @now)

  # A run whose entry writes Facts acknowledged.
  defp sent(run), do: put_in(run, ["pending", "writes"], [])
  defp at(run), do: {run["state"], run["status"], run["entry"]}

  # As the use cases on test and prod are today (status refine).
  defp live(design_status),
    do: %{
      "title" => "A use case",
      "description" => "What it is",
      "status" => "refine",
      "design_status" => design_status
    }

  # What the run presents in its state: {expected, owner}, as Flow's projection reads it.
  defp run_presents(env, state, values) do
    f = flow(env)

    {f.present(state, values)["expected"],
     AtlasFlow.Model.owner(f.owner(state)["default"], actors())}
  end

  # Which writer presents the use case: the run of the selected subflow that admits it.
  defp writer(env, values, runs) do
    {name, _s} = Store.selected(config(env), @kind, %{"values" => values})
    if runs[name]["status"] == "active", do: {:run, name}, else: :done
  end

  @architect %{"kind" => "agent", "key" => "architect"}
  defp tester, do: actors()["decider"]

  test "every import row of the design, mapped onto the use cases on test and prod" do
    assert selection()["imports"] == [
             %{"when" => %{"design_status" => ["in_review"]}, "state" => "accepting"}
           ]

    # No row leads to the accepted end: no acceptance is made for a use case whose design
    # was approved before; it is never admitted, so it never has a design run.
    refute Enum.any?(selection()["imports"], &(&1["state"] == "accepted"))

    for env <- @envs do
      # Writing, or sent back by its review: no row. It starts in designing, as a new one
      # does, writing nothing, for the architect until a person picks it up.
      for status <- ["writing", "changes_requested"] do
        values = live(status)
        run = new(env, values)
        assert at(run) == {"designing", "active", 1}
        refute Map.has_key?(run["last_input"], "import")
        assert run["pending"] == %{"version" => 1, "writes" => []}
        assert run["deadlines"]["timers"] == []
        assert run_presents(env, "designing", values) == {"Write its Design part", @architect}
        assert writer(env, values, %{@name => run}) == {:run, @name}
      end

      # In review (its design written by hand): the row joins its acceptance, writing
      # nothing, for the decider until a person picks it up.
      values = live("in_review")
      run = new(env, values)
      assert at(run) == {"accepting", "active", 1}
      assert run["last_input"] == %{"version" => 1, "import" => true}
      assert run["pending"] == %{"version" => 1, "writes" => []}
      assert run_presents(env, "accepting", values) == {"Accept its design", tester()}
      assert writer(env, values, %{@name => run}) == {:run, @name}
      # Imported where it is, it stays there: nothing moves it until it is accepted.
      assert {:ok, ^run} = Run.step(run, flow(env), use_case(values), @now)
    end
  end

  test "the design's acceptance: its supervisor's Accept ends its run, which writes accepted and hands it to its break-down, once" do
    for env <- @envs, status <- ["approved", "accepted"] do
      f = flow(env)
      designed = %{"key" => "TK-UC-Atlas-01-1", "outcome" => "completed"}

      {:ok, accepting} =
        Run.task_result(
          new(env, %{"design_status" => "writing"}),
          f,
          use_case(%{}),
          @now,
          "completed",
          designed,
          []
        )

      for from <- [sent(new(env, %{"design_status" => "in_review"})), sent(accepting)] do
        assert {:ok, accepted} = Run.step(from, f, use_case(%{"design_status" => status}), @now)
        assert at(accepted) == {"accepted", "completed", from["entry"] + 1}
        assert accepted["deadlines"]["timers"] == []

        assert [%{"id" => id, "kind" => @kind, "content" => content}] =
                 accepted["pending"]["writes"]

        assert content == %{
                 "op" => "change",
                 "key" => "UC-Atlas-01",
                 "values" => %{"design_status" => "accepted", "phase" => "break_down"},
                 "by" => "flow"
               }

        # The same entry gives the same id: a replay is the same write, stored once.
        assert {:ok, %{"pending" => %{"writes" => [%{"id" => ^id}]}}} =
                 Run.step(from, f, use_case(%{"design_status" => status}), @now)

        # Completed: nothing moves it again, whatever the use case says later.
        done = sent(accepted)

        for later <- ["writing", "in_review", "approved"],
            do:
              assert(
                {:ok, ^done} = Run.step(done, f, use_case(%{"design_status" => later}), @now)
              )
      end
    end
  end

  test "the agent's design: however its task ends, Accept its design is next; nothing by hand moves it" do
    for env <- @envs do
      f = flow(env)
      writing = new(env, %{"design_status" => "writing"})
      assert f.mechanism("designing") != nil

      for outcome <- ["completed", "check_failed", "stuck", "abandoned"] do
        ended = %{"key" => "TK-UC-Atlas-01-1", "outcome" => outcome}

        assert {:ok, accepting} =
                 Run.task_result(writing, f, use_case(%{}), @now, outcome, ended, [])

        assert at(accepting) == {"accepting", "active", 2}
      end

      # A design status written by hand moves nothing while the agent designs it.
      for status <- ["in_review", "changes_requested", "approved"],
          do:
            assert(
              {:ok, ^writing} = Run.step(writing, f, use_case(%{"design_status" => status}), @now)
            )

      # Its acceptance is the supervisor's (the decider's until one picked it up): Accept
      # approves the design.
      {expected, owner} = run_presents(env, "accepting", %{})
      assert {expected, owner} == {"Accept its design", tester()}

      assert [%{"label" => "Accept", "change" => %{"values" => %{"design_status" => "approved"}}}] =
               get_in(f.present("accepting", %{}), ["todo", "answers"])
    end
  end
end
