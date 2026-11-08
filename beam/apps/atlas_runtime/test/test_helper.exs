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
  File.rm_rf!(folder)

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
