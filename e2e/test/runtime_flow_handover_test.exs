defmodule AtlasE2E.RuntimeFlowHandoverTest do
  use ExUnit.Case, async: false

  @root Path.expand("../..", __DIR__)
  @tag timeout: 120_000
  test "deferred handover wins over replacement across end, crash, silence and restart" do
    # Integration belongs outside either layer; production modules still meet only
    # through the Bus. Each run has synthetic in-memory Facts and stub agents only.
    {out, status} =
      System.cmd("mix", ["run", "integration/runtime_flow_handover.exs"],
        cd: Path.join(@root, "beam"),
        env: [{"MIX_ENV", "test"}, {"ELIXIR_ERL_OPTIONS", "+S 1:1"}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    assert out =~ "5 tests, 0 failures"
  end
end
