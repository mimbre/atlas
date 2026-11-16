defmodule AtlasControl.Clock do
  @moduledoc """
  When Control's waits run out: a read's try, a fact's resend, the Gateway's offline
  while. `after_ms/2` sends `message` to the calling process after `ms`, as
  `Process.send_after/3` does, and returns the timer.

  A test may hold the clock instead (`hold/1`): each wait is then told to the holder as
  `{:clock, pid, message, ms}` and runs out only when the holder sends `message` to `pid`
  itself. The returned timer is then a reference no timer has; cancelling it does nothing.
  """

  @doc "Send `message` to this process after `ms`, unless a test holds the clock."
  def after_ms(message, ms) do
    case Application.get_env(:atlas_control, :clock) do
      nil ->
        Process.send_after(self(), message, ms)

      holder ->
        send(holder, {:clock, self(), message, ms})
        make_ref()
    end
  end

  @doc "Test only: `holder` decides when every wait runs out, until `release/0`."
  def hold(holder), do: Application.put_env(:atlas_control, :clock, holder)

  def release, do: Application.delete_env(:atlas_control, :clock)
end
