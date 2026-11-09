defmodule AtlasE2E.FlowAcceptanceTest do
  @moduledoc """
  Slices 10 and 11 on real persistence: a use case runs on Flow's durable runs, its
  design on design_and_accept and its building, testing and acceptance on
  test_and_accept_use_case, which together take every use case from the legacy flow
  design_and_accept, against a private Rela and real Facts, with Flow's engine and its
  processes (`beam/integration/flow_acceptance_native.exs`). The use cases as test and
  prod hold them keep what they present and their owner, and none is left to the legacy
  flow; both import tables; restart while waiting; changes requested; the design accepted
  once; a restart between the design's acceptance and the build run's creation makes one
  build run; its issues built, then tested across a restart, and accepted by the
  decider; reopening it starts no new generation.
  """
  use ExUnit.Case, async: false
  @root Path.expand("../..", __DIR__)
  @bin System.get_env("ATLAS_E2E_RELA_BIN") || System.get_env("ATLAS_RELA_BIN")
  @moduletag skip:
               if(@bin == nil, do: "set ATLAS_E2E_RELA_BIN to pinned Rela 26.11.2", else: false)
  @moduletag timeout: 120_000
  @moduletag :tmp_dir

  # The child owns its private Rela and Facts and stops them even on an assertion failure.
  test "a use case on its design and build runs: live rows kept, imports, restarts, accepted once",
       %{tmp_dir: dir} do
    on_exit(fn -> File.rm_rf!(dir) end)
    script = Path.join(@root, "beam/integration/flow_acceptance_native.exs")

    {out, status} =
      System.cmd("mix", ["run", script, dir, @bin],
        cd: Path.join(@root, "beam"),
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    assert out =~ "flow-acceptance native proof:"
  end
end
