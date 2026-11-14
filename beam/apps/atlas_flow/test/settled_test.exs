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

    test "a waiter is answered once a position at or past its own is seen, in any order" do
      {[], s} = Settled.wait(Settled.new(), 3, :w)
      {[], s} = Settled.seen(s, 2)
      assert Settled.value(s) == 2
      assert {[{:w, 7}], s} = Settled.seen(s, 7)
      # An earlier position seen later keeps the value.
      {[], s} = Settled.seen(s, 5)
      assert Settled.value(s) == 7 and s.waiters == []
    end

    test "a handled hint settles through Flow's own writes that follow it, up to a gap" do
      {[], s} = Settled.wait(Settled.new(), 6, :w)
      # Flow wrote 6 and 7 for the hint at 5: no one else wrote in between.
      assert {[{:w, 7}], s} = Settled.handled(s, 5, [6, 7])
      assert Settled.value(s) == 7

      # Someone else stored 9 after the hint at 8, before Flow's write at 10: its hint is
      # not handled yet, so the settled position stops at 8; 10's own hint comes after 9's.
      {[], s} = Settled.wait(s, 9, :later)
      {[], s} = Settled.handled(s, 8, [10])
      assert Settled.value(s) == 8
      assert {[{:later, 9}], s} = Settled.handled(s, 9, [])
      assert {[], s} = Settled.seen(s, 10)
      assert Settled.value(s) == 10

      # Nothing written: the hint's own position.
      assert {[], s} = Settled.handled(s, 11, [])
      assert Settled.value(s) == 11
    end

    test "a held hint keeps the value below it, whatever follows, until it is released" do
      {[], s} = Settled.seen(Settled.new(), 4)
      {[], s} = Settled.wait(s, 5, :w)
      # The hint at 5 was looked at, but its runs were not reconciled.
      assert {[], s} = Settled.hold(s, 5)
      assert Settled.value(s) == 4
      # Later hints, and Flow's writes for them, are looked at, but do not pass it.
      assert {[], s} = Settled.handled(s, 6, [7])
      assert {[], s} = Settled.seen(s, 8)
      assert Settled.value(s) == 4
      # A round reconciled every run: settled through all that was looked at.
      assert {[{:w, 8}], s} = Settled.release(s)
      assert Settled.value(s) == 8
      assert {[], s} = Settled.handled(s, 9, [])
      assert Settled.value(s) == 9
    end

    test "waiters are bounded: one too many answers the oldest now, with the value as it is" do
      assert Settled.new().most == 256
      {[], s} = Settled.seen(Settled.new(most: 2), 4)
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
      assert {[{99, 200}, {100, 200}], _} = Settled.seen(s, 200)
    end
  end

  describe "the engine" do
    setup do
      Application.put_env(:atlas_bus, :store, "settled-#{System.unique_integer([:positive])}")
      start_supervised!({FakeFacts, description: AtlasFlow.Workshop.description()})
      FakeFacts.put("maker", %{"key" => "mia"})
      FakeFacts.put("widget", %{"key" => "W-1", "values" => %{"title" => "One"}})
      clock = start_supervised!({ManualClock, ~U[2026-11-12 00:00:00Z]})

      engine =
        start_supervised!(
          {Engine, every: 3_600_000, clock: {ManualClock, clock}, model: AtlasFlow.Workshop}
        )

      Engine.round(engine)
      assert FakeFacts.get("widget", "W-1")["values"]["todo"] == "Tend it"
      :ok = AtlasBus.attach("tester-#{System.unique_integer([:positive])}")
      %{engine: engine, clock: clock}
    end

    defp ask(position) do
      request = %{Envelope.new("request", "_settled") | address: "flow"}
      :ok = AtlasBus.send(request, %{"position" => position})
      request.id
    end

    # Something the widget's subflow presents changed behind it: its next projection
    # writes again.
    defp stale(key) do
      FakeFacts.put("widget", put_in(FakeFacts.get("widget", key), ["values", "todo"], "stale"))
    end

    test "a hint is settled once what it is about was projected, past the write it made", c do
      stale("W-1")

      {:stored, p} =
        Talk.put("part", %{"op" => "create", "key" => "P-1", "links" => %{"of_widget" => ["W-1"]}})

      id = ask(p)

      assert_receive {:atlas_bus, %Envelope{id: ^id, class: "answer"}, %{"settled" => settled}},
                     1_000

      assert FakeFacts.get("widget", "W-1")["values"]["todo"] == "Tend it"
      assert settled == p + 1
      assert Settled.value(:sys.get_state(c.engine).settled) == settled

      # Reached already: answered at once.
      id = ask(p)

      assert_receive {:atlas_bus, %Envelope{id: ^id, class: "answer"}, %{"settled" => ^settled}},
                     1_000
    end

    test "a hint about nothing presented is settled at its own position", c do
      {:stored, p} = Talk.put("maker", %{"op" => "change", "key" => "mia", "values" => %{}})
      id = ask(p)
      assert_receive {:atlas_bus, %Envelope{id: ^id, class: "answer"}, %{"settled" => ^p}}, 1_000
      assert Settled.value(:sys.get_state(c.engine).settled) == p
    end

    for failure <- [:owner_read, :subject_read, :write] do
      test "#{failure}: settlement waits through failed recovery and later hints", c do
        {block, unblock} = projection_failure(unquote(failure))

        GenServer.call(FakeFacts, block)

        {:stored, p} =
          Talk.put("widget", %{"op" => "create", "key" => "W-2", "values" => %{"title" => "Two"}})

        id = ask(p)
        :sys.get_state(c.engine)
        refute_received {:atlas_bus, %Envelope{id: ^id}, _}
        assert FakeFacts.get("widget", "W-2")["values"]["todo"] == nil

        # Reconciliation succeeds on a round, but its required projection still fails.
        Engine.round(c.engine)
        :sys.get_state(c.engine)
        refute_received {:atlas_bus, %Envelope{id: ^id}, _}

        {:stored, q} = Talk.put("maker", %{"op" => "change", "key" => "mia", "values" => %{}})
        :sys.get_state(c.engine)
        refute_received {:atlas_bus, %Envelope{id: ^id}, _}

        GenServer.call(FakeFacts, unblock)
        Engine.round(c.engine)

        assert_receive {:atlas_bus, %Envelope{id: ^id, class: "answer"}, %{"settled" => settled}},
                       1_000

        assert settled >= q
        fact = FakeFacts.get("widget", "W-2")
        assert fact["values"]["todo"] == "Tend it"
        assert fact["links"]["tended_by"] == ["mia"]
      end
    end

    defp projection_failure(:owner_read),
      do: {{:busy, "maker", "mia"}, {:free, "maker", "mia"}}

    defp projection_failure(:subject_read) do
      read = %{"key" => "W-2", "incoming" => false}
      {{:block_read, "widget", read}, {:allow_read, "widget", read}}
    end

    defp projection_failure(:write),
      do: {{:refuse_write, "widget", "W-2"}, {:allow_write, "widget", "W-2"}}

    test "a recovery list failure cannot release a held input; unchanged projections can", c do
      read = %{"key" => "W-1", "incoming" => false}
      GenServer.call(FakeFacts, {:block_read, "widget", read})
      stale("W-1")
      {:stored, p} = Talk.put("widget", %{"op" => "change", "key" => "W-1", "values" => %{}})
      id = ask(p)
      :sys.get_state(c.engine)
      refute_received {:atlas_bus, %Envelope{id: ^id}, _}

      GenServer.call(FakeFacts, {:allow_read, "widget", read})
      # A later hint repairs the fact, but only a complete round can release the hold.
      {:stored, q} = Talk.put("widget", %{"op" => "change", "key" => "W-1", "values" => %{}})
      :sys.get_state(c.engine)
      assert FakeFacts.get("widget", "W-1")["values"]["todo"] == "Tend it"
      GenServer.call(FakeFacts, {:block_read, "widget", %{}})
      Engine.round(c.engine)
      :sys.get_state(c.engine)
      refute_received {:atlas_bus, %Envelope{id: ^id}, _}

      GenServer.call(FakeFacts, {:allow_read, "widget", %{}})
      writes = FakeFacts.sent()
      Engine.round(c.engine)

      assert_receive {:atlas_bus, %Envelope{id: ^id, class: "answer"}, %{"settled" => settled}},
                     1_000

      assert settled >= q
      assert FakeFacts.sent() == writes
    end

    test "a lost projection acknowledgement holds until the stored projection is read back", c do
      stale("W-1")
      GenServer.call(FakeFacts, {:lose_ack, "widget"})

      {:stored, p} =
        Talk.put("part", %{
          "op" => "create",
          "key" => "P-lost",
          "links" => %{"of_widget" => ["W-1"]}
        })

      id = ask(p)
      :sys.get_state(c.engine)
      refute_received {:atlas_bus, %Envelope{id: ^id}, _}
      assert FakeFacts.get("widget", "W-1")["values"]["todo"] == "Tend it"
      writes = FakeFacts.sent()
      Engine.round(c.engine)

      assert_receive {:atlas_bus, %Envelope{id: ^id, class: "answer"}, %{"settled" => settled}},
                     1_000

      assert settled >= p
      assert FakeFacts.sent() == writes
    end

    test "an unchanged required projection settles its input without another write", c do
      writes = length(FakeFacts.sent())
      {:stored, p} = Talk.put("widget", %{"op" => "change", "key" => "W-1", "values" => %{}})
      id = ask(p)
      assert_receive {:atlas_bus, %Envelope{id: ^id, class: "answer"}, %{"settled" => ^p}}, 1_000
      assert length(FakeFacts.sent()) == writes + 1
      :sys.get_state(c.engine)
    end

    test "an explicitly absent owner settles the expected work and waits for owner creation", c do
      GenServer.call(FakeFacts, {:drop, "maker", "mia"})
      {:stored, p} = Talk.put("widget", %{"op" => "create", "key" => "W-absent", "values" => %{}})
      id = ask(p)

      assert_receive {:atlas_bus, %Envelope{id: ^id, class: "answer"}, %{"settled" => settled}},
                     1_000

      assert settled >= p
      fact = FakeFacts.get("widget", "W-absent")
      assert fact["values"]["todo"] == "Tend it"
      assert fact["links"]["tended_by"] == nil

      {:stored, q} = Talk.put("maker", %{"op" => "create", "key" => "mia", "values" => %{}})
      id = ask(q)

      assert_receive {:atlas_bus, %Envelope{id: ^id, class: "answer"}, %{"settled" => recovered}},
                     1_000

      assert recovered >= q
      assert FakeFacts.get("widget", "W-absent")["links"]["tended_by"] == ["mia"]
      :sys.get_state(c.engine)
    end

    test "a hint whose runs could not be reconciled is settled only by the next round", c do
      # Facts cannot read the new widget yet: its run is not reconciled on the hint.
      GenServer.call(FakeFacts, {:busy, "widget", "W-2"})

      {:stored, p} =
        Talk.put("widget", %{"op" => "create", "key" => "W-2", "values" => %{"title" => "Two"}})

      id = ask(p)
      state = :sys.get_state(c.engine)
      refute_received {:atlas_bus, %Envelope{id: ^id}, _}
      assert Settled.value(state.settled) < p
      assert FakeFacts.get("widget", "W-2")["values"]["todo"] == nil

      # A later hint that reconciles is looked at, but does not settle past the held one.
      GenServer.call(FakeFacts, {:free, "widget", "W-2"})
      {:stored, q} = Talk.put("maker", %{"op" => "change", "key" => "mia", "values" => %{}})
      state = :sys.get_state(c.engine)
      refute_received {:atlas_bus, %Envelope{id: ^id}, _}
      assert Settled.value(state.settled) < p

      # The next round reconciles every run: the waiter is answered, with the effect applied.
      ManualClock.advance(c.clock, 3_600_000)
      :sys.get_state(c.engine)

      assert_receive {:atlas_bus, %Envelope{id: ^id, class: "answer"}, %{"settled" => settled}},
                     1_000

      assert settled >= q
      assert FakeFacts.get("widget", "W-2")["values"]["todo"] == "Tend it"
    end

    test "a question without a position is answered with why" do
      request = %{Envelope.new("request", "_settled") | address: "flow"}
      :ok = AtlasBus.send(request, %{})
      id = request.id
      assert_receive {:atlas_bus, %Envelope{id: ^id, class: "answer"}, %{"error" => _}}, 1_000
    end
  end
end
