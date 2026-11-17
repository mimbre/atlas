defmodule AtlasE2E.RuntimeBackendTcpTest do
  @moduledoc """
  The Runtime backend on loopback TCP end to end, with no tailnet (design
  2026-11-16-runtime-backend §8.1–§8.4, §9, §13 S3): integration/runtime_backend_tcp.exs
  runs the real Service, work core and both backend listeners as a separate OS process,
  with a clients.json, and drives it over 127.0.0.1, backend.sock and a TLS stand-in for
  `tailscale serve`, and its `:remote` cases drive AtlasRuntime.Remote (S3 P6) through a
  CONNECT proxy. Its ExUnit seed is this run's; ATLAS_E2E_INCLUDE passes through.
  """
  use ExUnit.Case, async: false

  @root Path.expand("../../../..", __DIR__)
  @tag timeout: 600_000
  test "the Runtime backend serves token clients on loopback TCP (S3)" do
    {output, status} =
      System.cmd("mix", ["run", "--no-start", "integration/runtime_backend_tcp.exs"],
        cd: Path.join(@root, "products/software_factory"),
        env: [{"MIX_ENV", "test"}, {"ATLAS_E2E_SEED", to_string(ExUnit.configuration()[:seed])}],
        stderr_to_stdout: true
      )

    assert status == 0, output
  end
end
