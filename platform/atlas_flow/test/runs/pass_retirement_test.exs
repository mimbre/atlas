defmodule AtlasFlow.Runs.PassRetirementTest do
  @moduledoc """
  F0: Flow has no pass. Runs a subflow left while it still had one, a shared pass (its
  owner's Runtime answering for them), are in Facts when Flow restarts on the version
  without it. Each moves along the approved entry-preserving migration: its state, entry
  and timers are kept, what it held of its pass (`pass`, `passes`, `pass_result`) is
  retired into the migration's audit, nothing is sent to a Runtime, and the run goes on by
  hand (a choice, its timer) or stays as it ended. Facts is a stand-in; the clock is manual.
  """
  use ExUnit.Case, async: false
  alias AtlasFlow.{Engine, FakeFacts, ManualClock, Sorts, Talk, TestModel}
  alias AtlasFlow.Runs.{Run, Store}
  @now ~U[2026-11-12 00:00:00Z]

  # The digest the sort had with its pass: a definition this build can no longer compile.
  @with_pass Run.digest("the sort with its shared pass, before F0")

  defmodule Retiring do
    use AtlasFlow.TestModel,
      subflows: [AtlasFlow.Sorts.Answered],
      selection: %{
        "sort" =>
          AtlasFlow.Depot.selection("sort")
          |> Map.put("imports", [])
          |> Map.put("migrations", [
            %{
              "from" => AtlasFlow.Runs.Run.digest("the sort with its shared pass, before F0"),
              "to" => AtlasFlow.Sorts.Answered.digest(),
              "states" => Map.new(AtlasFlow.Sorts.Answered.states(), &{&1, &1}),
              "preserve_entry" => true,
              "reason" => "F0: the pass removed; choices by hand; live entries and timers kept"
            }
          ])
      }
  end

  # The same model without the approved migration: the old runs cannot move.
  defmodule Unmigrated do
    use AtlasFlow.TestModel,
      subflows: [AtlasFlow.Sorts.Answered],
      selection: %{
        "sort" => AtlasFlow.Depot.selection("sort") |> Map.put("imports", [])
      }
  end

  # A frozen request as the pass froze it (its id, digest and binding).
  defp intent(key, extra \\ %{}) do
    request = %{
      "version" => 1,
      "id" => "pass-" <> key,
      "name" => "inspect",
      "subject" => key,
      "owner" => "ada",
      "machine" => "desk",
      "machine_field" => "node",
      "request" => %{"mode" => "start", "permissions" => "review-packet"}
    }

    Map.merge(%{"request" => request, "digest" => "sha256:" <> key}, extra)
  end

  defp old(key, values, f) do
    subject = %{
      "key" => key,
      "values" => Map.merge(%{"phase" => "first"}, values),
      "links" => %{"owned_by" => ["ada"]}
    }

    FakeFacts.put("box", subject)

    run =
      Run.new("sort", Sorts.Answered, subject, [], @now)
      |> Map.put("definition_sha256", @with_pass)
      |> f.()

    {key, run}
  end

  defp seed(config) do
    for key <- ["ada", "bob"], do: FakeFacts.put("clerk", %{"key" => key})

    runs =
      Map.new([
        # Waiting in working while its owner's Runtime runs the pass.
        old(
          "B-wait",
          %{},
          &put_in(&1, ["pending", "pass"], intent("B-wait", %{"execution" => "turn-1"}))
        ),
        # Its pass answered nothing (uncertain): the clerk was to answer by hand.
        old(
          "B-unanswered",
          %{},
          &put_in(
            &1,
            ["pending", "pass"],
            intent("B-unanswered", %{
              "execution" => "turn-2",
              "result" => %{
                "id" => "pass-B-unanswered",
                "status" => "completed",
                "outcome" => "uncertain"
              }
            })
          )
        ),
        # Moved on to stuck by its timer: the pass it left is kept with the run.
        old("B-left", %{}, fn run ->
          run
          |> Map.merge(%{"state" => "stuck", "entry" => 2})
          |> put_in(["deadlines", "timers"], [])
          |> put_in(["pending", "passes"], [
            Map.put(Map.take(intent("B-left"), ["request"]), "left", true)
          ])
        end),
        # Ended by the pass's answer, its write acknowledged.
        old("B-done", %{"choice" => "yes"}, fn run ->
          record = %{
            "request" => intent("B-done")["request"],
            "result" => %{"id" => "pass-B-done", "status" => "completed", "outcome" => "pass"}
          }

          run
          |> Map.merge(%{"state" => "done", "status" => "completed", "entry" => 2})
          |> put_in(["deadlines", "timers"], [])
          |> put_in(["pending", "passes"], [record])
          |> Map.put("last_input", %{
            "version" => 1,
            "pass" => "pass-B-done",
            "execution" => "turn-3"
          })
        end)
      ])

    for {_, run} <- runs,
        do: FakeFacts.put("cursor", %{"key" => run["key"], "values" => Store.encode(config, run)})

    runs
  end

  defp stored(config, run), do: elem(Store.decode(config, FakeFacts.get("cursor", run["key"])), 1)

  defp choose(run, choice) do
    {:stored, _} =
      Talk.put("choice", %{
        "op" => "submit",
        "key" => "I-#{run["subject_key"]}-#{choice}",
        "values" => %{
          "run" => run["key"],
          "entry" => run["entry"],
          "roles" => ["clerk"],
          "changed_fields" => %{"choice" => choice}
        }
      })
  end

  setup do
    Application.put_env(
      :atlas_bus,
      :store,
      "pass-retirement-#{System.unique_integer([:positive])}"
    )

    start_supervised!(FakeFacts)
    clock = start_supervised!({ManualClock, @now})
    # The node's pass endpoint: whatever Flow did, nothing may reach it.
    :ok = AtlasBus.attach("runtime@desk/passes")
    %{clock: clock}
  end

  test "restarted with old pass-state runs present: each loads, keeps its entry, and goes on by hand",
       %{clock: clock} do
    config = TestModel.config(Retiring)
    runs = seed(config)
    opts = [clock: {ManualClock, clock}, model: Retiring]

    # Twice: the first boot migrates, the second finds nothing left to do.
    for _ <- 1..2 do
      engine = start_supervised!({Engine, opts})
      :ok = Engine.round(engine)

      for {key, old} <- runs do
        migrated = stored(config, old)
        assert migrated["definition_sha256"] == Sorts.Answered.digest(), key
        assert migrated["status"] == old["status"] and migrated["blocked_reason"] in [nil, ""]

        assert Map.take(migrated, ~w(state entry entered_at deadlines last_input)) ==
                 Map.take(old, ~w(state entry entered_at deadlines last_input))

        # Nothing of the pass is left to ask, wait on or take a reply for.
        assert Map.take(migrated["pending"], ~w(pass passes pass_result)) == %{}

        assert [%{"from" => @with_pass, "retired" => retired}] =
                 migrated["pending"]["migrations"]

        assert retired == Map.take(old["pending"], ~w(pass passes pass_result))
      end

      stop_supervised!(Engine)
    end

    # The clerk answers by hand, in the entry the run kept.
    choose(stored(config, runs["B-wait"]), "yes")
    choose(stored(config, runs["B-left"]), "no")
    done = stored(config, runs["B-done"])
    engine = start_supervised!({Engine, opts})
    :ok = Engine.round(engine)
    assert {"done", "completed", 2} == at(stored(config, runs["B-wait"]))
    assert {"discarded", "completed", 3} == at(stored(config, runs["B-left"]))
    assert {"working", "active", 1} == at(stored(config, runs["B-unanswered"]))

    # The day still counts from the old entry; a run the pass ended stays as it ended.
    ManualClock.advance(clock, 86_400_000)
    :ok = Engine.round(engine)
    assert {"stuck", "active", 2} == at(stored(config, runs["B-unanswered"]))
    assert stored(config, runs["B-done"]) == done
    stop_supervised!(Engine)

    refute_received {:atlas_bus, _, _}
  end

  test "without the approved migration the old runs are blocked, never run on", %{clock: clock} do
    config = TestModel.config(Unmigrated)
    runs = seed(config)
    engine = start_supervised!({Engine, clock: {ManualClock, clock}, model: Unmigrated})
    :ok = Engine.round(engine)

    for {_, old} <- runs do
      blocked = stored(config, old)
      assert blocked["status"] == "blocked" and blocked["definition_sha256"] == @with_pass
      assert blocked["blocked_reason"] =~ "definition_changed"
    end

    refute_received {:atlas_bus, _, _}
  end

  defp at(run), do: {run["state"], run["status"], run["entry"]}
end
