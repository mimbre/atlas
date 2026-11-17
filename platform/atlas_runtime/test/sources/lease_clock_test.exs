defmodule AtlasRuntime.Sources.LeaseClockTest do
  # Decision §5.3 item 2 (F2): lease age = max(monotonic elapsed, system elapsed, 0),
  # checked every 5 s. Every case runs on an injected clock.
  use ExUnit.Case, async: true

  alias AtlasRuntime.Sources.LeaseClock

  @ttl 120_000
  @hour 3_600_000
  # An arbitrary wall-clock origin, so system and monotonic readings differ.
  @wall 1_795_000_000_000

  defp at(mono, sys), do: fn -> {mono, sys} end

  defp renewed, do: LeaseClock.stamp(at(0, @wall))

  test "stamp records {monotonic_ms, system_ms} from the injected clock" do
    assert LeaseClock.stamp(at(42, @wall + 7)) == {42, @wall + 7}
  end

  test "sleep/wake: system time +lease_ttl with monotonic +0 is expired" do
    # CLOCK_UPTIME_RAW does not advance while macOS sleeps; the wall clock does.
    assert LeaseClock.age(renewed(), at(0, @wall + @ttl)) == @ttl
    assert LeaseClock.expired?(renewed(), at(0, @wall + @ttl), @ttl)
  end

  test "monotonic time +lease_ttl with system time +0 is expired" do
    assert LeaseClock.expired?(renewed(), at(@ttl, @wall), @ttl)
  end

  test "backward wall jump (clock step): system time -1 h with monotonic +lease_ttl is expired" do
    clock = at(@ttl, @wall - @hour)
    assert LeaseClock.age(renewed(), clock) == @ttl
    assert LeaseClock.expired?(renewed(), clock, @ttl)
  end

  test "a forward wall jump fences early" do
    # 1 s of real time, but the wall clock stepped forward by an hour.
    assert LeaseClock.expired?(renewed(), at(1_000, @wall + @hour), @ttl)
  end

  test "a fresh lease is not expired" do
    refute LeaseClock.expired?(renewed(), at(0, @wall), @ttl)
    refute LeaseClock.expired?(renewed(), at(@ttl - 1, @wall + @ttl - 1), @ttl)
  end

  test "boundary: expired at exactly lease_ttl, not one ms before" do
    refute LeaseClock.expired?(renewed(), at(@ttl - 1, @wall), @ttl)
    assert LeaseClock.expired?(renewed(), at(@ttl, @wall), @ttl)
    refute LeaseClock.expired?(renewed(), at(0, @wall + @ttl - 1), @ttl)
    assert LeaseClock.expired?(renewed(), at(0, @wall + @ttl), @ttl)
  end

  test "the age is never negative" do
    assert LeaseClock.age(renewed(), at(-5, @wall - @hour)) == 0
  end

  test "the check runs every 5 s" do
    assert LeaseClock.check_interval_ms() == 5_000
  end

  test "checked every 5 s, a machine that wakes after lease_ttl fences at the first check after wake" do
    interval = LeaseClock.check_interval_ms()
    stamp = renewed()
    sleep_at = 30_000
    slept = 300_000

    # Awake: monotonic and wall advance together, one check per interval, nothing expires.
    awake = for mono <- interval..sleep_at//interval, do: {mono, @wall + mono}
    refute Enum.any?(awake, fn {mono, sys} -> LeaseClock.expired?(stamp, at(mono, sys), @ttl) end)

    # Asleep for 300 s: the wall clock moves, monotonic does not. After wake the checks go
    # on every interval of monotonic time.
    after_wake =
      for mono <- (sleep_at + interval)..(sleep_at + 30 * interval)//interval,
          do: {mono, @wall + mono + slept}

    {fenced_at, _} =
      Enum.find(after_wake, fn {mono, sys} -> LeaseClock.expired?(stamp, at(mono, sys), @ttl) end)

    assert fenced_at - sleep_at <= interval
  end

  test "the default clock reads monotonic and system milliseconds" do
    {mono, sys} = LeaseClock.now()
    assert is_integer(mono) and is_integer(sys)
    assert abs(sys - System.os_time(:millisecond)) < 1_000

    stamp = LeaseClock.stamp()
    assert LeaseClock.age(stamp) < 1_000
    refute LeaseClock.expired?(stamp, &LeaseClock.now/0, @ttl)
  end

  test "a clock that does not return two integers is refused" do
    assert_raise ArgumentError, fn -> LeaseClock.stamp(fn -> :tick end) end
  end
end
