defmodule AtlasRuntime.PresentationReadersTest do
  @moduledoc """
  Runtime reads whether work is open, whose it is and whether a handover waits from
  Facts' presentation of it, never from the fields written on the item: a run that ended
  starts no worker and keeps none eligible, whatever is still written.
  """
  use ExUnit.Case, async: false

  alias AtlasRuntime.{Engine, FakeFacts, Guidance}

  @moduletag :tmp_dir

  # The item as Facts presents a run that ended: its step is still written (stale), but
  # nothing is to be done.
  @ended %{"owner" => ["ada"], "actionable" => false, "status" => "completed", "handover" => nil}
  @open %{"owner" => ["ada"], "actionable" => true, "status" => "active", "handover" => nil}

  setup %{tmp_dir: dir} do
    Application.put_env(:atlas_bus, :store, "state-#{System.unique_integer([:positive])}")
    :ok = Supervisor.terminate_child(AtlasRuntime.Root, AtlasRuntime.Supervisor)
    {:ok, _} = Supervisor.restart_child(AtlasRuntime.Root, AtlasRuntime.Supervisor)

    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(AtlasRuntime.Supervisor),
          do: DynamicSupervisor.terminate_child(AtlasRuntime.Supervisor, pid)
    end)

    start_supervised!(FakeFacts)
    FakeFacts.put("clerk", %{"key" => "ada"})
    %{dir: dir}
  end

  defp card(presentation) do
    FakeFacts.put("box", %{"key" => "B-1", "links" => %{"card" => ["C-B-1"]}})

    FakeFacts.put("card", %{
      "key" => "C-B-1",
      "values" => %{"step" => "packing"},
      "links" => %{"owned_by" => ["ada"]},
      "presentation" => presentation
    })
  end

  # One synchronous round, with no round of its own on a timer.
  defp one_round(dir) do
    engine =
      start_supervised!(
        {Engine,
         machine: "here",
         agents: %{"ada" => %{"port" => "stub"}},
         silence: 900,
         max: 60_000,
         lease: 100,
         every: 3_600_000,
         stub_dir: dir,
         crash_pause: 50,
         leave_grace: 300,
         model: AtlasRuntime.TestModel,
         name: Engine}
      )

    Engine.round(engine)
    Registry.lookup(AtlasRuntime.Turns, "R-C-B-1-1")
  end

  test "a run that ended starts no worker, whatever its item still says", %{dir: dir} do
    card(@ended)
    assert one_round(dir) == []
  end

  test "a deferred handover bars a new worker on open work", %{dir: dir} do
    card(%{@open | "handover" => %{"from" => ["ada"], "position" => 3}})
    assert one_round(dir) == []
  end

  test "open work its presentation gives the agent starts one", %{dir: dir} do
    card(@open)
    assert [{_pid, _}] = one_round(dir)
  end

  describe "a running turn's eligibility" do
    # Guidance reads from the calling process, which must be on the Bus.
    setup do
      :ok = AtlasBus.attach("runtime/presentation-#{System.unique_integer([:positive])}")
    end

    defp turn do
      now = System.system_time(:millisecond)

      FakeFacts.put("run", %{
        "key" => "R-C-B-1-1",
        "values" => %{
          "status" => "going",
          "host" => "here",
          "until" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 60))
        },
        "links" => %{"run_on" => ["C-B-1"], "run_by" => ["ada"]}
      })

      %{
        key: "R-C-B-1-1",
        turn_kind: "run",
        item: "C-B-1",
        kind: "card",
        agent: "ada",
        machine: "here",
        attempt: nil,
        since: now,
        active: now,
        max: 60_000,
        silence: 60_000,
        names: %{
          state: "status",
          running: "going",
          machine: "host",
          attempt: "try",
          by: "run_by",
          on: "run_on",
          outcome: "result",
          lease: "until"
        }
      }
    end

    test "is eligible while its presentation is open and the agent's" do
      card(@open)
      assert {:eligible, _deadline} = Guidance.eligible(turn())
    end

    test "is closed once the run ended, or the work is another's" do
      card(@ended)
      assert Guidance.eligible(turn()) == :closed
      card(%{@open | "owner" => ["bob"]})
      assert Guidance.eligible(turn()) == :closed
    end

    test "is paused while a handover waits for it" do
      card(%{@open | "handover" => %{"from" => ["ada"], "position" => 3}})
      assert Guidance.eligible(turn()) == :paused
    end
  end
end
