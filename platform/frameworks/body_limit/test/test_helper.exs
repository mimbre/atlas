# A bare assert_receive waits up to 30 s for its message (bin/lib/test_waits.rb), not 100 ms.
ExUnit.start(assert_receive_timeout: 30_000)
