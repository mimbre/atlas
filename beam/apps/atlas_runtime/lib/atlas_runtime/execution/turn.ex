defmodule AtlasRuntime.Turn do
  @moduledoc """
  One running turn (architecture v4, section 3): an agent acting on one item. It starts the
  agent through its port, and puts every step as a fact in Facts, with its cause:

  - the turn, `running`, on its item and by its agent, with a lease until the silence limit
    (W1, W2);
  - its lease, renewed while the agent shows activity: until its last activity plus the
    silence limit, at most every `lease` (W2);
  - its end, `ended`, with why: the agent ended it, it was silent for the silence limit
    (W2), it ran longer than the maximum (W4), the agent crashed, or the item is no longer
    the agent's (the engine says so). Then the agent may still end its turn by itself for
    the grace (`leave_grace`), so its result is kept, as when it handed the item on itself
    (IS-Atlas-93); after it, the turn is stopped.

  Durable lifecycle remains in Facts; Runtime.Output separately retains a bounded public
  output ring after this producer exits. Viewer reads never refresh the activity lease.
  When this process dies, the engine ends its durable running turn (C1), while Output's
  owner monitor closes the ring. Flow remains authority for the item's ownership (W3).

  The turn's kind and fields, and the guidance records, are the model's
  (`AtlasRuntime.Model`), given by the engine: this module names none.
  """
  use GenServer, restart: :temporary

  require Logger

  alias AtlasRuntime.{Agent, Guidance, Output, Talk}

  def start_link(turn), do: GenServer.start_link(__MODULE__, turn, name: via(turn.key))

  def via(key), do: {:via, Registry, {AtlasRuntime.Turns, key}}

  @doc "End the turn, with why (from the engine)."
  def finish(pid, why), do: GenServer.cast(pid, {:finish, why})

  @doc "The agent's process, while it runs (for a failure Control causes, IS-Atlas-23)."
  def agent(pid), do: GenServer.call(pid, :agent)

  @doc "Its item left its agent (from the engine): it ends by itself, or after the grace."
  def leave(pid, why), do: GenServer.cast(pid, {:leave, why})

  @impl true
  def init(turn) do
    :ok = AtlasBus.attach("runtime@#{turn.machine}/#{turn.key}")
    # The turn's agent and item, for the registry: one turn per agent at a time.
    Registry.update_value(AtlasRuntime.Turns, turn.key, fn _ -> {turn.agent, turn.item} end)
    # Starting waits for Facts; the engine that started it does not.
    {:ok, turn, {:continue, :start}}
  end

  @impl true
  def handle_continue(:start, turn) do
    now = now()

    state =
      Map.merge(turn, %{
        agent_pid: nil,
        ref: nil,
        since: now,
        active: now,
        written: now,
        what: nil,
        leaving: nil,
        guidance: nil,
        output_execution: nil,
        attempt: AtlasBus.Envelope.new_id(),
        confirmed_quiescent: false
      })

    n = state.names

    values = %{
      n.state => n.running,
      n.machine => state.machine,
      n.lease => at(now + state.silence),
      n.activity => "started"
    }

    values = if n[:attempt], do: Map.put(values, n.attempt, state.attempt), else: values

    values =
      if state[:capacity] do
        Enum.reduce([:pick, :backend, :model, :step], values, fn slot, values ->
          if n[slot], do: Map.put(values, n[slot], state.capacity[slot]), else: values
        end)
      else
        values
      end

    # The turn and its immutable execution identity precede any adapter/model input.
    with :ok <- put(state, "create", values, state.cause),
         {:ok, guidance} <- Guidance.register(state),
         true <- now() < now + min(state.silence, state.max),
         true <-
           not Guidance.configured?(state) or match?({:eligible, _}, Guidance.eligible(state)),
         :ok <- prepare_output(guidance),
         :ok <- admit(state),
         {:ok, {agent, ref}} <-
           Agent.start_monitor(
             state.port,
             Guidance.context(state),
             Keyword.put(state.port_opts, :admission, fn -> admit(state) end)
           ) do
      state = %{
        state
        | agent_pid: agent,
          ref: ref,
          guidance: guidance,
          output_execution: output_execution(guidance)
      }

      schedule(state)

      if guidance != nil and state[:guidance_every] != :manual do
        AtlasBus.listen(state.guidance_mapping["interaction"]["kind"])
        Process.send_after(self(), :guidance_tick, 0)
      end

      {:noreply, state}
    else
      error ->
        Logger.warning("runtime: #{state.key} not started: #{inspect(error)}")
        finish_turn(state, "adapter startup or durable execution registration failed")
    end
  end

  # Recheck the exact stored turn and live cursor at the last pre-adapter boundary.
  # Native repeats this after its own configuration checks, before opening the host.
  defp admit(%{capacity: capacity} = state) when not is_nil(capacity) do
    case Talk.read(
           state.turn_kind,
           %{
             "key" => state.key,
             "admission" => %{
               "pick" => capacity.pick,
               "entry" => capacity.entry,
               "attempt" => state.attempt
             }
           },
           state[:talk_opts] || []
         ) do
      %{"admitted" => true} -> :ok
      _ -> {:error, :allocation_not_current}
    end
  end

  defp admit(_state), do: :ok

  @impl true
  def handle_info({:agent, pid, {:activity, what}}, %{agent_pid: pid} = state),
    do: {:noreply, %{state | active: now(), what: what}}

  def handle_info({:agent, pid, {:output, event}}, %{agent_pid: pid} = state) do
    append_output(state.output_execution, event)
    {:noreply, state}
  end

  def handle_info({:agent, pid, {:ended, why}}, %{agent_pid: pid} = state) do
    Process.demonitor(state.ref, [:flush])

    ended =
      if state.leaving,
        do: "#{state.leaving}, and the agent ended its turn by itself: #{why}",
        else: "the agent ended its turn: #{why}"

    finish_turn(%{state | agent_pid: nil, confirmed_quiescent: true}, ended)
  end

  def handle_info({:left, why}, state), do: finish_turn(state, why)

  def handle_info({:agent, pid, {:terminated, %{"exit_code" => code}}}, %{agent_pid: pid} = state)
      when is_integer(code) do
    Process.demonitor(state.ref, [:flush])
    finish_turn(%{state | agent_pid: nil, confirmed_quiescent: true}, "execution stopped")
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{ref: ref} = state) do
    why =
      case reason do
        :normal -> "the agent stopped"
        reason -> "the agent crashed: #{inspect(reason)}"
      end

    finish_turn(%{state | agent_pid: nil}, why)
  end

  def handle_info(:tick, %{pending_end: why} = state), do: finish_turn(state, why)

  def handle_info(:tick, state) do
    now = now()

    cond do
      now - state.active >= state.silence ->
        finish_turn(
          state,
          "silent for #{div(state.silence, 1000)} s: no activity since #{at(state.active)}"
        )

      now - state.since >= state.max ->
        finish_turn(state, "longer than the maximum of #{div(state.max, 1000)} s")

      state.active > state.written ->
        n = state.names

        values = %{
          n.lease => at(state.active + state.silence),
          n.activity => state.what || "activity"
        }

        case put(state, "change", values, "activity: #{state.what || "activity"}") do
          :ok ->
            schedule(state)
            {:noreply, %{state | written: state.active}}

          {:error, _why} ->
            # Facts did not store it: the lease runs out by itself if this goes on.
            schedule(state)
            {:noreply, state}
        end

      true ->
        schedule(state)
        {:noreply, state}
    end
  end

  def handle_info(:guidance_tick, state) do
    Process.send_after(self(), :guidance_tick, state[:guidance_every] || state.lease)
    handle_info(:guidance, state)
  end

  def handle_info(:guidance, state) do
    {_, guidance} = Guidance.round(state, state.guidance, state.agent_pid, :active)
    {:noreply, %{state | guidance: guidance}}
  end

  def handle_info({:atlas_bus, %AtlasBus.Envelope{class: "stored"}, _}, state),
    do: handle_info(:guidance, state)

  # Events are only wakeups. Even typed evidence must be queried, never trusted here.
  def handle_info({:agent, pid, {:guidance, _evidence}}, %{agent_pid: pid} = state) do
    {_, guidance} = Guidance.round(state, state.guidance, state.agent_pid, :active)
    {:noreply, %{state | guidance: guidance}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_call(:agent, _from, state), do: {:reply, state[:agent_pid], state}

  @impl true
  def handle_cast({:finish, why}, state), do: finish_turn(state, why)

  def handle_cast({:leave, why}, %{leaving: nil} = state) do
    Process.send_after(self(), {:left, why}, state.leave_grace)
    {:noreply, %{state | leaving: why}}
  end

  def handle_cast({:leave, _why}, state), do: {:noreply, state}

  defp finish_turn(state, why) do
    capacity? = state[:capacity] != nil or is_binary(state.names[:quiescent])
    confirmed = state[:confirmed_quiescent] == true

    stopped =
      if state.agent_pid do
        Agent.close_input(state.port, state.agent_pid)
        # Reconcile one bounded page before stopping; Engine handles remaining history.
        Guidance.round(state, state.guidance, state.agent_pid, :closed)

        if capacity?,
          do: Agent.stop_confirmed(state.port, state.agent_pid),
          else: Agent.stop(state.port, state.agent_pid)
      end

    if capacity? and not confirmed and stopped != :ok do
      n = state.names

      _ =
        put(
          state,
          "change",
          %{n.activity => "execution outcome unknown; reconciliation required"},
          why
        )

      if state.agent_pid && Process.alive?(state.agent_pid) do
        schedule(state)
        {:noreply, state}
      else
        {:stop, :normal, state}
      end
    else
      if state.output_execution,
        do: output_call(fn -> Output.finish(state.output_execution) end)

      n = state.names

      values = %{n.state => n.ended, n.why => why, n.lease => "", n.ended_at => at(now())}

      values =
        if is_binary(n[:quiescent]) and (confirmed or (capacity? and stopped == :ok)),
          do: Map.put(values, n.quiescent, true),
          else: values

      case put(state, "change", values, why) do
        :ok ->
          Logger.info("runtime: #{state.key} ended: #{why}")
          {:stop, :normal, state}

        {:error, failed} ->
          Logger.warning(
            "runtime: #{state.key} not ended in Facts (#{failed}); retaining completion"
          )

          schedule(state)

          {:noreply,
           Map.merge(state, %{
             agent_pid: nil,
             confirmed_quiescent: confirmed or stopped == :ok,
             pending_end: why
           })}
      end
    end
  end

  # Every write is a fact with its cause, by Runtime.
  defp put(state, op, values, cause) do
    n = state.names

    content = %{
      "op" => op,
      "key" => state.key,
      "values" => values,
      "version" => nil,
      "by" => "runtime",
      "cause" => cause
    }

    content =
      if op == "create",
        do:
          content
          |> Map.put("links", %{n.on => [state.item], n.by => [state.agent]})
          |> Map.put("allocation", (state[:capacity] || %{})[:entry]),
        else: content

    content =
      if op == "change" and is_binary(n[:attempt]) do
        was = %{n.attempt => state.attempt}

        was =
          if is_binary(n[:pick]),
            do: Map.put(was, n.pick, (state[:capacity] || %{})[:pick]),
            else: was

        Map.put(content, "was", was)
      else
        content
      end

    case Talk.put(state.turn_kind, content) do
      {:stored, _} -> :ok
      {:refused, reasons} -> {:error, Enum.join(List.wrap(reasons), "; ")}
      {:error, why} -> {:error, inspect(why)}
    end
  end

  defp output_execution(nil), do: nil

  defp output_execution(%{execution: execution}) do
    %{
      "worker" => Map.take(execution, ~w(environment machine worker)),
      "turn" => execution["turn"],
      "attempt" => execution["attempt"]
    }
  end

  defp prepare_output(nil), do: :ok

  defp prepare_output(guidance) do
    case output_call(fn -> Output.open(output_execution(guidance), self()) end) do
      # Ephemeral output loss must not end an otherwise eligible worker. Keep its
      # confirmed identity so the next producer event can reopen a fresh epoch.
      {:error, "output_unavailable"} -> :ok
      result -> result
    end
  end

  defp append_output(nil, _event), do: :ok

  defp append_output(execution, event) do
    case output_call(fn -> Output.append(execution, event) end) do
      {:error, "output_unavailable"} ->
        # Only a new event from this exact registered producer may recover a lost ring.
        # Reopening keeps the attempt, but the store assigns a new epoch.
        with :ok <- output_call(fn -> Output.open(execution, self()) end) do
          output_call(fn -> Output.append(execution, event) end)
        end

      result ->
        result
    end
  end

  defp output_call(call) do
    call.()
  catch
    :exit, _ -> {:error, "output_unavailable"}
  end

  defp schedule(state), do: Process.send_after(self(), :tick, min(state.lease, state.silence))

  defp now, do: System.system_time(:millisecond)

  defp at(ms),
    do:
      ms
      |> DateTime.from_unix!(:millisecond)
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()
end
