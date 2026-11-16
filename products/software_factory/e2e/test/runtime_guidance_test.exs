defmodule AtlasE2E.RuntimeGuidanceTest do
  use ExUnit.Case, async: false
  @root Path.expand("../../../..", __DIR__)
  @tag timeout: 120_000
  test "exact-turn guidance survives loss and closure with private durable evidence" do
    {out, status} =
      System.cmd("mix", ["run", "integration/runtime_guidance.exs"],
        cd: Path.join(@root, "products/software_factory"),
        env: [{"MIX_ENV", "test"}, {"ELIXIR_ERL_OPTIONS", "+S 1:1"}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    assert out =~ "21 tests, 0 failures"
  end
end
