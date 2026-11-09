defmodule AtlasE2E.RuntimeLifecycleTest do
  use ExUnit.Case, async: false
  @root Path.expand("../../../..", __DIR__)
  @tag timeout: 120_000
  test "generated local lifecycle requires exact ownership and preserves private instance evidence" do
    for component <- ["platform/atlas_control/backend/contract", "products/software_factory"] do
      {output, code} =
        System.cmd("mix", ["compile", "--warnings-as-errors"],
          cd: Path.join(@root, component),
          env: [{"MIX_ENV", "dev"}, {"ELIXIR_ERL_OPTIONS", "+S 1:1"}],
          stderr_to_stdout: true
        )

      assert code == 0, output
    end

    for script <- [
          "test_runtime_lifecycle.py",
          "test_runtime_credential_routing.py",
          "runtime_lifecycle_private.py"
        ] do
      {output, code} =
        System.cmd("python3", [Path.join(@root, "platform/ops/tests/" <> script)],
          cd: @root,
          env: [
            {"PYTHONDONTWRITEBYTECODE", "1"},
            {"ATLAS_LIFECYCLE_PROOF_DIR",
             Path.join(@root, "products/software_factory/e2e/artifacts/runtime-lifecycle")}
          ],
          stderr_to_stdout: true
        )

      assert code == 0, output
    end
  end
end
