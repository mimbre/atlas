defmodule AtlasE2E.RelaInstallTest do
  use ExUnit.Case, async: true
  @installer Path.expand("../../rela/scripts/start-test.sh", __DIR__)
  @bin AtlasE2E.Instance.rela_bin()
  @moduletag skip: if(@bin == nil, do: "set ATLAS_E2E_RELA_BIN to pinned Rela", else: false)
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    bin = Path.join(dir, "bin")
    tools = Path.join(dir, "tools")
    File.mkdir_p!(bin)
    File.mkdir_p!(tools)

    for name <- ["rela", "rela-sqlite", "rela-server-headless-sqlite"] do
      File.cp!(Path.join(@bin, name), Path.join(bin, name))
      File.chmod!(Path.join(bin, name), 0o755)
    end

    # No test can download. A rejected cache must reach this boundary and fail closed.
    curl = Path.join(tools, "curl")
    File.write!(curl, "#!/bin/sh\necho download-attempted\nexit 73\n")
    File.chmod!(curl, 0o755)

    env = [
      {"ATLAS_RELA_BIN", bin},
      {"ATLAS_RELA_DATA", Path.join(dir, "data")},
      {"ATLAS_RELA_PORT", "0"},
      {"PATH", tools <> ":" <> System.get_env("PATH")}
    ]

    %{bin: bin, dir: dir, tools: tools, env: env}
  end

  defp install(env),
    do: System.cmd("bash", [@installer, "install"], env: env, stderr_to_stdout: true)

  test "the exact CLI and headless server are reused without downloading or starting data", c do
    assert {_, 0} = install(c.env)
    refute File.exists?(Path.join(c.dir, "data"))
    refute File.exists?(Path.join(c.bin, "rela-server"))
  end

  for name <- ["rela", "rela-sqlite", "rela-server-headless-sqlite"] do
    test "missing #{name} fails closed when replacement cannot be downloaded", c do
      File.rm!(Path.join(c.bin, unquote(name)))
      assert {out, 73} = install(c.env)
      assert out =~ "download-attempted"
      refute File.exists?(Path.join(c.dir, "data"))
    end
  end

  test "a same-version CLI cannot vouch for a different server variant", c do
    # Keep the old executable name too: existence of it must never make a cache ready.
    File.cp!(System.find_executable("bash"), Path.join(c.bin, "rela-server"))
    File.cp!(System.find_executable("bash"), Path.join(c.bin, "rela-server-headless-sqlite"))
    assert {out, 73} = install(c.env)
    assert out =~ "download-attempted"
    refute File.exists?(Path.join(c.dir, "data"))
  end

  test "an altered CLI is rejected even when it claims the pinned version", c do
    File.write!(Path.join(c.bin, "rela"), "#!/bin/sh\necho 'rela version 26.11.3'\n")
    assert {out, 73} = install(c.env)
    assert out =~ "download-attempted"
    refute File.exists?(Path.join(c.dir, "data"))
  end

  test "a corrupt archive cannot replace binaries or start data", c do
    before = File.read!(Path.join(c.bin, "rela"))
    File.rm!(Path.join(c.bin, "rela-server-headless-sqlite"))
    File.write!(Path.join(c.tools, "curl"), "#!/bin/sh\necho corrupt > \"$3\"\n")
    assert {_, 1} = install(c.env)
    assert File.read!(Path.join(c.bin, "rela")) == before
    refute File.exists?(Path.join(c.bin, "rela-server-headless-sqlite"))
    refute File.exists?(Path.join(c.dir, "data"))
  end

  test "an unsupported platform is refused before any download", c do
    uname = Path.join(c.tools, "uname")
    File.write!(uname, "#!/bin/sh\necho unsupported\n")
    File.chmod!(uname, 0o755)
    assert {out, 1} = install(c.env)
    assert out =~ "no rela"
    refute out =~ "download-attempted"
    refute File.exists?(Path.join(c.dir, "data"))
  end
end
