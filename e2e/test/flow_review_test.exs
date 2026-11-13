defmodule AtlasE2E.FlowReviewTest do
  @moduledoc """
  Slice 7 on real persistence: the review and the test of a pull request run on Flow's
  durable runs, against a private Rela and real Facts (`beam/integration/flow_review_native.exs`).
  Imports, restart while waiting, trusted verdicts, a replaced child whose late result is
  ignored, and review and test completing on one exact revision.
  """
  use ExUnit.Case, async: false
  @root Path.expand("../..", __DIR__)
  @bin System.get_env("ATLAS_E2E_RELA_BIN") || System.get_env("ATLAS_RELA_BIN")
  @moduletag skip:
               if(@bin == nil, do: "set ATLAS_E2E_RELA_BIN to pinned Rela 26.11.2", else: false)
  @moduletag timeout: 120_000
  @moduletag :tmp_dir

  # The child owns its private Rela and Facts and stops them even on an assertion failure.
  test "review and test on one exact revision: imports, restart, replaced child ignored",
       %{tmp_dir: dir} do
    on_exit(fn -> File.rm_rf!(dir) end)
    script = Path.join(@root, "beam/integration/flow_review_native.exs")

    {out, status} =
      System.cmd("mix", ["run", script, dir, @bin],
        cd: Path.join(@root, "beam"),
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    assert out =~ "flow-review native proof:"
  end
end
