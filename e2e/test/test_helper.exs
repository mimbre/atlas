# Git in these tests, and in every command they run (bin/atlas, bin/atlas-ops, the core),
# never reads the user's or the system's configuration: a global file of the run's own under
# the system temp directory (in place of ~/.gitconfig and the XDG one), which names no
# template folder (so `git init` copies no sample hooks) and no ignore or attributes file
# (git's defaults are under ~/.config/git), and no system file. A sandboxed worker may read
# neither ~/.gitconfig nor ~/.config/git, nor write a repository's `.git/hooks`.
git = Path.join(System.tmp_dir!(), "atlas-e2e-git-#{System.unique_integer([:positive])}")
File.mkdir_p!(git)

File.write!(Path.join(git, "gitconfig"), """
[init]
	templateDir =
[core]
	excludesFile = /dev/null
	attributesFile = /dev/null
""")

System.put_env("GIT_CONFIG_GLOBAL", Path.join(git, "gitconfig"))
System.put_env("GIT_CONFIG_NOSYSTEM", "1")
ExUnit.after_suite(fn _ -> File.rm_rf!(git) end)

# :httpc needs a CA store even for http; where the system's is unreadable, the bundle on disk.
_ = AtlasFacts.Trust.load()

ExUnit.start()
