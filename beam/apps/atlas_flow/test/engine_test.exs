defmodule AtlasFlow.EngineTest do
  # The engine's own rules, apart from what a process does with its fact (atlas_flow_test).
  use ExUnit.Case, async: false

  alias AtlasFlow.{Engine, FakeFacts}

  setup do
    Application.put_env(:atlas_bus, :store, "state-#{System.unique_integer([:positive])}")
    # A fresh supervisor for the facts' processes: a process killed in an earlier test (or
    # an earlier run of this one) does not count against the restarts it allows.
    :ok = Supervisor.terminate_child(AtlasFlow.Root, AtlasFlow.Supervisor)
    {:ok, _} = Supervisor.restart_child(AtlasFlow.Root, AtlasFlow.Supervisor)
    start_supervised!(FakeFacts)
    for key <- ["ada", "bob"], do: FakeFacts.put("clerk", %{"key" => key})

    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(AtlasFlow.Supervisor),
          do: DynamicSupervisor.terminate_child(AtlasFlow.Supervisor, pid)
    end)

    :ok
  end

  defp eventually(fun, tries \\ 150) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("did not happen")
      true -> Process.sleep(20) && eventually(fun, tries - 1)
    end
  end

  # A process handled its first look. Named as soon as it starts, before its init sent
  # the look: the first call waits for the init, the second for the look queued by it.
  defp looked(pid) do
    :sys.get_state(pid)
    :sys.get_state(pid)
  end

  defp todo(key), do: FakeFacts.get("box", key)["values"]["todo"]

  # A hint about the crate under B-1, as any change makes one.
  defp hint do
    {:stored, _} =
      AtlasFlow.Talk.put("crate", %{"op" => "change", "key" => "C-1", "values" => %{}})
  end

  test "a failure (IS-Atlas-23): a fact's process killed comes back, and reads Facts again" do
    alias AtlasFlow.Faults
    FakeFacts.put("box", %{"key" => "B-1", "progress" => %{"value" => "check"}})
    engine = start_supervised!({Engine, every: 3_600_000})
    # Its round started the process; the process's first look is sent in its init.
    Engine.round(engine)
    [{old, _}] = Registry.lookup(AtlasFlow.Items, {"box", "B-1"})
    looked(old)
    assert todo("B-1") == "Check it"

    assert [%{"fault" => "kill-process"}] = Faults.offers("B-1")
    assert Faults.offers("B-2") == []

    # What Flow wrote is gone from Facts; only a process that reads Facts writes it again.
    FakeFacts.put("box", %{"key" => "B-1", "progress" => %{"value" => "check"}})
    assert todo("B-1") == nil

    assert {:ok, "Killed Flow's process for B-1; back as a new one" <> _} =
             Faults.run("kill-process", "B-1")

    [{new, _}] = Registry.lookup(AtlasFlow.Items, {"box", "B-1"})
    assert new != old and not Process.alive?(old)
    looked(new)
    assert todo("B-1") == "Check it"

    assert {:error, _} = Faults.run("kill-process", "B-2")
  end

  test "a fact that reopens right after its process stopped moves at once, not a round later" do
    FakeFacts.put("box", %{"key" => "B-1", "progress" => %{"value" => "check"}})
    FakeFacts.put("crate", %{"key" => "C-1", "links" => %{"in_box" => ["B-1"]}})
    # No round comes within the test: only a hint can move B-1.
    start_supervised!({Engine, every: 3_600_000})
    :ok = AtlasBus.attach("tester-#{System.unique_integer([:positive])}")

    eventually(fn -> todo("B-1") == "Check it" end)
    [{pid, _}] = Registry.lookup(AtlasFlow.Items, {"box", "B-1"})
    ref = Process.monitor(pid)

    # The Registry forgets a stopped process a moment after it stops. Held still here, it
    # keeps naming it for as long as the test needs, so the race is certain, not likely.
    partitions = for {_, p, _, _} <- Supervisor.which_children(AtlasFlow.Items), do: p
    Enum.each(partitions, &:sys.suspend/1)
    on_exit(fn -> Enum.each(partitions, &resume/1) end)

    # Done: its process stops by itself.
    done = Map.merge(FakeFacts.get("box", "B-1"), %{"completion" => %{"done" => true}})
    FakeFacts.put("box", done)
    hint()
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 3_000
    eventually(fn -> todo("B-1") == nil end)
    assert [{^pid, _}] = Registry.lookup(AtlasFlow.Items, {"box", "B-1"})

    # Reopened at once, while the Registry still names the stopped process.
    FakeFacts.put("box", Map.delete(FakeFacts.get("box", "B-1"), "completion"))
    hint()
    eventually(fn -> todo("B-1") == "Check it" end, 50)
    Enum.each(partitions, &resume/1)
  end

  defp resume(partition) do
    if Process.alive?(partition), do: :sys.resume(partition)
  catch
    _, _ -> :ok
  end

  @tag :tmp_dir
  test "generated and legacy projections have one writer, with disjoint phases and restart deadlines",
       %{tmp_dir: dir} do
    alias AtlasFlow.{FixtureTarget, ManualClock}
    alias AtlasFlow.Runs.{Run, Store}
    FakeFacts.set_description(FakeFacts.run_description())
    FakeFacts.put("box", %{"key" => "B-1", "values" => %{"phase" => "first"}})
    FakeFacts.put("box", %{"key" => "B-2", "values" => %{"phase" => "second"}})
    yaml = Path.join(dir, "flows.yaml")
    File.write!(yaml, "fixture\n")
    clock = start_supervised!({ManualClock, ~U[2026-11-12 00:00:00Z]})

    opts = [
      every: 3_600_000,
      clock: {ManualClock, clock},
      target: FixtureTarget,
      deployed_yaml: yaml
    ]

    engine = start_supervised!({Engine, opts})
    Engine.round(engine)
    flush_items()
    assert todo("B-1") == "Sort it"
    assert todo("B-2") == "Pack it"
    assert [{_, _}] = Registry.lookup(AtlasFlow.Items, {"box", "B-1"})
    key = Run.key("sort", "box", "B-1", 1)
    config = FakeFacts.run_description()["flow_runtime"]
    {:ok, first} = Store.decode(config, FakeFacts.get("cursor", key))
    assert first["entry"] == 1
    ManualClock.advance(clock, 299_999)
    Engine.round(engine)
    stop_supervised!(Engine)
    stop_items()
    restarted = start_supervised!({Engine, opts})
    Engine.round(restarted)
    {:ok, waiting} = Store.decode(config, FakeFacts.get("cursor", key))
    assert waiting == first
    ManualClock.advance(clock, 2)
    Engine.round(restarted)
    {:ok, second} = Store.decode(config, FakeFacts.get("cursor", key))
    assert second["entry"] == 2
    assert second["last_input"]["due"] == "2026-11-12T00:05:00.000Z"
    send(restarted, :round)
    Engine.round(restarted)
    assert {:ok, ^second} = Store.decode(config, FakeFacts.get("cursor", key))
    stop_supervised!(Engine)
    stop_items()
    again = start_supervised!({Engine, opts})
    Engine.round(again)
    assert {:ok, ^second} = Store.decode(config, FakeFacts.get("cursor", key))
    FakeFacts.put("box", %{"key" => "B-1", "values" => %{"phase" => "first", "result" => "ok"}})
    Engine.round(again)
    {:ok, completed} = Store.decode(config, FakeFacts.get("cursor", key))
    assert completed["status"] == "completed"
    stop_supervised!(Engine)
    stop_items()
    final_engine = start_supervised!({Engine, opts})
    Engine.round(final_engine)
    assert {:ok, ^completed} = Store.decode(config, FakeFacts.get("cursor", key))
    # The generated phase releases presentation to a distinct legacy phase.
    FakeFacts.put("box", %{"key" => "B-1", "values" => %{"phase" => "second"}})
    Engine.round(final_engine)
    flush_items()
    assert todo("B-1") == "Pack it"
    assert {:ok, ^completed} = Store.decode(config, FakeFacts.get("cursor", key))
  end

  @tag :tmp_dir
  test "a mismatched or missing deployment refuses selected execution with zero writes", %{
    tmp_dir: dir
  } do
    alias AtlasFlow.{FixtureTarget, ManualClock}
    FakeFacts.set_description(FakeFacts.run_description())
    FakeFacts.put("box", %{"key" => "B-1", "values" => %{"phase" => "first"}})
    yaml = Path.join(dir, "flows.yaml")
    File.write!(yaml, "wrong bytes")
    clock = start_supervised!({ManualClock, ~U[2026-11-12 00:00:00Z]})

    engine =
      start_supervised!(
        {Engine, clock: {ManualClock, clock}, target: FixtureTarget, deployed_yaml: yaml}
      )

    Engine.round(engine)
    assert FakeFacts.sent() == []
    assert Registry.lookup(AtlasFlow.Items, {"box", "B-1"}) == []
    File.rm!(yaml)
    Engine.round(engine)
    assert FakeFacts.sent() == []
  end

  defp flush_items do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(AtlasFlow.Supervisor) do
      send(pid, :look)

      try do
        :sys.get_state(pid)
      catch
        :exit, _ -> :ok
      end
    end
  end

  defp stop_items do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(AtlasFlow.Supervisor),
        do: DynamicSupervisor.terminate_child(AtlasFlow.Supervisor, pid)
  end
end
