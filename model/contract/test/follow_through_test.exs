defmodule Model.FollowThroughTest do
  @moduledoc """
  Slice 14: an accepted decision stays owned until work is based on it or `no_work` says
  none is needed, on its own subflow `follow_through`, which takes the decision from where
  `decide` ends. Its selection, disjoint from decide's; the import table over accepted
  decisions as they stand (with work, with `no_work`, with neither); completion by the
  tally of the work based on it and by `no_work`; staying owned meanwhile, and ending when
  a newer decision supersedes it; and the composition's tally that counts its work.
  """
  use ExUnit.Case, async: true

  alias AtlasFlow.Runs.{Run, Store}

  @now ~U[2026-11-14 00:00:00Z]
  @envs [:prod, :test]
  @name "follow_through"
  @coordinator %{"kind" => "agent", "key" => "coordinator"}

  defp flow(env), do: Enum.find(Model.AtlasEyra.subflows(env), &(&1.name() == @name))
  defp selection, do: Model.AtlasEyra.selection(@name)
  defp runner(env), do: AtlasFlow.Model.load(Model.AtlasEyra, env, %{"decider" => "someone"})

  defp decision(values),
    do: %{"key" => "D-0100", "version" => "v1", "position" => 7, "values" => values}

  defp imported(env, values),
    do: Run.new(@name, flow(env), decision(values), selection()["imports"], @now)

  # Live accepted decisions as they stand before the subflow runs, and the entry each
  # takes: `{values, state, status}`. The tally of its work is not written yet on any.
  @rows [
    {%{"status" => "accepted", "consequences" => "the ledger changes"}, "waiting", "active"},
    {%{"status" => "accepted", "no_work" => true}, "no_work", "completed"},
    {%{"status" => "accepted", "no_work" => false}, "waiting", "active"},
    {%{"status" => "accepted", "unverified" => true}, "waiting", "active"}
  ]

  test "selected in both environments, runnable, and one writer with decide on a decision" do
    for env <- @envs do
      r = runner(env)
      assert r.refusal == nil
      assert Run.validate(flow(env)) == :ok
      assert r.config["selection"][@name]["admission"] == %{"status" => ["accepted"]}
      refute "accepted" in r.config["selection"]["decide"]["admission"]["status"]
    end

    # One presenter presents a decision, through both subflows: their projections are one.
    assert [p] = for(p <- Model.AtlasEyra.presentation(), p["subject"] == "decision", do: p)
    assert Enum.map(p["flows"], & &1["name"]) == ["decide", @name]
    assert selection()["projection"] == Model.AtlasEyra.selection("decide")["projection"]
  end

  test "every import row: no_work is completed history; any other accepted decision waits" do
    for env <- @envs, {values, state, status} <- @rows do
      run = imported(env, values)
      assert {run["state"], run["status"]} == {state, status}, inspect(values)
      # Imported, it writes nothing and arms no timer.
      assert run["pending"]["writes"] == []
      assert run["deadlines"]["timers"] == []
      assert run["last_input"]["import"] == true
    end

    for row <- selection()["imports"],
        env <- @envs,
        do: assert(Run.importable?(flow(env), row["state"]))
  end

  test "work based on it completes it: the tally's first offer moves an imported wait on" do
    for env <- @envs do
      waiting = imported(env, %{"status" => "accepted"})

      # The tally (`work`, of every scene, use case and issue based on it) reaches the run
      # on its first entry: one with work ends there, none is left owned or blocked.
      subject = decision(%{"status" => "accepted", "work" => 2})
      {:ok, ended} = Run.step(waiting, flow(env), subject, @now)
      assert {ended["state"], ended["status"]} == {"carried_out", "completed"}
      assert ended["pending"]["writes"] == []

      # Nothing based on it yet: it stays, owned.
      for work <- [0, nil] do
        values = %{"status" => "accepted", "work" => work}
        assert Run.step(waiting, flow(env), decision(values), @now) == {:ok, waiting}
      end
    end
  end

  test "no_work completes it, before work does; a newer decision that supersedes it ends it" do
    for env <- @envs do
      waiting = imported(env, %{"status" => "accepted"})

      for {values, state} <- [
            {%{"status" => "accepted", "no_work" => true}, "no_work"},
            {%{"status" => "accepted", "no_work" => true, "work" => 1}, "no_work"},
            {%{"status" => "superseded"}, "superseded"}
          ] do
        {:ok, ended} = Run.step(waiting, flow(env), decision(values), @now)
        assert {ended["state"], ended["status"]} == {state, "completed"}
      end

      # A completed one stays so, whatever happens to its work later.
      {:ok, done} =
        Run.step(waiting, flow(env), decision(%{"status" => "accepted", "work" => 1}), @now)

      undone = decision(%{"status" => "accepted", "work" => 0})
      assert Run.step(done, flow(env), undone, @now) == {:ok, done}
    end
  end

  test "while it waits, the coordinator owns it and is shown what to carry out" do
    for env <- @envs do
      f = flow(env)
      run = imported(env, %{"status" => "accepted"})
      consequences = "the ledger changes"
      values = %{"status" => "accepted", "consequences" => consequences}

      shown =
        AtlasFlow.Runs.Presentation.of_run(run, f, decision(values), fn default -> default end)

      assert shown["owner"] == @coordinator
      assert shown["name"] == "waiting"
      # What is expected carries the decision's own consequences, filled in.
      assert String.contains?(shown["expected"], consequences)
      refute shown["expected"] =~ "{"
      assert shown["preserve_kind"] == nil

      # Without consequences (an agent decided it, unverified), none is filled in and no
      # placeholder is left.
      bare = AtlasFlow.Runs.Presentation.of_run(run, f, decision(%{}), fn d -> d end)
      refute String.contains?(bare["expected"], consequences)
      refute bare["expected"] =~ "{"

      done = Map.merge(run, %{"status" => "completed", "state" => "carried_out"})

      assert AtlasFlow.Runs.Presentation.of_run(done, f, decision(values), & &1) ==
               %{"name" => "carried_out", "done" => true}
    end
  end

  test "the tally that counts its work is applied, with every kind based_on starts at" do
    for env <- @envs do
      assert runner(env).config["composition"]["tallies"] == [
               %{
                 "parent_subject" => "decision",
                 "relation" => "based_on",
                 "all" => "work",
                 "from" => ["scene", "use_case", "issue"],
                 "readers" => [@name]
               }
             ]
    end

    # Flow keeps the tally on the decision, which is frozen once accepted: frozen takes it.
    assert Model.AtlasEyra.__rela__({:entity, "decision"}).extension["frozen"]["tallied"] ==
             ["work"]

    # A run Flow stores and reads back is the same run.
    config = runner(:prod).config
    run = imported(:prod, %{"status" => "accepted"})

    assert {:ok, ^run} =
             Store.decode(config, %{"key" => run["key"], "values" => Store.encode(config, run)})
  end
end
