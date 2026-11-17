# A bare assert_receive waits on its event up to a safety cap, not ExUnit's 100 ms
# (platform/frameworks/test_await; this project does not depend on it).
ExUnit.start(assert_receive_timeout: 30_000)
