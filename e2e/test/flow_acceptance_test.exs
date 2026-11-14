defmodule AtlasE2E.FlowAcceptanceTest do
  @moduledoc """
  Slices 10, 11 and 12 on real persistence: a use case runs on Flow's durable runs, its
  design on design_and_accept and its building, testing and acceptance on
  test_and_accept_use_case, which together take every use case from the legacy flow
  design_and_accept; a scene runs on test_and_accept_scene, which takes every scene from
  the legacy flow test_and_accept, so all eight generated subflows are selected; against a
  private Rela and real Facts, with Flow's engine and its processes
  (`beam/integration/flow_acceptance_native.exs`). The use cases and scenes as test and
  prod hold them keep what they present and their owner, and none is left to a legacy
  flow; the import tables; restart while waiting; changes requested; the design accepted
  once; a restart between the design's acceptance and the build run's creation makes one
  build run; its issues built, then tested across a restart, and accepted by the decider;
  reopening it starts no new generation. A scene holds no count of its use cases before
  its cutover, and its count after; it is tested across a restart and accepted by the
  decider; a use case under it reopened, the scene reopened and open work added under it
  start no new generation, and an explicit restart does.
  """
  use ExUnit.Case, async: false
  @root Path.expand("../..", __DIR__)
  @bin AtlasE2E.Instance.rela_bin()
  @moduletag skip:
               if(@bin == nil, do: "set ATLAS_E2E_RELA_BIN to pinned Rela 26.11.2", else: false)
  @moduletag timeout: 120_000
  @moduletag :tmp_dir

  # The child owns its private Rela and Facts and stops them even on an assertion failure.
  test "use cases and scenes on their runs: live rows kept, imports, counts, restarts, accepted once",
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
