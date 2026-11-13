defmodule AtlasE2E.FlowAcceptanceTest do
  @moduledoc """
  Slice 10 on real persistence: the design of a use case runs on Flow's durable runs,
  for the design phase of the legacy flow design_and_accept, which keeps the building
  phase, against a private Rela and real Facts, with Flow's engine and its processes
  (`beam/integration/flow_acceptance_native.exs`). The use cases as test and prod hold
  them keep what they present and their owner; only a design being written or reviewed
  gets a run, as the import table says; restart while waiting; changes requested; the
  review's approval accepts it once, across a restart before its accepted write reached
  Facts, with one writer at every step; the building phase goes on on the legacy flow.
  """
  use ExUnit.Case, async: false
  @root Path.expand("../..", __DIR__)
  @bin System.get_env("ATLAS_E2E_RELA_BIN") || System.get_env("ATLAS_RELA_BIN")
  @moduletag skip:
               if(@bin == nil, do: "set ATLAS_E2E_RELA_BIN to pinned Rela 26.11.2", else: false)
  @moduletag timeout: 120_000
  @moduletag :tmp_dir

  # The child owns its private Rela and Facts and stops them even on an assertion failure.
  test "the design of a use case on its run: live rows kept, imports, restart, accepted once",
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
