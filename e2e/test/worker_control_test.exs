defmodule AtlasE2E.WorkerControlTest do
  use ExUnit.Case, async: false

  @root Path.expand("../..", __DIR__)
  @tag timeout: 120_000
  test "worker Control uses durable exact-turn authority across real client sessions" do
    {output, status} =
      System.cmd("mix", ["run", "integration/worker_control.exs"],
        cd: Path.join(@root, "beam"),
        env: [{"MIX_ENV", "test"}, {"ELIXIR_ERL_OPTIONS", "+S 1:1"}],
        stderr_to_stdout: true
      )

    assert status == 0, output
  end
end
