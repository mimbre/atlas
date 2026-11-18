# platform/frameworks/test_await

`AtlasTestAwait` (Mix app `atlas_test_await`) is the one helper every app's tests wait with:
on a real event, a record or a `DOWN`, never on the clock. No system owns it, it names none,
and it has no dependencies. Apps take it for their tests only:

```elixir
{:atlas_test_await, path: "../frameworks/test_await", only: :test}
# test/test_helper.exs
ExUnit.start(AtlasTestAwait.exunit_options())   # a bare assert_receive waits up to the cap
```

```elixir
require AtlasTestAwait, as: Await
Await.message({:reply, ^ref, value})                    # assert_receive up to the cap
Await.down(pid_or_monitor_ref)                           # the exit reason
Await.until(check, wake: {:trace, server})               # re-checked after each message it handles
Await.until(check, wake: {:subscribe, fn -> subscribe() end})  # re-checked on each notification
Await.events(3, wake: source, match: &heartbeat?/1)      # count real events, then refute
```

**The cap.** Each wait has a 30 s safety cap (`ATLAS_TEST_AWAIT_CAP_MS`, or `cap:`). It
never decides a test: a wait returns as soon as its event happens. On the cap it raises
`AtlasTestAwait.CapReached`. Its `report` holds the last check value, the events seen, the
watched processes (status, stack, state), the mailbox and the caller's `state:`.

**Negative checks.** Don't wait for nothing to happen. Wait for the events after which it
would have happened (heartbeats, a barrier on the process that would do it), then use
`refute_received`.

`bin/check test-waits` (`bin/lib/test_waits.rb`) keeps tests on this helper. It refuses
`Process.sleep`, short `assert_receive`/`refute_receive` timeouts and short `after` clauses
under `platform/` and `products/`, outside `bin/lib/test_waits.allow`.
