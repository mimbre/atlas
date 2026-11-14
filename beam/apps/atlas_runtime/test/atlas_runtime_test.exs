defmodule AtlasRuntimeTest do
  use ExUnit.Case, async: false

  alias AtlasRuntime.{Engine, FakeFacts}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    Application.put_env(:atlas_bus, :store, "state-#{System.unique_integer([:positive])}")

    # A fresh supervisor for the turns: none is left from another test.
    :ok = Supervisor.terminate_child(AtlasRuntime.Root, AtlasRuntime.Supervisor)
    {:ok, _} = Supervisor.restart_child(AtlasRuntime.Root, AtlasRuntime.Supervisor)
    eventually(fn -> Registry.count(AtlasRuntime.Turns) == 0 end)

    # And none outlives this test: the umbrella runs the other apps' tests in this VM, where
    # a turn still renewing its lease puts facts on their Bus.
    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(AtlasRuntime.Supervisor),
          do: DynamicSupervisor.terminate_child(AtlasRuntime.Supervisor, pid)
    end)

    start_supervised!(FakeFacts)
    FakeFacts.put("clerk", %{"key" => "ada"})
    FakeFacts.put("clerk", %{"key" => "bob"})
    %{dir: dir}
  end

  # Ada's box: its card is hers, and the run of its subflow is in a state for it (nil: the
  # run ended), as Facts presents it.
  defp box(owner \\ "ada", state \\ "packing") do
    FakeFacts.put("box", %{"key" => "B-1", "links" => %{"card" => ["C-B-1"]}})

    FakeFacts.put("card", %{
      "key" => "C-B-1",
      "values" => %{"step" => state},
      "links" => %{"owned_by" => List.wrap(owner)},
      "presentation" => %{
        "owner" => List.wrap(owner),
        "state" => state,
        "status" => if(state, do: "active", else: "completed"),
        "actionable" => state != nil,
        "handover" => nil,
        "manual" => false
      }
    })
  end

  # Flow deferred a handover from ada while her turn runs: Facts presents it.
  defp deferred(card, state \\ "packing"),
    do:
      card
      |> put_in(["values", "later"], "pending")
      |> put_in(["values", "step"], state)
      |> put_in(["presentation", "state"], state)
      |> put_in(["presentation", "handover"], %{"from" => ["ada"], "position" => 1})

  defp engine(dir, more \\ []) do
    opts =
      [
        machine: "here",
        agents: %{"ada" => %{"port" => "stub"}},
        silence: 900,
        max: 60_000,
        lease: 100,
        every: 200,
        stub_dir: dir,
        crash_pause: 50,
        leave_grace: 300,
        model: AtlasRuntime.TestModel,
        name: Engine
      ]
      |> Keyword.merge(more)

    start_supervised!({Engine, opts})
  end

  defp mode(dir, agent, mode), do: File.write!(Path.join(dir, agent), mode)

  defp run(key), do: FakeFacts.get("run", key)

  defp eventually(fun, tries \\ 200) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("did not happen")
      true -> Process.sleep(25) && eventually(fun, tries - 1)
    end
  end

  defp settle_turns do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(AtlasRuntime.Supervisor),
        do: :sys.get_state(pid)
  end

  test "a delayed ownership snapshot cannot bypass a newly saved handover", %{dir: dir} do
    box()
    runtime = engine(dir, every: 3_600_000)
    eventually(fn -> run("R-C-B-1-1") != nil end)
    [{turn, _}] = Registry.lookup(AtlasRuntime.Turns, "R-C-B-1-1")

    held =
      FakeFacts.hold_read("card", %{
        "linked" => %{"owned_by" => "ada"},
        "plain" => true,
        "presentation" => true
      })

    round = Task.async(fn -> Engine.round(runtime) end)
    assert_receive {:held_read, ^held}, 3_000

    # Runtime's ownership answer is already captured. Flow commits its handover,
    # then the live turn ends before Runtime receives that old answer.
    card = FakeFacts.get("card", "C-B-1") |> deferred()
    FakeFacts.put("card", card)
    ref = Process.monitor(turn)
    AtlasRuntime.Turn.finish(turn, "the agent ended its turn: packed it")
    assert_receive {:DOWN, ^ref, :process, ^turn, :normal}, 3_000
    eventually(fn -> Registry.lookup(AtlasRuntime.Turns, "R-C-B-1-1") == [] end)
    FakeFacts.release_read()
    Task.await(round)
    settle_turns()
    assert run("R-C-B-1-1")["values"]["reason"] == "the agent ended its turn: packed it"
    assert run("R-C-B-1-2") == nil
    Engine.round(runtime)
    assert run("R-C-B-1-2") == nil
  end

  test "a normal end without a handover permits the same owner to continue", %{dir: dir} do
    box()
    runtime = engine(dir, every: 3_600_000)
    eventually(fn -> run("R-C-B-1-1") != nil end)
    [{turn, _}] = Registry.lookup(AtlasRuntime.Turns, "R-C-B-1-1")
    ref = Process.monitor(turn)
    FakeFacts.put("run", put_in(run("R-C-B-1-1"), ["values", "result"], "packed one part"))
    Engine.round(runtime)
    assert_receive {:DOWN, ^ref, :process, ^turn, :normal}, 3_000
    eventually(fn -> Registry.lookup(AtlasRuntime.Turns, "R-C-B-1-1") == [] end)
    Engine.round(runtime)
    eventually(fn -> run("R-C-B-1-2") != nil end)
    assert run("R-C-B-1-2")["links"]["run_by"] == ["ada"]
  end

  test "an orphaned turn keeps its stored outcome and does not restart from stale ownership", %{
    dir: dir
  } do
    box()
    engine(dir, every: 60_000)
    eventually(fn -> run("R-C-B-1-1") != nil end)
    [{pid, _}] = Registry.lookup(AtlasRuntime.Turns, "R-C-B-1-1")
    DynamicSupervisor.terminate_child(AtlasRuntime.Supervisor, pid)
    eventually(fn -> Registry.lookup(AtlasRuntime.Turns, "R-C-B-1-1") == [] end)
    turn = run("R-C-B-1-1") |> put_in(["values", "result"], "packed it before the restart")
    FakeFacts.put("run", turn)
    Engine.round(Engine)

    assert run("R-C-B-1-1")["values"]["reason"] ==
             "the agent ended its turn: packed it before the restart"

    assert run("R-C-B-1-2") == nil
  end

  test "a stored outcome ends the local turn through Runtime", %{dir: dir} do
    box()
    engine(dir)
    eventually(fn -> run("R-C-B-1-1") != nil end)
    turn = run("R-C-B-1-1") |> put_in(["values", "result"], "packed it")
    FakeFacts.put("run", turn)
    Engine.round(Engine)
    eventually(fn -> run("R-C-B-1-1")["values"]["status"] == "over" end)
    assert run("R-C-B-1-1")["values"]["reason"] == "the agent ended its turn: packed it"
  end

  test "an owned open fact gets a turn; its lease follows the agent's activity", %{dir: dir} do
    box()
    engine(dir)

    eventually(fn -> run("R-C-B-1-1") != nil end)
    turn = run("R-C-B-1-1")
    assert turn["values"]["status"] == "going"
    assert turn["values"]["host"] == "here"
    assert turn["links"] == %{"run_on" => ["C-B-1"], "run_by" => ["ada"]}

    [{"run", created} | _] = FakeFacts.sent()
    assert created["op"] == "create" and created["by"] == "runtime"
    assert created["cause"] == "ada owns C-B-1, and no turn of it runs: a turn (1)"

    # The stub is active: the lease is renewed, each time with what the agent did.
    eventually(fn ->
      Enum.count(FakeFacts.sent(), &match?({"run", %{"op" => "change"}}, &1)) >= 2
    end)

    {"run", renewed} = Enum.find(FakeFacts.sent(), &match?({"run", %{"op" => "change"}}, &1))
    assert renewed["cause"] =~ ~r/^activity: stub step \d+$/
    assert renewed["values"]["until"] =~ ~r/^\d{4}-\d\d-\d\dT/
    assert run("R-C-B-1-1")["values"]["status"] == "going"
  end

  test "a silent turn loses its lease and ends; the owner gets a new turn", %{dir: dir} do
    box()
    mode(dir, "ada", "silent")
    engine(dir)

    eventually(fn -> run("R-C-B-1-1")["values"]["status"] == "over" end)
    assert run("R-C-B-1-1")["values"]["reason"] =~ ~r/^silent for 0 s: no activity since /
    refute Map.has_key?(run("R-C-B-1-1")["values"], "until")

    # Still ada's, and open: the next round starts another turn.
    mode(dir, "ada", "active")
    eventually(fn -> run("R-C-B-1-2")["values"]["status"] == "going" end)
  end

  test "a crashed agent ends its turn; one that ends it, too", %{dir: dir} do
    box()
    engine(dir)
    eventually(fn -> run("R-C-B-1-1") != nil end)

    mode(dir, "ada", "crash once")
    eventually(fn -> run("R-C-B-1-1")["values"]["status"] == "over" end)
    assert run("R-C-B-1-1")["values"]["reason"] =~ "the agent crashed: :crashed"
    eventually(fn -> run("R-C-B-1-2")["values"]["status"] == "going" end)

    mode(dir, "ada", "end")

    eventually(fn ->
      run("R-C-B-1-2")["values"]["reason"] == "the agent ended its turn: the stub ended its turn"
    end)
  end

  test "only the owner's turn runs: one that moves away ends it; nobody else gets one", %{
    dir: dir
  } do
    box()
    engine(dir)
    eventually(fn -> run("R-C-B-1-1")["values"]["status"] == "going" end)

    # Flow, or anyone, moves it to bob, whom this machine does not run.
    box("bob")
    eventually(fn -> run("R-C-B-1-1")["values"]["status"] == "over" end)
    assert run("R-C-B-1-1")["values"]["reason"] == "C-B-1 is no longer ada's to work on"
    Process.sleep(500)
    assert FakeFacts.all("run") |> length() == 1
  end

  test "a turn whose item left its agent may still end by itself, for the grace", %{dir: dir} do
    box()
    engine(dir, leave_grace: 5_000)
    eventually(fn -> run("R-C-B-1-1")["values"]["status"] == "going" end)

    # As when ada hands it on itself: acknowledge reconciliation and its leave cast
    # before ending the stub; the grace must not depend on a wall-clock pause.
    box("bob")
    Engine.round(Engine)
    [{turn, _}] = Registry.lookup(AtlasRuntime.Turns, "R-C-B-1-1")
    assert :sys.get_state(turn).leaving == "C-B-1 is no longer ada's to work on"
    assert run("R-C-B-1-1")["values"]["status"] == "going"
    mode(dir, "ada", "end")

    eventually(fn ->
      run("R-C-B-1-1")["values"]["reason"] ==
        "C-B-1 is no longer ada's to work on, and the agent ended its turn by itself: " <>
          "the stub ended its turn"
    end)
  end

  test "a turn keeps running while its item's state changes and a handover waits for it", %{
    dir: dir
  } do
    box()
    engine(dir, every: 3_600_000)
    eventually(fn -> run("R-C-B-1-1")["values"]["status"] == "going" end)
    [{turn, _}] = Registry.lookup(AtlasRuntime.Turns, "R-C-B-1-1")

    # The agent adds children: Flow moves the item to its next state and defers the
    # handover until this turn ends. The item is still ada's.
    card =
      FakeFacts.get("card", "C-B-1")
      |> deferred("checking")

    FakeFacts.put("card", card)
    Engine.round(Engine)
    settle_turns()

    assert Registry.lookup(AtlasRuntime.Turns, "R-C-B-1-1") == [{turn, {"ada", "C-B-1"}}]
    assert :sys.get_state(turn).leaving == nil
    assert run("R-C-B-1-1")["values"]["status"] == "going"
    assert run("R-C-B-1-2") == nil
  end

  test "after the grace a moved turn ends, no new one starts; back to its agent, the next", %{
    dir: dir
  } do
    box()
    engine(dir, every: 3_600_000, leave_grace: 0)
    eventually(fn -> run("R-C-B-1-1")["values"]["status"] == "going" end)

    box("bob")
    Engine.round(Engine)
    eventually(fn -> run("R-C-B-1-1")["values"]["status"] == "over" end)
    assert run("R-C-B-1-1")["values"]["reason"] == "C-B-1 is no longer ada's to work on"
    Engine.round(Engine)
    assert FakeFacts.all("run") |> length() == 1

    box()
    Engine.round(Engine)
    eventually(fn -> run("R-C-B-1-2")["values"]["status"] == "going" end)
    assert run("R-C-B-1-2")["links"]["run_by"] == ["ada"]
  end

  test "a turn a human moved away stays ended: a later outcome by its agent changes nothing",
       %{dir: dir} do
    box()
    engine(dir, every: 3_600_000, leave_grace: 0)
    eventually(fn -> run("R-C-B-1-1")["values"]["status"] == "going" end)

    box("bob")
    Engine.round(Engine)
    eventually(fn -> run("R-C-B-1-1")["values"]["status"] == "over" end)

    FakeFacts.put("run", put_in(run("R-C-B-1-1"), ["values", "result"], "too late"))
    Engine.round(Engine)
    settle_turns()

    assert run("R-C-B-1-1")["values"]["status"] == "over"
    assert run("R-C-B-1-1")["values"]["reason"] == "C-B-1 is no longer ada's to work on"
    assert FakeFacts.all("run") |> length() == 1
  end

  test "an idle agent's turn ends at its maximum; an empty one at once; each time the next",
       %{dir: dir} do
    box()
    mode(dir, "ada", "idle")
    engine(dir, max: 300)

    eventually(fn -> run("R-C-B-1-1")["values"]["status"] == "over" end)
    assert run("R-C-B-1-1")["values"]["reason"] =~ ~r/^longer than the maximum of \d+ s$/
    eventually(fn -> run("R-C-B-1-2") != nil end)

    # Empty: its turns end at once, without an outcome, and the next one starts each time.
    mode(dir, "ada", "end")
    empty = "the agent ended its turn: the stub ended its turn"

    eventually(fn ->
      ended = for r <- FakeFacts.all("run"), r["values"]["reason"] == empty, do: r["key"]
      length(ended) >= 2
    end)
  end

  test "failures (IS-Atlas-23): kill a turn's agent; a stand-in agent's modes", %{dir: dir} do
    alias AtlasRuntime.Faults
    box()
    opts = [agents: %{"ada" => %{"port" => "stub"}, "cy" => %{"port" => "claude"}}, stub_dir: dir]
    engine(dir)
    eventually(fn -> run("R-C-B-1-1")["values"]["status"] == "going" end)

    # On a turn it runs: kill its agent. The turn ends as a crash; the next one starts.
    assert [%{"fault" => "kill-agent"}] = Faults.offers("R-C-B-1-1", opts)

    assert {:ok, "Killed ada's process for R-C-B-1-1." <> _} =
             Faults.run("kill-agent", "R-C-B-1-1", opts)

    eventually(fn -> run("R-C-B-1-1")["values"]["reason"] == "the agent crashed: :killed" end)
    eventually(fn -> run("R-C-B-1-2")["values"]["status"] == "going" end)

    # On a stand-in agent: its modes, through its file. A real agent's port gets none.
    assert ~w(idle silent empty active) == Enum.map(Faults.offers("ada", opts), & &1["fault"])
    assert Faults.offers("cy", opts) == []
    assert {:ok, "ada is idle now."} = Faults.run("idle", "ada", opts)
    assert File.read!(Path.join(dir, "ada")) == "idle"
    eventually(fn -> run("R-C-B-1-2")["values"]["last"] == "idle" end)
    assert {:ok, "ada ends its turns empty now."} = Faults.run("empty", "ada", opts)
    assert File.read!(Path.join(dir, "ada")) == "end"

    # Nothing it does not offer.
    assert {:error, _} = Faults.run("idle", "cy", opts)
    assert {:error, _} = Faults.run("kill-agent", "R-NONE", opts)
  end

  test "a fact Flow has no state for (done) gets no turn", %{dir: dir} do
    box("ada", nil)
    engine(dir)
    Engine.round(Engine)
    Process.sleep(300)
    assert FakeFacts.all("run") == []
  end

  test "a turn running in Facts with no process here is ended (Runtime restarted)", %{dir: dir} do
    box("bob")

    FakeFacts.put("run", %{
      "key" => "R-C-B-1-1",
      "values" => %{"status" => "going", "host" => "here"},
      "links" => %{"run_on" => ["C-B-1"], "run_by" => ["ada"]}
    })

    # Another machine's turn is not this one's to end.
    FakeFacts.put("run", %{
      "key" => "R-X-1",
      "values" => %{"status" => "going", "host" => "there"}
    })

    engine(dir)
    eventually(fn -> run("R-C-B-1-1")["values"]["status"] == "over" end)

    assert run("R-C-B-1-1")["values"]["reason"] ==
             "no process runs it on here any more (Runtime restarted)"

    assert run("R-X-1")["values"]["status"] == "going"
  end

  test "after a restart, the turn Facts had running ends and its agent gets the next", %{
    dir: dir
  } do
    box()

    FakeFacts.put("run", %{
      "key" => "R-C-B-1-1",
      "values" => %{"status" => "going", "host" => "here"},
      "links" => %{"run_on" => ["C-B-1"], "run_by" => ["ada"]}
    })

    engine(dir, every: 3_600_000)
    eventually(fn -> run("R-C-B-1-1")["values"]["status"] == "over" end)

    assert run("R-C-B-1-1")["values"]["reason"] ==
             "no process runs it on here any more (Runtime restarted)"

    Engine.round(Engine)
    eventually(fn -> run("R-C-B-1-2")["values"]["status"] == "going" end)
  end

  test "an agent's turn limit: no more turns here than that", %{dir: dir} do
    box()
    mode(dir, "ada", "end")
    engine(dir, agents: %{"ada" => %{"port" => "stub", "turn_limit" => 1}})
    eventually(fn -> run("R-C-B-1-1")["values"]["status"] == "over" end)
    assert run("R-C-B-1-1")["values"]["done_at"] =~ ~r/^\d{4}-/
    Process.sleep(800)
    assert length(FakeFacts.all("run")) == 1
  end

  test "3 crashes in 10 minutes: no more turns here, and the agent says it cannot run", %{
    dir: dir
  } do
    box()
    mode(dir, "ada", "crash")
    engine(dir)

    eventually(fn -> run("R-C-B-1-3")["values"]["status"] == "over" end)
    eventually(fn -> FakeFacts.get("clerk", "ada")["values"]["stuck"] != nil end)

    assert FakeFacts.get("clerk", "ada")["values"]["stuck"] =~
             ~r/^on here since .*: 3 crashes in 10 minutes$/

    Process.sleep(800)
    assert run("R-C-B-1-4") == nil

    {"clerk", marked} = Enum.find(FakeFacts.sent(), &match?({"clerk", _}, &1))

    assert marked["by"] == "runtime" and
             marked["cause"] == "ada crashed 3 times in 10 minutes on here"
  end

  test "a machine that runs no agents does nothing", %{dir: dir} do
    box()
    engine(dir, agents: %{})
    Engine.round(Engine)
    assert FakeFacts.all("run") == []
  end
end
