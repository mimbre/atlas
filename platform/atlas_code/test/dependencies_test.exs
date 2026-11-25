defmodule AtlasCode.DependenciesTest do
  # A prepared base carries the Hex registry entries of its locked packages (IS-Atlas-13):
  # every mix.lock is fetched with one Hex home of the preparation's own, whose registry cache
  # is added as `.atlas/hex/cache.ets`; the server's Hex configuration is used, never added.
  # `mix` is a stand-in on PATH that records its Hex home and writes a registry there, so the
  # test needs no network.
  use ExUnit.Case, async: false

  alias AtlasCode.Dependencies

  setup {AtlasCode.TestDir, :tmp_dir}

  setup %{tmp_dir: dir} do
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)
    seen = Path.join(dir, "seen")

    File.write!(Path.join(bin, "mix"), """
    #!/bin/sh
    # Stand-in for `mix deps.get`: a dependency under deps/, and this lockfile's entry in the
    # Hex home's registry cache (appended, so both lockfiles share one home).
    [ "$1" = deps.get ] || exit 2
    mkdir -p deps/pkg && echo source > deps/pkg/lib.ex
    echo "$HEX_HOME" >> "#{seen}"
    echo "entries of $(basename "$PWD")" >> "$HEX_HOME/cache.ets"
    [ -f "$HEX_HOME/hex.config" ] && [ -d "$HEX_HOME/packages" ] || exit 3
    """)

    File.chmod!(Path.join(bin, "mix"), 0o755)

    server_hex = Path.join(dir, "server-hex")
    File.mkdir_p!(Path.join(server_hex, "packages"))
    File.write!(Path.join(server_hex, "hex.config"), "SERVER-HEX-CONFIG\n")
    File.write!(Path.join(server_hex, "cache.ets"), "SERVER-REGISTRY\n")

    for {name, value} <- [
          {"PATH", bin <> ":" <> System.get_env("PATH")},
          {"HEX_HOME", server_hex}
        ] do
      previous = System.get_env(name)
      System.put_env(name, value)

      on_exit(fn ->
        if previous, do: System.put_env(name, previous), else: System.delete_env(name)
      end)
    end

    source = Path.join(dir, "source")
    for app <- ["one", "two"], do: File.mkdir_p!(Path.join(source, app))
    File.write!(Path.join(source, "one/mix.lock"), "%{\"pkg\" => 1}\n")
    File.write!(Path.join(source, "two/mix.lock"), "%{\"pkg\" => 2}\n")
    File.write!(Path.join(source, ".gitignore"), "deps/\n")
    git(source, ["init", "-q", "-b", "develop"])
    git(source, ["add", "-A"])
    git(source, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "base"])
    repo = Path.join(dir, "repo.git")
    git(dir, ["clone", "-q", "--bare", source, repo])

    %{repo: repo, seen: seen, server_hex: server_hex, commit: git(repo, ["rev-parse", "develop"])}
  end

  test "the prepared base adds the registry of its locked packages, from a Hex home of its own",
       %{repo: repo, seen: seen, server_hex: server_hex, commit: commit} do
    prepared = Dependencies.prepared(repo, commit)
    registry = Dependencies.hex_registry()

    assert git(repo, ["diff", "--name-only", commit, prepared]) ==
             Enum.join([registry, "one/deps/pkg/lib.ex", "two/deps/pkg/lib.ex"], "\n")

    # One Hex home for both lockfiles, not the server's and not inside the base's copy; gone after.
    assert [home, home] = seen |> File.read!() |> String.split("\n", trim: true)
    refute home == server_hex
    refute File.exists?(home)

    # Exactly what the lockfiles resolved; the server's registry and configuration stay out.
    assert git(repo, ["show", prepared <> ":" <> registry]) == "entries of one\nentries of two"
    refute git(repo, ["ls-tree", "-r", "--name-only", prepared]) =~ "hex.config"
    assert File.read!(Path.join(server_hex, "cache.ets")) == "SERVER-REGISTRY\n"

    # The same lockfiles give the same commit, from the kept tree.
    File.rm!(seen)
    assert Dependencies.prepared(repo, commit) == prepared
    refute File.exists?(seen)
  end

  defp git(dir, args) do
    {out, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)
    String.trim(out)
  end
end
