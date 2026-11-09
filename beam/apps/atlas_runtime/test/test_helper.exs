# The sandbox (IS-Atlas-94) is macOS's: its tests run where there is one, and where there
# is none, the test that nothing runs without it.
sandbox? = File.exists?("/usr/bin/sandbox-exec")
ExUnit.start(exclude: if(sandbox?, do: [:no_sandbox], else: [:sandbox]))

root = Path.expand("../../../..", __DIR__)

folder =
  Path.join(
    System.tmp_dir!(),
    "atlas-workspace-#{System.pid()}-#{System.unique_integer([:positive])}"
  )

File.mkdir!(folder)
executable = Path.join(folder, "atlas-runtime")
previous = System.get_env("ATLAS_RUNTIME_EXECUTABLE")

ExUnit.after_suite(fn _ ->
  # ExUnit counts skips without their reasons; a host capability skip says what was missing.
  for {capability, reason} <- AtlasRuntime.TestHost.missing_report(),
      do: IO.puts("Skipped tests needing #{capability}: #{reason}")

  File.rm_rf!(folder)
  System.delete_env("ATLAS_RUNTIME_FAKE_NATIVE")

  if previous,
    do: System.put_env("ATLAS_RUNTIME_EXECUTABLE", previous),
    else: System.delete_env("ATLAS_RUNTIME_EXECUTABLE")
end)

case System.cmd(
       "go",
       ["-C", "tools/runtime", "build", "-o", executable, "."],
       cd: root,
       stderr_to_stdout: true
     ) do
  {_, 0} -> System.put_env("ATLAS_RUNTIME_EXECUTABLE", executable)
  {output, _} -> raise("Building Runtime workspace command failed:\n#{output}")
end

fake = Path.join(folder, "fake-native")

case System.cmd("go", ["build", "-o", fake, "main.go"],
       cd: Path.join(__DIR__, "support/fake_native"),
       stderr_to_stdout: true
     ) do
  {_, 0} -> System.put_env("ATLAS_RUNTIME_FAKE_NATIVE", fake)
  {output, _} -> raise("Building the synthetic native CLI failed:\n#{output}")
end
