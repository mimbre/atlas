defmodule AtlasE2E.RuntimeStatusTest do
  use ExUnit.Case, async: false
  @root Path.expand("../..", __DIR__)

  # The generated status path end to end: tools/runtime.py runtime-status, the contract's
  # codec (tools/runtime_status.exs) and the readonly observation. The Python unit tests
  # of that observation (tools/tests/test_runtime_status.py) run in CI's contract job.
  @tag timeout: 30_000
  test "generated machine diagnostics are readonly and never equate a PID with a Runtime" do
    # Explicit build setup; the status command itself must never build or install.
    {output, code} =
      System.cmd("mix", ["compile", "--warnings-as-errors"],
        cd: Path.join(@root, "bff/contract"),
        env: [{"MIX_ENV", "test"}, {"ELIXIR_ERL_OPTIONS", "+S 1:1"}],
        stderr_to_stdout: true
      )

    assert code == 0, output

    dir = Path.join(System.tmp_dir!(), "atlas-status-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)

    # Status does not create the Runtime home.
    {output, _} = status(Path.join(dir, "absent"), stderr_to_stdout: true)
    refute File.exists?(Path.join([dir, "absent", "runtime"])), output

    # A retained PID of a live process (this BEAM's) is not Runtime health or ownership.
    home = Path.join([dir, "retained", "runtime"])
    File.mkdir_p!(home)
    File.write!(Path.join(home, "runtime.pid"), System.pid())

    File.write!(
      Path.join(home, "runtime.json"),
      JSON.encode!(%{
        env: "test",
        runtime: %{machine: "fixture"},
        bus_link: %{machine: "fixture"}
      })
    )

    {output, _} = status(Path.dirname(home))
    refute output =~ "running (pid"
    assert String.downcase(output) =~ "unverified", output
  end

  defp status(dir, options \\ []) do
    File.mkdir_p!(dir)
    client = Path.join(dir, "client.json")
    File.write!(client, JSON.encode!(%{env: "test", control: %{port: 1}}))
    home = Path.join(dir, "runtime")

    System.cmd(
      "python3",
      [Path.join(@root, "tools/runtime.py"), "runtime-status", @root, "test"],
      [
        env: [
          {"ATLAS_ENV_FILE", client},
          {"ATLAS_RUNTIME_HOME", home},
          {"ATLAS_RUNTIME_FILE", Path.join(home, "runtime.json")},
          {"ELIXIR_ERL_OPTIONS", "+S 1:1"},
          {"PYTHONDONTWRITEBYTECODE", "1"}
        ]
      ] ++ options
    )
  end
end
