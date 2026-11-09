defmodule AtlasFlow.EngineTest do
  # The engine's own rules, apart from what a process does with its fact (atlas_flow_test).
  use ExUnit.Case, async: false

  alias AtlasFlow.{Engine, FakeFacts}

  setup do
    Application.put_env(:atlas_bus, :store, "state-#{System.unique_integer([:positive])}")
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

  defp todo(key), do: FakeFacts.get("box", key)["values"]["todo"]

  # A hint about the crate under B-1, as any change makes one.
  defp hint do
    {:stored, _} =
      AtlasFlow.Talk.put("crate", %{"op" => "change", "key" => "C-1", "values" => %{}})
  end

  test "a failure (IS-Atlas-23): a fact's process killed comes back, and reads Facts again" do
    alias AtlasFlow.Faults
    FakeFacts.put("box", %{"key" => "B-1", "progress" => %{"value" => "check"}})
    start_supervised!({Engine, every: 3_600_000})
    eventually(fn -> todo("B-1") == "Check it" end)
    [{old, _}] = Registry.lookup(AtlasFlow.Items, {"box", "B-1"})

    assert [%{"fault" => "kill-process"}] = Faults.offers("B-1")
    assert Faults.offers("B-2") == []

    # What Flow wrote is gone from Facts; only a process that reads Facts writes it again.
    FakeFacts.put("box", %{"key" => "B-1", "progress" => %{"value" => "check"}})
    assert todo("B-1") == nil

    assert {:ok, "Killed Flow's process for B-1; back as a new one" <> _} =
             Faults.run("kill-process", "B-1")

    [{new, _}] = Registry.lookup(AtlasFlow.Items, {"box", "B-1"})
    assert new != old and not Process.alive?(old)
    eventually(fn -> todo("B-1") == "Check it" end)

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
end
