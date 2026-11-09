# Git in tests, Code's own included, never reads the user's or the system's configuration: a
# global file of its own under the system temp directory, no system file and no XDG config.
# It names no template folder, so `git init` copies no sample hooks into `.git/hooks` (a
# sandboxed worker may not write there).
config = Path.join(System.tmp_dir!(), "atlas-code-test-#{System.unique_integer([:positive])}")
File.mkdir_p!(config)
File.write!(Path.join(config, "gitconfig"), "[init]\n\ttemplateDir =\n")
System.put_env("GIT_CONFIG_GLOBAL", Path.join(config, "gitconfig"))
System.put_env("GIT_CONFIG_NOSYSTEM", "1")
System.put_env("XDG_CONFIG_HOME", config)
ExUnit.after_suite(fn _ -> File.rm_rf!(config) end)
ExUnit.start()

defmodule AtlasCode.TestDir do
  @moduledoc """
  A test's own folder under the system temp directory (`TMPDIR`), removed after it: a
  `setup` in place of `@moduletag :tmp_dir`, which puts it under the checkout, where a
  sandboxed worker may not write a repository's `.git/config` or `.git/hooks`.
  """
  def tmp_dir(_context) do
    dir = Path.join(System.tmp_dir!(), "atlas-code-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(dir) end)
    %{tmp_dir: dir}
  end
end
