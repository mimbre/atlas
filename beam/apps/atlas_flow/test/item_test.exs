defmodule AtlasFlow.ItemTest do
  # One fact's process by itself (no engine): what it holds while it waits. It is watched
  # by tracing (calls of its handle_info and when it is scheduled out), so each assertion
  # follows what it handled in order: no waiting on time.
  use ExUnit.Case, async: false

  alias AtlasFlow.{FakeFacts, Item, ManualClock}

  @every 60_000
  # Where a hibernated GenServer waits: erlang:hibernate/3 before OTP 28, then
  # gen_server:loop_hibernate/4 (erlang:hibernate/0).
  @hibernated [{:erlang, :hibernate, 3}, {:gen_server, :loop_hibernate, 4}]

  setup do
    Application.put_env(:atlas_bus, :store, "state-#{System.unique_integer([:positive])}")
    # A description as large as a real one: many small terms. A process never holds it.
    big = Map.put(FakeFacts.description(), "notes", Enum.map(1..20_000, &%{"n" => &1}))
    start_supervised!({FakeFacts, description: big})
    for key <- ["ada", "bob"], do: FakeFacts.put("clerk", %{"key" => key})
    # Its own fact: a process another test file left running (atlas_flow_test starts them
    # under the shared supervisor, Registry frees a name only a moment after its process
    # stops) holds its own key, never this one, whatever the order of the files.
    key = "B-#{System.unique_integer([:positive])}"
    FakeFacts.put("box", %{"key" => key, "progress" => %{"value" => "check"}})
    clock = start_supervised!({ManualClock, ~U[2026-11-12 00:00:00Z]})

    pid =
      start_supervised!(
        {Item, {"box", key, every: @every, clock: {ManualClock, clock}, model: AtlasFlow.Depot}}
      )

    # Its first look (sent in init) is handled before this.
    :sys.get_state(pid)
    assert FakeFacts.get("box", key)["values"]["todo"] == "Check it"

    # Traced to this test only; tracing ends with either process.
    :erlang.trace_pattern({Item, :handle_info, 2}, [{:_, [], [{:return_trace}]}], [:local])
    on_exit(fn -> :erlang.trace_pattern({Item, :handle_info, 2}, false, [:local]) end)
    :erlang.trace(pid, true, [:call, :running])
    %{pid: pid, clock: clock, description: big}
  end

  test "an idle process hibernates after a look on its timer", %{pid: pid, clock: clock} do
    {reads, _} = FakeFacts.reads()

    ManualClock.advance(clock, @every)
    hibernates_after(pid, :look)

    assert elem(FakeFacts.reads(), 0) > reads
    assert current(pid) in @hibernated
    # Only what it keeps (a few hundred words), none of the description it read.
    assert {:total_heap_size, words} = Process.info(pid, :total_heap_size)
    assert words < 5_000
  end

  test "after a poke it hibernates too, holding no description", %{pid: pid, clock: clock} do
    Item.poke(pid)
    # Not idle yet: a look is due once the burst of hints settles.
    await(pid, &match?({:return_from, {Item, :handle_info, 2}, {:noreply, %{soon: true}}}, &1))
    ManualClock.advance(clock, 50)
    hibernates_after(pid, {:look, :poked})

    assert current(pid) in @hibernated
    assert {:total_heap_size, words} = Process.info(pid, :total_heap_size)
    assert words < 5_000
    state = :sys.get_state(pid)
    assert %{soon: false} = state
    # What it walks (the model's relations) is the runner's, read once at boot.
    refute Map.has_key?(state, :description)
  end

  test "a late answer leaves an idle process hibernated", %{pid: pid} do
    send(pid, {:atlas_bus, :late, %{}})
    hibernates_after(pid, {:atlas_bus, :late, %{}})
    assert current(pid) in @hibernated
  end

  defp current(pid), do: elem(Process.info(pid, :current_function), 1)

  # It handles `message`, answers to hibernate, and then waits hibernated.
  defp hibernates_after(pid, message) do
    await(pid, &match?({:call, {Item, :handle_info, [^message, _]}}, &1))
    await(pid, &match?({:return_from, {Item, :handle_info, 2}, {:noreply, _, :hibernate}}, &1))
    await(pid, &match?({:out, mfa} when mfa in @hibernated, &1))
  end

  # The trace of `pid`, in order, up to the first event that matches.
  defp await(pid, matches?) do
    event =
      receive do
        {:trace, ^pid, kind, what} -> {kind, what}
        {:trace, ^pid, kind, what, value} -> {kind, what, value}
      after
        5_000 -> flunk("#{inspect(pid)} did not get there")
      end

    if matches?.(event), do: :ok, else: await(pid, matches?)
  end
end
