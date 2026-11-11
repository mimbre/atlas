# Git in tests, Code's own included, never reads the user's or the system's configuration: an
# empty global file under the system temp directory, no system file and no XDG config.
config = Path.join(System.tmp_dir!(), "atlas-code-test-#{System.unique_integer([:positive])}")
File.mkdir_p!(config)
File.write!(Path.join(config, "gitconfig"), "")
System.put_env("GIT_CONFIG_GLOBAL", Path.join(config, "gitconfig"))
System.put_env("GIT_CONFIG_NOSYSTEM", "1")
System.put_env("XDG_CONFIG_HOME", config)
ExUnit.after_suite(fn _ -> File.rm_rf!(config) end)
ExUnit.start()
