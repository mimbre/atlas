defmodule AtlasRuntime.Sources.LeaseClock do
  @moduledoc """
  The sleep-safe lease age for self-fencing (decision §5.3 item 2, F2).

  A lease's age counts from the send time of the last successful `poll`. When it reaches
  `lease_ttl`, the Runtime starts that lease's cancel stages.

  BEAM's OS monotonic source on macOS is `CLOCK_UPTIME_RAW`, which does not advance while
  the machine sleeps; on monotonic time alone a lease would look fresh after a wake. So the
  age is the **larger** of the monotonic and the system (wall-clock) elapsed time, and never
  below 0:
  - wall-clock time counts sleep;
  - a forward wall jump only fences early, which is safe;
  - a backward wall jump is covered by the monotonic term.

  The caller checks every `check_interval_ms/0`, so a machine that wakes fences within
  seconds.

  Everything here is pure. The clock is a zero-arity function returning
  `{monotonic_ms, system_ms}`; the default, `now/0`, reads `System.monotonic_time/1` and
  `System.os_time/1` in milliseconds. Tests pass their own.
  """

  @check_interval_ms 5_000

  @typedoc "`{monotonic_ms, system_ms}`, as read at one instant."
  @type stamp :: {integer(), integer()}
  @type clock :: (-> stamp())

  @doc "How often the caller checks its leases: every 5 s."
  @spec check_interval_ms() :: pos_integer()
  def check_interval_ms, do: @check_interval_ms

  @doc "The default clock reading: `{monotonic_ms, system_ms}`."
  @spec now() :: stamp()
  def now, do: {System.monotonic_time(:millisecond), System.os_time(:millisecond)}

  @doc "Records the moment a lease was last renewed, read from `clock`."
  @spec stamp(clock()) :: stamp()
  def stamp(clock \\ &now/0) when is_function(clock, 0), do: read(clock)

  @doc """
  The lease age in ms at `clock`'s current reading:
  `max(monotonic elapsed, system elapsed, 0)`.
  """
  @spec age(stamp(), clock()) :: non_neg_integer()
  def age({mono0, sys0}, clock \\ &now/0) when is_function(clock, 0) do
    {mono, sys} = read(clock)
    Enum.max([mono - mono0, sys - sys0, 0])
  end

  @doc "Whether the lease has reached `lease_ttl` ms of age: expired at exactly `lease_ttl`."
  @spec expired?(stamp(), clock(), pos_integer()) :: boolean()
  def expired?(stamp, clock, lease_ttl) when is_integer(lease_ttl) and lease_ttl > 0 do
    age(stamp, clock) >= lease_ttl
  end

  defp read(clock) do
    case clock.() do
      {mono, sys} = stamp when is_integer(mono) and is_integer(sys) ->
        stamp

      other ->
        raise ArgumentError,
              "lease clock must return {monotonic_ms, system_ms}, got: #{inspect(other)}"
    end
  end
end
