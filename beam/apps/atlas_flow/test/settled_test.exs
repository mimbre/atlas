defmodule AtlasFlow.SettledTest do
  # Flow's settled position (docs/design/page-freshness.md §2.1): by itself, and as the
  # engine keeps it and answers `_settled` over the Bus. No time passes but the manual
  # clock's.
  use ExUnit.Case, async: false

  alias AtlasBus.Envelope
  alias AtlasFlow.{Engine, FakeFacts, ManualClock, Settled, Talk}

  describe "the settled position" do
    test "nothing seen: settled at 0, and a waiter for 0 is answered at once" do
      assert Settled.value(Settled.new()) == 0
      assert {[{:w, 0}], _} = Settled.wait(Settled.new(), 0, :w)
    end

    test "the frontier waits for every process the hint poked" do
      {[], s} = Settled.hint(Settled.new(), 5, [:a, :b])
      assert Settled.value(s) == 4
      {[], s} = Settled.wait(s, 5, :w)
      {[], s} = Settled.looked(s, :a, 5, nil)
      assert Settled.value(s) == 4 and Settled.holds?(s, :b) and not Settled.holds?(s, :a)
      assert {[{:w, 5}], s} = Settled.looked(s, :b, 5, nil)
      assert Settled.value(s) == 5
    end

    test "what a process wrote for its look advances it" do
      {[], s} = Settled.hint(Settled.new(), 5, [:a])
      {[], s} = Settled.wait(s, 7, :w)
      assert {[{:w, 7}], s} = Settled.looked(s, :a, 5, 7)
      assert Settled.value(s) == 7
    end

    test "a hint that pokes nothing is settled at once; a waiter is answered when reached" do
      {[], s} = Settled.wait(Settled.new(), 3, :w)
      {[], s} = Settled.seen(s, 2)
      assert Settled.value(s) == 2
      assert {[{:w, 3}], s} = Settled.hint(s, 3, [])
      assert s.waiters == []
    end

    test "a look answers the tickets it had, not a later one" do
      {[], s} = Settled.hint(Settled.new(), 3, [:a])
      {[], s} = Settled.hint(s, 6, [:a])
      {[], s} = Settled.looked(s, :a, 3, nil)
      assert Settled.value(s) == 5
      assert {[], s} = Settled.looked(s, :a, 6, nil)
      assert Settled.value(s) == 6
    end

    test "waiters are bounded: one too many answers the oldest now, with the value as it is" do
      assert Settled.new().most == 256
      {[], s} = Settled.hint(Settled.new(most: 2), 5, [:a])
      {[], s} = Settled.wait(s, 5, :w1)
      {[], s} = Settled.wait(s, 6, :w2)

      # A third: the oldest is told how far Flow is, below what it waits for; the others wait.
      assert {[{:w1, 4}], s} = Settled.wait(s, 7, :w3)
      assert s.waiters == [{6, :w2}, {7, :w3}]

      # One answered at once does not count against the bound.
      assert {[{:w4, 4}], s} = Settled.wait(s, 3, :w4)
      assert length(s.waiters) == 2

      # A Flow that never settles keeps at most the bound, however many ask.
      s = Enum.reduce(1..100, s, fn n, s -> elem(Settled.wait(s, 10 + n, n), 1) end)
      assert length(s.waiters) == 2
      # Once it settles, those left are answered as before.
      assert {[{99, 200}, {100, 200}], _} = Settled.looked(s, :a, 5, 200)
    end

    test "a report before its hint, or of a process that is gone, holds nothing back" do
      # The report raced ahead of the hint it answers: the write still counts.
      {[], s} = Settled.looked(Settled.new(), :a, 4, 5)
      assert Settled.value(s) == 5
      {[], s} = Settled.hint(s, 8, [:a, :b])
      {[], s} = Settled.wait(s, 8, :w)
      {[], s} = Settled.down(s, :a)
      assert {[{:w, 8}], _} = Settled.down(s, :b)
    end
  end

  describe "the engine" do
    setup do
      Application.put_env(:atlas_bus, :store, "settled-#{System.unique_integer([:positive])}")
      :ok = Supervisor.terminate_child(AtlasFlow.Root, AtlasFlow.Supervisor)
      {:ok, _} = Supervisor.restart_child(AtlasFlow.Root, AtlasFlow.Supervisor)
      start_supervised!({FakeFacts, description: AtlasFlow.Workshop.description()})
      FakeFacts.put("maker", %{"key" => "mia"})
      FakeFacts.put("widget", %{"key" => "W-1", "values" => %{"title" => "One"}})
      clock = start_supervised!({ManualClock, ~U[2026-11-12 00:00:00Z]})

      engine =
        start_supervised!(
          {Engine, every: 3_600_000, clock: {ManualClock, clock}, model: AtlasFlow.Workshop}
        )

      Engine.round(engine)
      [{item, _}] = Registry.lookup(AtlasFlow.Items, {"widget", "W-1"})
      # Its first look (sent in its init) is done, and the hints of what it wrote are seen.
      :sys.get_state(item)
      :sys.get_state(item)
      :sys.get_state(engine)
      assert FakeFacts.get("widget", "W-1")["values"]["todo"] == "Tend it"
      :ok = AtlasBus.attach("tester-#{System.unique_integer([:positive])}")

      on_exit(fn ->
        for {_, pid, _, _} <- DynamicSupervisor.which_children(AtlasFlow.Supervisor),
            do: DynamicSupervisor.terminate_child(AtlasFlow.Supervisor, pid)
      end)

      %{engine: engine, item: item, clock: clock}
    end

    defp ask(position) do
      request = %{Envelope.new("request", "_settled") | address: "flow"}
      :ok = AtlasBus.send(request, %{"position" => position})
      request.id
    end

    # Something the widget's flow reads changed behind it: its next look writes again.
    defp stale(key) do
      FakeFacts.put("widget", put_in(FakeFacts.get("widget", key), ["values", "todo"], "stale"))
    end

    test "a hint pokes the widget's process; it is settled once the process looked, past its write",
         c do
      stale("W-1")

      {:stored, p} =
        Talk.put("part", %{"op" => "create", "key" => "P-1", "links" => %{"of_widget" => ["W-1"]}})

      id = ask(p)
      # The engine has the hint and the question, the process its poke: nobody answers yet.
      :sys.get_state(c.engine)
      :sys.get_state(c.item)
      refute_received {:atlas_bus, %Envelope{id: ^id}, _}

      # The burst of hints settles: the process looks, writes, and reports.
      ManualClock.advance(c.clock, 50)

      assert_receive {:atlas_bus, %Envelope{id: ^id, class: "answer"}, %{"settled" => settled}},
                     1_000

      assert FakeFacts.get("widget", "W-1")["values"]["todo"] == "Tend it"
      assert settled == p + 1

      # Reached already: answered at once.
      id = ask(p)

      assert_receive {:atlas_bus, %Envelope{id: ^id, class: "answer"}, %{"settled" => ^settled}},
                     1_000
    end

    test "a hint that pokes no process is settled at once", c do
      {:stored, p} = Talk.put("maker", %{"op" => "change", "key" => "mia", "values" => %{}})
      id = ask(p)
      assert_receive {:atlas_bus, %Envelope{id: ^id, class: "answer"}, %{"settled" => ^p}}, 1_000
      assert Settled.value(:sys.get_state(c.engine).settled) == p
    end

    test "a poked process that is gone holds nothing back", c do
      {:stored, p} =
        Talk.put("part", %{"op" => "create", "key" => "P-2", "links" => %{"of_widget" => ["W-1"]}})

      id = ask(p)
      :sys.get_state(c.engine)
      refute_received {:atlas_bus, %Envelope{id: ^id}, _}
      Process.exit(c.item, :kill)

      assert_receive {:atlas_bus, %Envelope{id: ^id, class: "answer"}, %{"settled" => settled}},
                     1_000

      assert settled >= p
    end

    test "a question without a position is answered with why" do
      request = %{Envelope.new("request", "_settled") | address: "flow"}
      :ok = AtlasBus.send(request, %{})
      id = request.id
      assert_receive {:atlas_bus, %Envelope{id: ^id, class: "answer"}, %{"error" => _}}, 1_000
    end
  end
end
