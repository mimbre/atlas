defmodule AtlasE2E.FlowDeliveryTest do
  @moduledoc """
  Slices 8 and 9 on real persistence: the pull request and the issue run on Flow's durable
  runs in place of their legacy flows, against a private Rela and real Facts
  (`beam/integration/flow_delivery_native.exs`). Imports of merged, closed and open pull
  requests, one writer, restart while waiting, changes requested, a new revision whose
  replaced verdict is ignored, review and test together leading to the merge once, and the
  merge by hand ending it; imports of issues, which build on while their pull request is
  checked or sent back, and are done, once, when it is merged (the composition's link).
  """
  use ExUnit.Case, async: false
  @root Path.expand("../..", __DIR__)
  @bin System.get_env("ATLAS_E2E_RELA_BIN") || System.get_env("ATLAS_RELA_BIN")
  @moduletag skip:
               if(@bin == nil, do: "set ATLAS_E2E_RELA_BIN to pinned Rela 26.11.2", else: false)
  @moduletag timeout: 120_000
  @moduletag :tmp_dir

  # The child owns its private Rela and Facts and stops them even on an assertion failure.
  test "the pull request and its issue on their runs: imports, restart, new revision, merge once",
       %{tmp_dir: dir} do
    on_exit(fn -> File.rm_rf!(dir) end)
    script = Path.join(@root, "beam/integration/flow_delivery_native.exs")

    {out, status} =
      System.cmd("mix", ["run", script, dir, @bin],
        cd: Path.join(@root, "beam"),
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    assert out =~ "flow-delivery native proof:"
  end
end
