defmodule AtlasTestAwaitTest do
  # Not async: the cleanup tests compare the trace sessions on a process.
  use ExUnit.Case, async: false

  require AtlasTestAwait, as: Await
  alias AtlasTestAwait.CapReached

  # A process the test controls: it sends `:tick` to the waiter's relay `n` times once told.
  defp ticker do
    spawn_link(fn ->
      receive do
        {:go, relay, n} -> for i <- 1..n, do: send(relay, {:tick, i})
      end

      receive do
        :never -> :ok
      end
    end)
  end

  defp subscribe_to(ticker, n, test \\ self()) do
    {:subscribe,
     fn ->
       send(test, {:relay, self()})
       send(ticker, {:go, self(), n})
     end}
  end

  defp counter, do: :counters.new(1, [])
  defp counted(counter, fun), do: fn -> :counters.add(counter, 1, 1) && fun.() end

  describe "exunit_options/1" do
    test "a bare assert_receive waits up to the cap" do
      assert Await.exunit_options()[:assert_receive_timeout] == Await.cap()
      assert Await.exunit_options(seed: 1)[:seed] == 1
      assert ExUnit.configuration()[:assert_receive_timeout] == Await.cap()
    end
  end

  describe "message/2" do
    test "returns the message and binds the pattern's variables" do
      expected = 7
      send(self(), {:reply, 7, :payload})
      assert {:reply, 7, :payload} = Await.message({:reply, ^expected, payload})
      assert payload == :payload
    end

    test "waits up to the cap, not ExUnit's default" do
      expanded = Macro.expand_once(quote(do: Await.message(:x, cap: 7)), __ENV__)

      assert {:__block__, _,
              [_opts, {{:., _, [assertions, :assert_receive]}, _, [_, timeout, _]}]} =
               expanded

      assert {:__aliases__, _, [:ExUnit, :Assertions]} = assertions
      assert {{:., _, [{:__aliases__, _, [:AtlasTestAwait]}, :cap]}, _, [_opts]} = timeout
    end

    test "on the cap, reports the mailbox and the caller's state" do
      send(self(), :unrelated)

      error =
        assert_raise CapReached, fn ->
          Await.message({:never, _}, cap: 1, state: fn -> :caller_state end)
        end

      assert error.cap == 1
      assert error.report.mailbox == [:unrelated]
      assert error.report.state == :caller_state
    end

    test "with report_only, the report comes back as the assertion's message" do
      error =
        assert_raise ExUnit.AssertionError, fn ->
          Await.message(:never, cap: 1, report_only: true)
        end

      assert is_binary(error.message)
    end
  end

  describe "down/2" do
    test "the reason of a process that ends (a held monitor), and of one already gone" do
      pid = spawn(fn -> receive(do: (:stop -> exit(:stopped))) end)
      ref = Process.monitor(pid)
      send(pid, :stop)
      assert Await.down(ref) == :stopped
      assert Await.down(pid) == :noproc
      assert Await.down(:atlas_test_await_absent) == :noproc
    end

    test "on the cap, reports the process" do
      pid = spawn(fn -> receive(do: (:never -> :ok)) end)
      error = assert_raise CapReached, fn -> Await.down(pid, cap: 1) end
      assert error.report.process[:status] == :waiting
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert Await.down(ref) == :killed
    end
  end

  describe "until/2 with a subscription" do
    test "checks once now and once per event, never on a timer" do
      ticks = :atomics.new(1, [])
      test = self()

      ticker =
        spawn_link(fn ->
          receive do
            {:go, relay} ->
              for i <- 1..3, do: :atomics.put(ticks, 1, i) && send(relay, {:tick, i})
          end
        end)

      checks = counter()

      # Read before releasing the ticks, so the first check cannot already see the last.
      check =
        counted(checks, fn ->
          value = :atomics.get(ticks, 1)

          if :counters.get(checks, 1) == 1,
            do: send(ticker, {:go, Await.message({:relay, relay}) && relay})

          value == 3
        end)

      assert Await.until(check, wake: {:subscribe, fn -> send(test, {:relay, self()}) end})
      assert :counters.get(checks, 1) in 2..4
    end

    test "stops its relay" do
      test = self()

      assert Await.until(fn -> true end,
               wake: {:subscribe, fn -> send(test, {:relay, self()}) end}
             )

      assert_received {:relay, relay}
      refute Process.alive?(relay)
    end

    test "returns the first truthy value" do
      ticker = ticker()
      flag = :atomics.new(1, [])
      ref = make_ref()

      value =
        Await.until(fn -> :atomics.get(flag, 1) == 1 && ref end,
          wake: {:subscribe, fn -> send(ticker, {:go, self(), 1}) && :atomics.put(flag, 1, 1) end}
        )

      assert value == ref
    end

    test "leaves no event in the test's mailbox" do
      ticker = ticker()
      Await.events(2, wake: subscribe_to(ticker, 5))
      assert_received {:relay, _}
      assert {:messages, []} = Process.info(self(), :messages)
    end

    test "a subscription that fails, fails the wait with its reason" do
      error =
        assert_raise CapReached, fn ->
          Await.until(fn -> false end, wake: {:subscribe, fn -> exit(:refused) end})
        end

      assert {{:subscribe, _}, :refused} = error.report.ended
    end

    test "on the cap, reports the last value, the checks and the events" do
      ticker = ticker()

      error =
        assert_raise CapReached, fn ->
          Await.until(fn -> nil end, wake: subscribe_to(ticker, 2), cap: 1)
        end

      assert error.report.last == nil
      assert error.report.checks >= 1
      assert [{{:subscribe, _}, %{alive: true}}] = error.report.sources
    end

    test "needs wake sources" do
      assert_raise ArgumentError, fn -> Await.until(fn -> true end, []) end
      assert_raise ArgumentError, fn -> Await.until(fn -> true end, wake: :clock) end
    end
  end

  describe "until/2 tracing a process" do
    test "rechecks after the process has handled what it received, not on its own calls" do
      {:ok, agent} = Agent.start_link(fn -> 0 end)
      test = self()

      updater =
        spawn_link(fn ->
          # Each update is a moment of work, during which a waiter woken by its own calls
          # would spin through many checks.
          receive(
            do: (:go ->
                   for(_ <- 1..3, do: Enum.sum(1..300_000) && Agent.update(agent, &(&1 + 1))))
          )

          send(test, :updated)
        end)

      checks = counter()

      check =
        counted(checks, fn ->
          # Read before releasing the updates, while still calling the traced process.
          value = Agent.get(agent, & &1)
          if :counters.get(checks, 1) == 1, do: send(updater, :go)
          value == 3
        end)

      assert Await.until(check, wake: {:trace, agent})
      # Once now, then at most once per update.
      assert :counters.get(checks, 1) in 2..4
      assert_receive :updated
      assert {:messages, []} = Process.info(self(), :messages)
      assert :trace.session_info(agent) in [:undefined, []]
    end

    test "the waiter's own calls and barriers to the process are no event" do
      {:ok, agent} = Agent.start_link(fn -> 0 end)
      checks = counter()

      # The first check casts once to the agent: one event, one barrier, one more check. The
      # check calls the agent each time and never holds; nothing else touches the agent, so
      # no further event may come, from the check's calls or from the barrier's.
      check =
        counted(checks, fn ->
          if :counters.get(checks, 1) == 1, do: Agent.cast(agent, & &1)
          Agent.get(agent, & &1) == :never
        end)

      error =
        assert_raise CapReached, fn -> Await.until(check, wake: {:trace, agent}, cap: 50) end

      assert {error.report.checks, error.report.events} == {2, 1}
    end

    test "checks after the process has handled the message, not when it arrives" do
      {:ok, agent} = Agent.start_link(fn -> :ok end)
      done = :atomics.new(1, [])
      checks = counter()

      # One cast after the first check, whose handling takes a moment and then writes what the
      # check reads (not through the agent): without the barrier, the second check would run
      # while the cast is handled, see 0, and no event would follow.
      check =
        counted(checks, fn ->
          if :counters.get(checks, 1) == 1,
            do:
              Agent.cast(agent, fn s ->
                Enum.reduce(1..300_000, 0, &+/2) && :atomics.put(done, 1, 1) && s
              end)

          :atomics.get(done, 1) == 1
        end)

      assert Await.until(check, wake: {:trace, agent}) == true
      assert :counters.get(checks, 1) == 2
    end

    test "the end of the process is an event" do
      {:ok, agent} = Agent.start(fn -> 0 end)

      # The trace starts first; the relay's subscription then stops the agent.
      assert [{:down, ^agent, :normal}] =
               Await.events(1,
                 wake: [[{:trace, agent}], {:subscribe, fn -> Agent.stop(agent) end}],
                 match: &match?({:down, _, _}, &1)
               )
    end

    test "on the cap, reports the watched process and its state" do
      {:ok, agent} = Agent.start_link(fn -> :held end)

      error =
        assert_raise CapReached, fn ->
          Await.until(fn -> false end, wake: {:trace, agent}, cap: 1)
        end

      assert [{{:trace, ^agent}, process}] = error.report.sources
      assert process[:state] == :held
      assert process[:status] in [:waiting, :runnable, :running]
    end

    test "a registered name is resolved, an unknown one refused" do
      {:ok, agent} = Agent.start_link(fn -> 1 end, name: :atlas_test_await_agent)

      assert Await.until(fn -> Agent.get(agent, & &1) end,
               wake: {:trace, :atlas_test_await_agent}
             ) == 1

      assert_raise ArgumentError, fn -> Await.until(fn -> true end, wake: {:trace, :absent}) end
    end
  end

  describe "events/2" do
    test "the first matching events, in order" do
      ticker = ticker()

      assert Await.events(2,
               wake: subscribe_to(ticker, 5),
               match: &match?({:tick, i} when i > 1, &1)
             ) ==
               [{:tick, 2}, {:tick, 3}]
    end

    test "zero events is no wait" do
      assert Await.events(0, wake: {:subscribe, fn -> :ok end}) == []
    end

    test "on the cap, reports how many matched" do
      ticker = ticker()

      error =
        assert_raise CapReached, fn -> Await.events(9, wake: subscribe_to(ticker, 2), cap: 1) end

      assert {:matched, n} = error.report.last
      assert n in 0..2
    end
  end
end
