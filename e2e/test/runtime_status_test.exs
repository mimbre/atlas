defmodule AtlasE2E.RuntimeStatusTest do
  use ExUnit.Case, async: false
  @root Path.expand("../..", __DIR__)
  @tag timeout: 30_000
  test "generated machine diagnostics are readonly and never equate a PID with a Runtime" do
    # Explicit build setup; the status command itself must never build or install.
    {output, code} =
      System.cmd("mix", ["compile", "--warnings-as-errors"],
        cd: Path.join(@root, "bff/contract"),
        env: [{"MIX_ENV", "test"}, {"ELIXIR_ERL_OPTIONS", "+S 1:1"}],
        stderr_to_stdout: true
      )

    assert code == 0, output

    {output, code} =
      System.cmd("python3", [Path.join(@root, "tools/tests/test_runtime_status.py")],
        cd: @root,
        stderr_to_stdout: true
      )

    assert code == 0, output
    assert output =~ "Ran 9 tests"
  end
end
