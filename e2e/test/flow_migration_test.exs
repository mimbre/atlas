defmodule AtlasE2E.FlowMigrationTest do
  use ExUnit.Case, async: false
  @root Path.expand("../..", __DIR__)
  @tag timeout: 120_000
  test "core Flow boots over the pre-upgrade run store" do
    {out, status} =
      System.cmd("mix", ["run", "integration/flow_migration.exs"],
        cd: Path.join(@root, "beam"),
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    assert out =~ "flow migration boot proof:"
  end
end
