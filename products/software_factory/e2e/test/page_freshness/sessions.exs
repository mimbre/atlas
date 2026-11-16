# What Control's sessions of the TUIs send and whether they are done handling hints: loaded
# into the core's own node by proof.exs, never into the e2e project.
defmodule PageFreshness.Sessions do
  @moduledoc """
  The Control sessions of the TUIs, watched from inside the core: every message a session
  writes to its TUI (traced, as `products/software_factory/integration/settle_submit.exs` traces Facts'
  answers), and whether it has handled every hint it got.
  """
  alias AtlasControl.Freshness.{Batch, Marks}

  @doc "The sessions of TUIs of `user` (its `tui_user`) that have said hello."
  def of(user) do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(AtlasControl.Sessions),
        state = state(pid),
        is_map(state) and state.hello and state.by == user,
        do: pid
  end

  @doc "Wait, at most `within` ms, until exactly one session of `user` is not in `known`."
  def new(user, known, within) do
    wait(within, "find one new TUI session of #{user}", fn ->
      case of(user) -- known do
        [pid] -> pid
        _ -> nil
      end
    end)
  end

  @doc "Record every message `sessions` send to their TUIs from now on."
  def watch(sessions) do
    tracer = spawn(fn -> collect([]) end)
    :erlang.trace_pattern({:gen_tcp, :send, 2}, true, [:global])

    :erlang.trace_pattern(
      {AtlasControl.Session, :handle_info, 2},
      [{[{:atlas_bus, %{class: "answer", kind: "_settled"}, :_}, :_], [], []}],
      [:global]
    )

    for pid <- sessions,
        do: :erlang.trace(pid, true, [:call, :monotonic_timestamp, {:tracer, tracer}])

    tracer
  end

  @doc "Ordered events after the VM delivered its trace and the collector consumed it."
  def events(tracer, session) do
    delivered = :erlang.trace_delivered(session)

    receive do
      {:trace_delivered, ^session, ^delivered} -> :ok
    after
      5_000 -> raise "Control's session trace was not delivered"
    end

    ref = make_ref()
    send(tracer, {:events, self(), ref})

    receive do
      {^ref, all} -> for {^session, event} <- all, do: event
    after
      5_000 -> raise "the trace of Control's sessions did not answer"
    end
  end

  @doc "A drained sequence boundary, independent of clock resolution or collector scheduling."
  def cursor(tracer, session),
    do: events(tracer, session) |> List.last() |> then(&if(&1, do: &1.sequence, else: 0))

  @doc "What `session` sent since `since` (`now/0`): VM event time in ms, never collection time."
  def sent(tracer, session, since) do
    for %{type: "send", at: at, message: message} <- events(tracer, session),
        ms = System.convert_time_unit(at, :native, :millisecond),
        ms >= since,
        do: {ms, message}
  end

  @doc """
  Classify every page in same-session event order. Session accepts any integer
  _settled answer, even with an old id, clearing covered marks before it sends.
  Page position/reason and the final session state never establish coverage.
  """
  def frames(events, position) do
    {frames, _} =
      Enum.map_reduce(events, nil, fn event, coverage ->
        coverage =
          if event.type == "coverage" do
            [coverage, event.reported]
            |> Enum.filter(&is_integer/1)
            |> Enum.max(fn -> nil end)
          else
            coverage
          end

        phase = if is_integer(coverage) and coverage >= position, do: "covered", else: "pending"
        {Map.merge(event, %{coverage: coverage, phase: phase}), coverage}
      end)

    frames
  end

  @doc "Full ledger, including non-page sends and invalid/uncovering coverage answers."
  def ledger(tracer, session, cursor, position) do
    events(tracer, session) |> frames(position) |> Enum.filter(&(&1.sequence > cursor))
  end

  @doc "Every event in order, with page identities/flags, retained in the core proof output."
  def evidence(ledger) do
    Enum.map(ledger, fn
      %{type: "send", message: message} = event ->
        event
        |> Map.delete(:message)
        |> Map.put(:message, Map.take(message, ~w(op path reason position)))
        |> Map.put(:rows, rows(message))

      event ->
        event
    end)
  end

  @doc "All assigned-list frames: both phases, retained pending row, then exact remaining order."
  def assert_marker_frames(ledger, before, changed) do
    import ExUnit.Assertions

    lists =
      for %{type: "send", message: %{"op" => "page", "path" => "/"}} = frame <- ledger, do: frame

    assert Enum.any?(lists, &(&1.phase == "pending"))
    assert Enum.any?(lists, &(&1.phase == "covered"))

    for %{phase: phase, message: page} <- lists do
      if phase == "pending" do
        assert Map.put(changed, :pending, true) in rows(page)
      else
        refute changed.key in Enum.map(rows(page), & &1.key)
        refute Enum.any?(rows(page), & &1.pending)
        assert Enum.map(rows(page), & &1.key) == before -- [changed.key]
      end
    end
  end

  @doc "The pages `session` sent since `since`."
  def pages(tracer, session, since),
    do: for({_, %{"op" => "page"} = page} <- sent(tracer, session, since), do: page)

  @doc "The pages `session` sent by itself (a hint or a marker) since `since`: its pushes."
  def pushes(tracer, session, since),
    do:
      for(page <- pages(tracer, session, since), page["reason"] in ["hint", "pending"], do: page)

  @doc "The rows of the lists of `page`: `%{key, label, pending}`."
  def rows(page) do
    for %{"type" => "list"} = block <- page["blocks"] || [],
        row <- get_in(block, ["props", "rows"]) || [],
        do: %{key: row["key"], label: row["label"], pending: row["pending"] == true}
  end

  @doc """
  Wait, at most `within` ms, until `session` has handled every hint it got: none is
  collected, no flush is due and it waits for nobody. A hint sent before this call is
  in its mailbox already, and `:sys.get_state/1` lets it handle that first.
  """
  def quiet(session, within) do
    wait(within, "handle its hints", fn ->
      s = :sys.get_state(session)
      Batch.empty?(s.batch) and s.flush_timer == nil and s.settling == nil
    end)

    :ok
  end

  @doc "`fun`'s first value that is not nil or false, asked again every 20 ms, at most `within` ms."
  def wait(within, what, fun), do: poll(fun, now() + within, what, within)

  defp poll(fun, deadline, what, within) do
    case fun.() do
      done when done not in [nil, false] ->
        done

      _ ->
        if now() >= deadline, do: raise("did not #{what} within #{within} ms")
        Process.sleep(20)
        poll(fun, deadline, what, within)
    end
  end

  @doc "Whether `session` holds no mark: Flow has settled past every write it made."
  def unmarked?(session) do
    s = :sys.get_state(session)
    s.settling == nil and not Marks.held?(s.marks)
  end

  def settling(session), do: :sys.get_state(session).settling

  def now, do: System.monotonic_time(:millisecond)

  defp state(pid) do
    :sys.get_state(pid, 1_000)
  catch
    :exit, _ -> nil
  end

  defp collect(all) do
    receive do
      {:trace_ts, pid, :call, {:gen_tcp, :send, [_socket, data]}, at} ->
        message = data |> IO.iodata_to_binary() |> String.trim() |> JSON.decode!()
        event = %{sequence: length(all) + 1, at: at, type: "send", message: message}
        collect([{pid, event} | all])

      {:trace_ts, pid, :call,
       {AtlasControl.Session, :handle_info,
        [{:atlas_bus, %{class: "answer", kind: "_settled"}, content}, state]}, at} ->
        event = %{
          sequence: length(all) + 1,
          at: at,
          type: "coverage",
          prior: state.settled,
          reported: content["settled"]
        }

        collect([{pid, event} | all])

      {:events, from, ref} ->
        send(from, {ref, Enum.reverse(all)})
        collect(all)

      _ ->
        collect(all)
    end
  end
end

defmodule PageFreshness.CoreLog do
  @moduledoc "Every line the core logs from now on, kept to be read back (a `:logger` handler)."

  def start do
    {:ok, agent} = Agent.start(fn -> [] end, name: __MODULE__)
    :ok = :logger.add_handler(__MODULE__, __MODULE__, %{})
    agent
  end

  def lines, do: Agent.get(__MODULE__, &Enum.reverse/1)

  # The :logger handler callback.
  def log(%{msg: msg}, _config) do
    line =
      case msg do
        {:string, text} -> IO.chardata_to_string(text)
        {:report, report} -> inspect(report)
        {format, args} -> format |> :io_lib.format(args) |> IO.chardata_to_string()
      end

    Agent.update(__MODULE__, &[line | &1])
  end
end
