defmodule AtlasFlow.Runs.Clock do
  @moduledoc "UTC persistence and replaceable wakeups. A clock is {module, context}."
  def now({module, context}), do: module.now(context)
  def now(nil), do: DateTime.utc_now()

  def schedule({module, context}, pid, message, delay),
    do: module.schedule(context, pid, message, max(delay, 0))

  def schedule(nil, pid, message, delay), do: Process.send_after(pid, message, delay)
  def cancel(_clock, nil), do: :ok
  def cancel({module, context}, ref), do: module.cancel(context, ref)
  def cancel(nil, ref), do: Process.cancel_timer(ref)
end
