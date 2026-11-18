defmodule AtlasTestAwait.CapReached do
  @moduledoc """
  A wait that reached its safety cap. `report` holds the diagnostic state as data: `:last`
  (the check's last value, or how many events matched), `:checks`, `:events`, `:recent`
  (newest first), `:ended` (a wake source that ended early), `:sources`, `:process`,
  `:mailbox` and the caller's `:state`.
  """
  defexception [:what, :cap, report: %{}]

  @impl true
  def message(%{what: what, cap: cap, report: report}) do
    body =
      Enum.map_join(report, "\n", fn {key, value} ->
        "  #{key}: " <> inspect(value, pretty: true, limit: 50, printable_limit: 4_096)
      end)

    "AtlasTestAwait: #{what} not reached within the #{cap} ms safety cap " <>
      "(the cap reports a hang; it decides nothing)\n" <> body
  end
end

defmodule AtlasTestAwait do
  @moduledoc """
  Waiting in tests on what happens, never on the clock.

  A test waits for a message (`message/2`), for a process to end (`down/2`), or for a
  condition that is re-checked on each real event of the system under test (`until/2`). It
  counts real events before a negative check (`events/2`). No wait sleeps or polls on a timer.

  Each wait has a safety cap (`cap/0`: 30 s, or `ATLAS_TEST_AWAIT_CAP_MS`, or `cap:`) that
  lies far beyond any healthy wait. The cap only turns a hang into a failure that carries the
  full diagnostic state: what was awaited, the last value of the check, the events seen, the
  watched processes and their state, the test's mailbox, and the caller's own `state:`. The
  cap never decides the outcome: a wait returns as soon as its event happens.

  ## Wake sources (`wake:`)

  These decide what re-runs a check (`until/2`) or what counts as an event (`events/2`).
  Give one or a list (nested lists are flattened).

  - `{:subscribe, fun}`: a relay process runs `fun`, a subscription made in the relay's own
    name (the work core's notifications, a Bus subscription and so on), and then forwards each
    message it receives as an event, as received. The test's own mailbox is left alone. An
    assertion inside `fun` that fails fails the wait.
  - `{:trace, process}`: each message that `process` (a pid or a registered name of an OTP
    process) receives is an event `{:received, pid, message}`, and its end is an event
    `{:down, pid, reason}`. The waiter's own calls and `:sys` requests to it are not events,
    so a check may call `process`. After each batch of events, a `:sys.get_state/2` barrier
    makes the check run once `process` has handled them. The trace has a session of its own
    (OTP 27+), so it works alongside any other tracer. A check that reaches `process` through
    a third process would wake itself: watch that third process instead, or subscribe.

  ## Negative checks

  Do not wait for nothing to happen. Wait for the events after which it would have happened,
  then assert that it did not:

      Await.events(3, wake: {:subscribe, subscribe}, match: &match?({:tick, _}, &1))
      refute_received {:started, _}
  """

  alias AtlasTestAwait.CapReached

  @default_cap 30_000
  @shown 10

  @doc "The safety cap in milliseconds: `ATLAS_TEST_AWAIT_CAP_MS`, else 30 000."
  def cap do
    case System.get_env("ATLAS_TEST_AWAIT_CAP_MS") do
      nil -> @default_cap
      value -> String.to_integer(value)
    end
  end

  @doc false
  def cap(opts), do: Keyword.get(opts, :cap, cap())

  @doc """
  Options for `ExUnit.start/1`: a bare `assert_receive` then waits up to the cap, as an event
  wait does, instead of ExUnit's 100 ms.
  """
  def exunit_options(extra \\ []), do: Keyword.merge([assert_receive_timeout: cap()], extra)

  @doc """
  `assert_receive` up to the cap; returns the message and binds the pattern's variables. On
  the cap it fails with the mailbox and the caller's `state:` (a 0-arity function).
  """
  defmacro message(pattern, opts \\ []) do
    label = Macro.to_string(pattern)

    quote do
      opts = unquote(opts)

      ExUnit.Assertions.assert_receive(
        unquote(pattern),
        AtlasTestAwait.cap(opts),
        AtlasTestAwait.__cap_reached__("a message matching #{unquote(label)}", opts, %{})
      )
    end
  end

  @doc """
  The exit reason of `target` (a pid, a registered name, or a monitor reference the caller
  already holds) once it is down. `:noproc` for a process already gone.
  """
  def down(target, opts \\ [])

  def down(ref, opts) when is_reference(ref), do: await_down(ref, nil, opts)

  def down(name, opts) when is_atom(name) do
    case Process.whereis(name) do
      nil -> :noproc
      pid -> down(pid, opts)
    end
  end

  def down(pid, opts) when is_pid(pid), do: await_down(Process.monitor(pid), pid, opts)

  defp await_down(ref, pid, opts) do
    receive do
      {:DOWN, ^ref, :process, _, reason} -> reason
    after
      cap(opts) ->
        Process.demonitor(ref, [:flush])

        __cap_reached__("the end of #{inspect(pid || ref)}", opts, %{
          process: if(pid, do: describe(pid), else: :monitor_reference)
        })
    end
  end

  @doc """
  The value of `check` (a 0-arity function) once it is truthy. It is checked once now and
  again after each event of `wake:` (required). Options: `wake:`, `cap:`, `label:`, `state:`.
  """
  def until(check, opts) when is_function(check, 0) do
    with_sources(opts, fn session ->
      loop_until(check, session, deadline(opts), %{checks: 0, events: 0, last: nil, recent: []})
    end)
  end

  defp loop_until(check, session, deadline, stats) do
    value = check.()
    stats = %{stats | checks: stats.checks + 1, last: value}

    if value not in [nil, false] do
      value
    else
      case next(session, deadline) do
        {:events, events} ->
          barrier(session, deadline)
          loop_until(check, session, deadline, seen(stats, events))

        stop ->
          fail(stop, "the condition #{label(session.opts, check)}", session, stats)
      end
    end
  end

  @doc """
  The first `count` events of `wake:` (required) that `match:` (default: every event)
  accepts, in order, once the watched processes have handled them. Options: `wake:`,
  `match:`, `cap:`, `label:`, `state:`.
  """
  def events(count, opts) when is_integer(count) and count >= 0 do
    match = Keyword.get(opts, :match, fn _ -> true end)

    with_sources(opts, fn session ->
      stats = %{checks: 0, events: 0, last: [], recent: []}
      collect(session, count, match, deadline(opts), stats)
    end)
  end

  defp collect(session, count, _match, deadline, %{last: matched})
       when length(matched) >= count do
    barrier(session, deadline)
    Enum.reverse(matched)
  end

  defp collect(session, count, match, deadline, stats) do
    case next(session, deadline) do
      {:events, events} ->
        stats = seen(stats, events)
        matched = Enum.reduce(events, stats.last, &if(match.(&1), do: [&1 | &2], else: &2))
        collect(session, count, match, deadline, %{stats | last: Enum.take(matched, -count)})

      stop ->
        what = "#{count} event(s)#{if label = session.opts[:label], do: " (#{label})"}"
        fail(stop, what, session, %{stats | last: {:matched, length(stats.last)}})
    end
  end

  # Sources: relays and tracers, each its own process, stopped and flushed after the wait.

  defp with_sources(opts, fun) do
    wake = Keyword.get(opts, :wake) || raise ArgumentError, "a wait needs `wake:` sources"
    ref = make_ref()
    session = %{ref: ref, opts: opts, sources: []}

    try do
      session = Enum.reduce(List.flatten([wake]), session, &start_source(&1, &2, opts))
      fun.(session)
    after
      stop_sources(ref)
    end
  end

  defp start_source({:subscribe, fun}, session, opts) when is_function(fun, 0),
    do: start(session, {:subscribe, fun}, opts, fn waiter, ref -> relay(waiter, ref, fun) end)

  defp start_source({:trace, process}, session, opts) do
    pid =
      case process do
        pid when is_pid(pid) -> pid
        name -> GenServer.whereis(name) || raise(ArgumentError, "no process #{inspect(name)}")
      end

    start(session, {:trace, pid}, opts, fn waiter, ref -> tracer(waiter, ref, pid) end)
  end

  defp start_source(other, _session, _opts),
    do: raise(ArgumentError, "unknown wake source #{inspect(other)}")

  defp start(session, source, opts, body) do
    waiter = self()
    ref = session.ref
    # Atomically: a source that fails at once still reports its own reason.
    {pid, monitor} = spawn_monitor(fn -> body.(waiter, ref) end)
    Process.put({__MODULE__, ref}, [{pid, monitor} | Process.get({__MODULE__, ref}, [])])

    receive do
      {^ref, :ready, ^pid} ->
        %{session | sources: session.sources ++ [%{source: source, pid: pid, monitor: monitor}]}

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        Process.put(
          {__MODULE__, ref},
          List.delete(Process.get({__MODULE__, ref}), {pid, monitor})
        )

        __cap_reached__("the start of #{inspect(source)}", opts, %{ended: {source, reason}})
    after
      # Starting a source is the helper's own work, not the awaited outcome: the full cap
      # even when the wait itself was given a shorter one.
      max(cap(opts), cap()) -> __cap_reached__("the start of #{inspect(source)}", opts, %{})
    end
  end

  defp relay(waiter, ref, fun) do
    watch = Process.monitor(waiter)
    fun.()
    send(waiter, {ref, :ready, self()})
    relay_loop(waiter, ref, watch)
  end

  defp relay_loop(waiter, ref, watch) do
    receive do
      {:DOWN, ^watch, :process, ^waiter, _} -> :ok
      message -> send(waiter, {ref, :event, message}) && relay_loop(waiter, ref, watch)
    end
  end

  defp tracer(waiter, ref, target) do
    watch = Process.monitor(waiter)
    watched = Process.monitor(target)
    session = :trace.session_create(__MODULE__, self(), [])
    :trace.process(session, target, true, [:receive])
    send(waiter, {ref, :ready, self()})
    tracer_loop(waiter, ref, target, {watch, watched}, session)
  end

  defp tracer_loop(waiter, ref, target, {watch, watched} = monitors, session) do
    receive do
      {:trace, ^target, :receive, message} ->
        unless from?(message, waiter),
          do: send(waiter, {ref, :event, {:received, target, message}})

        tracer_loop(waiter, ref, target, monitors, session)

      {:DOWN, ^watched, :process, ^target, reason} ->
        send(waiter, {ref, :event, {:down, target, reason}})
        tracer_loop(waiter, ref, target, monitors, session)

      {:DOWN, ^watch, :process, ^waiter, _} ->
        :trace.session_destroy(session)
    end
  end

  # The waiter's own calls and `:sys` requests (its check, its barrier) are no event.
  defp from?({:"$gen_call", {pid, _}, _}, pid), do: true
  defp from?({:system, {pid, _}, _}, pid), do: true
  defp from?(_, _), do: false

  defp stop_sources(ref) do
    sources = Process.delete({__MODULE__, ref}) || []

    for {pid, monitor} <- sources do
      # A relay may still be inside its subscription, so a source is killed, not asked. Its
      # `DOWN` comes after every event it sent, so the flush below leaves none behind; a
      # killed tracer's trace session goes with it.
      Process.exit(pid, :kill)

      receive do
        {:DOWN, ^monitor, :process, ^pid, _} -> :ok
      end
    end

    flush(ref)
  end

  defp flush(ref) do
    receive do
      {^ref, :event, _} -> flush(ref)
    after
      0 -> :ok
    end
  end

  # The next batch of events: the first to arrive, then every one already queued.
  defp next(session, deadline) do
    ref = session.ref
    monitors = Map.new(session.sources, &{&1.monitor, &1.source})

    receive do
      {^ref, :event, event} ->
        {:events, drain(ref, [event])}

      {:DOWN, monitor, :process, _, reason} when is_map_key(monitors, monitor) ->
        {:source_down, monitors[monitor], reason}
    after
      remaining(deadline) -> :cap
    end
  end

  defp drain(ref, events) do
    receive do
      {^ref, :event, event} -> drain(ref, [event | events])
    after
      0 -> Enum.reverse(events)
    end
  end

  # Once each watched process has handled what it received so far.
  defp barrier(session, deadline) do
    for %{source: {:trace, pid}} <- session.sources, Process.alive?(pid) do
      try do
        :sys.get_state(pid, max(remaining(deadline), 1))
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  defp seen(stats, events),
    do: %{
      stats
      | events: stats.events + length(events),
        recent: Enum.take(Enum.reverse(events) ++ stats.recent, @shown)
    }

  # Failure: everything a reader needs to tell a hang from a product bug.

  defp fail(stop, what, session, stats) do
    ended =
      case stop do
        :cap -> %{}
        {:source_down, source, reason} -> %{ended: {source, reason}}
      end

    __cap_reached__(
      what,
      session.opts,
      Map.merge(ended, %{
        last: stats.last,
        checks: stats.checks,
        events: stats.events,
        recent: stats.recent,
        sources: Enum.map(session.sources, &{&1.source, describe_source(&1)})
      })
    )
  end

  defp describe_source(%{source: {:trace, pid}}), do: describe(pid)
  defp describe_source(%{pid: relay}), do: %{relay: relay, alive: Process.alive?(relay)}

  defp describe(pid) do
    info =
      Process.info(pid, [
        :registered_name,
        :status,
        :message_queue_len,
        :current_stacktrace,
        :dictionary
      ])

    case info do
      nil ->
        :not_alive

      info ->
        state =
          try do
            :sys.get_state(pid, 1_000)
          catch
            :exit, reason -> {:unavailable, reason}
          end

        info
        |> Keyword.update!(:dictionary, &Keyword.take(&1, [:"$initial_call", :"$ancestors"]))
        |> Keyword.put(:state, state)
    end
  end

  @doc false
  def __cap_reached__(what, opts, report) do
    {:messages, mailbox} = Process.info(self(), :messages)

    state =
      case opts[:state] do
        nil ->
          %{}

        fun ->
          try do
            %{state: fun.()}
          rescue
            error -> %{state: {:raised, error}}
          end
      end

    report = report |> Map.put(:mailbox, Enum.take(mailbox, @shown)) |> Map.merge(state)
    exception = CapReached.exception(what: what, cap: cap(opts), report: report)

    # `message/2` hands this call to `assert_receive` as its failure message, which must
    # type as a string: with `report_only: true` the report comes back as text instead.
    if Keyword.get(opts, :report_only, false),
      do: Exception.message(exception),
      else: raise(exception)
  end

  defp label(opts, check), do: opts[:label] || inspect(check)

  defp deadline(opts), do: System.monotonic_time(:millisecond) + cap(opts)
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
end
