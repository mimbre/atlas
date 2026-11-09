defmodule AtlasE2E.RuntimeBackendTest do
  @moduledoc """
  The Runtime backend end to end with a stub harness (design 2026-11-16-runtime-backend
  §13 S1d, cases 1–9): integration/runtime_backend.exs runs the real Service, work core and
  backend as a separate OS process and drives it over backend.sock. Its ExUnit seed is
  this run's; ATLAS_E2E_INCLUDE (for example `cli_after_d3`) passes through.
  """
  use ExUnit.Case, async: false

  @root Path.expand("../../../..", __DIR__)
  @tag timeout: 600_000
  test "the Runtime backend serves the work contract over backend.sock (cases 1–9)" do
    {output, status} =
      System.cmd("mix", ["run", "--no-start", "integration/runtime_backend.exs"],
        cd: Path.join(@root, "products/software_factory"),
        env: [{"MIX_ENV", "test"}, {"ATLAS_E2E_SEED", to_string(ExUnit.configuration()[:seed])}],
        stderr_to_stdout: true
      )

    assert status == 0, output
  end
end
