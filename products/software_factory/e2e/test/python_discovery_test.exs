defmodule AtlasE2E.PythonDiscoveryTest do
  use ExUnit.Case, async: false

  @moduletag timeout: 120_000
  @root Path.expand("../../../..", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "atlas-python-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    for folder <- ["bin", "platform/atlas_facts/rela", "products/software_factory/targets/rela"] do
      File.mkdir_p!(Path.dirname(Path.join(dir, folder)))
      File.cp_r!(Path.join(@root, folder), Path.join(dir, folder))
    end

    # The checkout's layout with its code linked, as before the move. The folders that hold
    # something private, the umbrella's apps and the model are real folders here, their other
    # entries linked: the Rela scripts (platform/atlas_facts/rela) find the private project
    # (products/software_factory/targets/rela) beside them, and the umbrella, its apps and the
    # model see one another at the same paths. The umbrella builds in the checkout's _build.
    File.mkdir_p!(Path.join(@root, "products/software_factory/_build"))

    apps =
      for name <- File.ls!(Path.join(@root, "platform")),
          String.starts_with?(name, "atlas_"),
          do: "platform/" <> name

    real = ["platform", "products/software_factory", "products/software_factory/model" | apps]

    private = [
      "platform/atlas_facts/rela",
      "products/software_factory/targets",
      "products/software_factory/environments",
      "products/software_factory/e2e"
    ]

    for folder <- real,
        name <- File.ls!(Path.join(@root, folder)),
        path = Path.join(folder, name),
        path not in real and path not in private do
      File.mkdir_p!(Path.join(dir, folder))
      File.ln_s!(Path.join(@root, path), Path.join(dir, path))
    end

    python = System.get_env("ATLAS_CONFIG_PYTHON") || System.find_executable("python3")
    marker = Path.join(dir, "selected-python")
    local = Path.join(dir, ".venv-config/bin/python")
    write_python(local, python, marker, "local")
    system = Path.join(dir, "system/python3")
    write_python(system, python, marker, "system")
    override = Path.join(dir, "override/python")
    write_python(override, python, marker, "override")

    sockets = for _ <- 1..2, do: elem(:gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}]), 1)
    [rela_port, control_port] = Enum.map(sockets, &elem(:inet.port(&1), 1))
    Enum.each(sockets, &:gen_tcp.close/1)

    bin = AtlasE2E.Instance.rela_bin!()

    settings = %{
      "env" => "test",
      # Who decides what a person decides (the model names only the role).
      "actors" => %{"decider" => "melle"},
      "control" => %{"host" => "127.0.0.1", "port" => control_port},
      "rela" => %{
        "url" => "http://127.0.0.1:#{rela_port}/api/v1",
        "port" => rela_port,
        "data" => Path.join(dir, "store/rela"),
        "bin" => bin
      },
      "facts" => %{"data" => Path.join(dir, "store/beam")}
    }

    file = Path.join(dir, "test.json")
    File.write!(file, JSON.encode!(settings))
    # Seed only the private schema snapshot, using the test runner's known interpreter.
    {out, code} =
      System.cmd(
        python,
        [
          Path.join(dir, "platform/atlas_facts/rela/scripts/config.py"),
          "copy",
          "--data",
          settings["rela"]["data"]
        ],
        stderr_to_stdout: true
      )

    assert code == 0, out

    env = [
      {"ATLAS_ENV_FILE", file},
      {"ATLAS_NO_UPDATE", "1"},
      {"MIX_ENV", "dev"},
      {"ATLAS_CONFIG_PYTHON", nil},
      {"VIRTUAL_ENV", nil},
      {"PYTHONPATH", nil},
      {"PATH", Path.join(dir, "system") <> ":" <> System.get_env("PATH")}
    ]

    socket = "atlas-python-#{System.unique_integer([:positive])}"

    ctx = %{
      dir: dir,
      env: env,
      local: local,
      system: system,
      override: override,
      marker: marker,
      python: python,
      socket: socket
    }

    on_exit(fn ->
      AtlasE2E.Tui.kill_server(socket)
      ops(ctx, ["stop", "--rela"])
      File.rm_rf!(dir)
    end)

    ctx
  end

  defp quote_sh(text), do: "'" <> String.replace(text, "'", "'\\''") <> "'"

  defp write_python(path, python, marker, label) do
    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      "#!/bin/sh\nprintf '%s\\n' #{quote_sh(label)} >> #{quote_sh(marker)}\nexec #{quote_sh(python)} \"$@\"\n"
    )

    File.chmod!(path, 0o755)
  end

  defp ops(ctx, args) do
    System.cmd(Path.join(ctx.dir, "bin/atlas-ops"), args ++ ["--env", "test"],
      cd: System.tmp_dir!(),
      env: ctx.env,
      stderr_to_stdout: true
    )
  end

  defp status!(ctx) do
    {out, code} = ops(ctx, ["status"])
    assert code == 0, out
    assert out =~ "description: this build's", out
  end

  test "ordinary status and TUI startup discover the local Python without activation", ctx do
    # A system Python without PyYAML must not be chosen when the local one exists.
    File.write!(ctx.system, "#!/bin/sh\necho 'system Python has no yaml' >&2\nexit 73\n")
    File.chmod!(ctx.system, 0o755)
    status!(ctx)
    assert File.read!(ctx.marker) =~ "local"
    {out, code} = ops(ctx, ["restart"])
    assert code == 0, out
    assert out =~ "core ready"
    status!(ctx)

    # A private tmux server inherits the ordinary environment, with no Python override.
    command = quote_sh(Path.join(ctx.dir, "bin/atlas")) <> " tui --env test"

    {out, code} =
      System.cmd(
        "tmux",
        AtlasE2E.Tui.server(ctx.socket) ++
          [
            "new-session",
            "-d",
            "-s",
            "ordinary",
            "-x",
            "100",
            "-y",
            "30",
            command
          ],
        env: ctx.env,
        stderr_to_stdout: true
      )

    assert code == 0, out
    tui = %AtlasE2E.Tui{name: "ordinary", socket: ctx.socket, label: "ordinary"}
    screen = AtlasE2E.Scenario.ready(tui, 20_000)
    assert screen =~ "● connected"
    refute screen =~ "migrate that data"
    assert File.read!(ctx.marker) |> String.split("\n", trim: true) |> Enum.all?(&(&1 == "local"))
  end

  test "explicit Python override wins over project-local discovery", ctx do
    ctx = %{
      ctx
      | env:
          List.keystore(ctx.env, "ATLAS_CONFIG_PYTHON", 0, {"ATLAS_CONFIG_PYTHON", ctx.override})
    }

    status!(ctx)
    assert File.read!(ctx.marker) == "override\n"
  end

  test "system fallback remains when project-local Python is not executable", ctx do
    File.chmod!(ctx.local, 0o644)
    status!(ctx)
    assert File.read!(ctx.marker) == "system\n"
  end
end
