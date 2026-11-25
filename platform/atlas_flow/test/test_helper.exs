# The work source tests read the Runtime's generated contract files, which are build output
# (not in git): generate them first, with the generators' own environment.
{_, 0} =
  System.cmd(Path.expand("../../../bin/generate", __DIR__), ~w(runtime_boundary runtime_backend),
    env: [{"MIX_ENV", nil}],
    stderr_to_stdout: true
  )

ExUnit.start(AtlasTestAwait.exunit_options())
