# Time in the core, held by the page freshness proof (docs/design/page-freshness.md §2.1,
# §2.2): loaded into the core's own node by proof.exs, never into the e2e project.
defmodule PageFreshness.ControlTime do
  @moduledoc """
  Holds Control's waits (`AtlasControl.Clock.hold/1`). A flush (`:flush`) runs at once,
  as if its 20 ms had passed; every other wait (a settle budget, a read's try, a resend)
  runs out only when the proof says so, and the proof never does. Each held wait is told
  to `watcher` as `{:held, session, message, ms}`.
  """
  use GenServer

  def hold(watcher) do
    {:ok, pid} = GenServer.start(__MODULE__, watcher)
    AtlasControl.Clock.hold(pid)
    pid
  end

  def release(pid) do
    AtlasControl.Clock.release()
    GenServer.stop(pid)
  end

  @impl true
  def init(watcher), do: {:ok, watcher}

  @impl true
  def handle_info({:clock, pid, :flush, _ms}, watcher) do
    send(pid, :flush)
    {:noreply, watcher}
  end

  def handle_info({:clock, pid, message, ms}, watcher) do
    send(watcher, {:held, pid, message, ms})
    {:noreply, watcher}
  end
end

defmodule PageFreshness.FlowTime do
  @moduledoc """
  A clock for Flow (`AtlasFlow.Runs.Clock`'s `{module, context}`) that moves only when the
  proof advances it, as `AtlasFlow.ManualClock` does in Flow's tests. `hold/0` puts the
  core's Flow engine on it and holds the engine itself: Flow keeps no process per fact,
  and the engine settles a hint as soon as it handles it, so it is suspended after its
  first round, and handles nothing (no hint, no `_settled` question) until `until/3`
  lets it catch up. `release/1` puts back the engine the core started, on the real
  clock.
  """
  use Agent

  def now(clock), do: Agent.get(clock, & &1.now)

  def schedule(clock, pid, message, delay) do
    ref = make_ref()

    Agent.update(clock, fn s ->
      put_in(s.timers[ref], {DateTime.add(s.now, delay, :millisecond), pid, message})
    end)

    ref
  end

  def cancel(clock, ref), do: Agent.update(clock, &%{&1 | timers: Map.delete(&1.timers, ref)})

  @doc "Move the clock `ms` on; what fell due is delivered."
  def advance(clock, ms) do
    due =
      Agent.get_and_update(clock, fn s ->
        now = DateTime.add(s.now, ms, :millisecond)

        {due, later} =
          Enum.split_with(s.timers, fn {_, {at, _, _}} -> DateTime.compare(at, now) != :gt end)

        {due, %{s | now: now, timers: Map.new(later)}}
      end)

    for {_, {_, pid, message}} <- due, do: send(pid, message)
    :ok
  end

  @doc "The core's Flow engine on a held clock, held after its first round."
  def hold do
    {:ok, clock} =
      Agent.start(fn -> %{now: DateTime.utc_now(), timers: %{}, held: nil} end)

    :ok = Supervisor.terminate_child(AtlasFlow.Root, AtlasFlow.Engine)

    spec =
      Supervisor.child_spec(
        {AtlasFlow.Engine,
         every: Application.get_env(:atlas_flow, :tick_seconds, 60) * 1000,
         name: AtlasFlow.Engine,
         model: AtlasFlow.Model.configured!(),
         clock: {__MODULE__, clock}},
        id: __MODULE__
      )

    {:ok, engine} = Supervisor.start_child(AtlasFlow.Root, spec)
    # Its first round has reconciled every run and projected every subject.
    :ok = AtlasFlow.Engine.round(engine)
    :ok = :sys.suspend(engine)
    Agent.update(clock, &%{&1 | held: engine})
    clock
  end

  # The held engine handles what it was sent meanwhile, and goes on as usual.
  defp catch_up(clock) do
    case Agent.get_and_update(clock, &{&1.held, %{&1 | held: nil}}) do
      nil -> :ok
      engine -> :sys.resume(engine)
    end
  end

  @doc "The engine the core started, back on the real clock."
  def release(clock) do
    catch_up(clock)
    :ok = Supervisor.terminate_child(AtlasFlow.Root, __MODULE__)
    :ok = Supervisor.delete_child(AtlasFlow.Root, __MODULE__)
    {:ok, _} = Supervisor.restart_child(AtlasFlow.Root, AtlasFlow.Engine)
    Agent.stop(clock)
  end

  @doc """
  Let the held engine catch up, then advance the clock in steps of 50 ms until `done?`
  holds, at most `within` ms of real time: each step, the engine handled what it was sent
  (hints, a round or a run's timer that fell due) before `done?` is asked.
  """
  def until(clock, done?, within) do
    catch_up(clock)
    deadline = System.monotonic_time(:millisecond) + within
    step(clock, done?, deadline)
  end

  defp step(clock, done?, deadline) do
    advance(clock, 50)
    handled()

    cond do
      done?.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        raise "Flow did not settle within the ceiling"

      true ->
        Process.sleep(20)
        step(clock, done?, deadline)
    end
  end

  defp handled, do: state(AtlasFlow.Engine)

  # An engine being replaced meanwhile has nothing left to handle.
  defp state(process) do
    :sys.get_state(process)
  catch
    :exit, _ -> :ok
  end
end
