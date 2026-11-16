defmodule AtlasFlow.ManualClock do
  @moduledoc "A UTC clock whose wakeups are delivered only by an explicit advance."
  use Agent
  def start_link(now), do: Agent.start_link(fn -> %{now: now, timers: %{}} end)
  def now(pid), do: Agent.get(pid, & &1.now)

  def schedule(clock, pid, message, delay) do
    ref = make_ref()

    Agent.update(clock, fn s ->
      put_in(s.timers[ref], {DateTime.add(s.now, delay, :millisecond), pid, message})
    end)

    ref
  end

  def cancel(clock, ref), do: Agent.update(clock, &%{&1 | timers: Map.delete(&1.timers, ref)})

  def advance(clock, milliseconds) do
    due =
      Agent.get_and_update(clock, fn s ->
        now = DateTime.add(s.now, milliseconds, :millisecond)

        {due, later} =
          Enum.split_with(s.timers, fn {_, {at, _, _}} -> DateTime.compare(at, now) != :gt end)

        {due, %{now: now, timers: Map.new(later)}}
      end)

    for {_, {_, pid, message}} <- due, do: send(pid, message)
    :ok
  end
end
