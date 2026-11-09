defmodule AtlasE2E.DeployPrerequisitesTest do
  use ExUnit.Case, async: false
  @moduletag timeout: 60_000
  @root Path.expand("../..", __DIR__)

  defp jobs do
    python = System.get_env("ATLAS_CONFIG_PYTHON") || System.find_executable("python3")

    {json, 0} =
      System.cmd(python, [
        "-c",
        "import yaml,json,sys; print(json.dumps(yaml.safe_load(open(sys.argv[1]))['jobs']))",
        Path.join(@root, ".github/workflows/ci.yml")
      ])

    JSON.decode!(json)
  end

  # A flyctl stand-in that notes each command, answers `secrets list` with secrets, an app's
  # machines with none, and stops at anything else (a deploy, an ssh) with exit 73.
  defp fly_stub(secrets) do
    dir = Path.join(System.tmp_dir!(), "atlas-deploy-guard-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    marker = Path.join(dir, "calls")

    File.write!(Path.join(dir, "flyctl"), """
    #!/bin/sh
    echo "$1" >> '#{marker}'
    case "$1" in
      status) echo '{"Machines":[]}' ;;
      machine) echo '[]' ;;
      secrets) echo '#{secrets}' ;;
      *) exit 73 ;;
    esac
    """)

    File.chmod!(Path.join(dir, "flyctl"), 0o755)
    {dir, marker}
  end

  defp deploy(environment, dir) do
    System.cmd("bash", [Path.join(@root, "fly/deploy.sh"), environment, "private-check"],
      cd: @root,
      env: [
        {"ATLAS_FLY_TOKEN_RELA", nil},
        {"ATLAS_FLY_TOKEN_CORE", nil},
        {"FLY_API_TOKEN", nil},
        {"ATLAS_CONTROL_TEST_HOST", "test.security-fixture.ts.net"},
        {"ATLAS_CONTROL_PROD_HOST", "prod.security-fixture.ts.net"},
        {"ATLAS_DEPLOY_RECOVERY", Path.join(dir, "captured-pair")},
        {"PATH", dir <> ":" <> System.get_env("PATH")}
      ],
      stderr_to_stdout: true
    )
  end

  test "without the core's tailnet key nothing is deployed: no deploy, no ssh, nothing changed" do
    for secrets <- ["[]", ~s([{"Name":"OTHER"}]), ~s([{"name":"OTHER"}])] do
      {dir, marker} = fly_stub(secrets)
      assert {out, code} = deploy("test", dir)
      assert code not in [0, 73], secrets <> ": " <> out
      assert File.read!(marker) == "secrets\n", secrets
    end
  end

  test "the core's tailnet key counts in either field casing of flyctl's JSON" do
    for secrets <- [~s([{"Name":"TS_AUTHKEY"}]), ~s([{"name":"OTHER"},{"name":"TS_AUTHKEY"}])] do
      {dir, marker} = fly_stub(secrets)
      assert {out, status} = deploy("test", dir)
      assert status != 0
      assert File.read!(marker) =~ "machine", secrets <> ": " <> out
      refute File.read!(marker) =~ "deploy"
    end
  end

  test "each deploy job checks CI's tailnet key and joins the tailnet before it deploys" do
    jobs = jobs()

    for name <- ["deploy-test", "deploy-prod"] do
      steps = jobs[name]["steps"]
      at = fn found -> Enum.find_index(steps, found) end
      run = fn step -> if is_binary(step["run"]), do: step["run"], else: "" end

      check =
        at.(
          &(run.(&1) =~ "$TS_AUTHKEY_CI" and &1["env"]["TS_AUTHKEY_CI"] =~ "secrets.TS_AUTHKEY_CI")
        )

      join =
        at.(
          &(String.starts_with?(&1["uses"] || "", "tailscale/github-action@") and
              &1["with"]["authkey"] =~ "secrets.TS_AUTHKEY_CI")
        )

      deploy = at.(&(run.(&1) =~ ~r"fly/deploy(-test-current)?\.sh"))
      assert is_integer(check) and is_integer(join) and is_integer(deploy), name
      assert check < join and join < deploy, name
    end
  end

  for environment <- ["test", "prod"] do
    test "#{environment} deployment provisions its own pinned validator before remote I/O" do
      environment = unquote(environment)
      python = System.get_env("ATLAS_CONFIG_PYTHON") || System.find_executable("python3")
      job = jobs()["deploy-" <> environment]

      dir =
        Path.join(System.tmp_dir!(), "atlas-deploy-tools-#{System.unique_integer([:positive])}")

      File.mkdir_p!(Path.join(dir, "bin"))
      on_exit(fn -> File.rm_rf!(dir) end)
      marker = Path.join(dir, "remote-boundary")
      # No Fly command can reach the network. Exit distinctly at the deployment boundary.
      fly = Path.join(dir, "bin/flyctl")

      File.write!(fly, """
      #!/bin/sh
      echo "$1" >> '#{marker}'
      case "$1" in
        status) echo '{"Machines":[]}' ;;
        secrets) echo '[{"Name":"TS_AUTHKEY"}]' ;;
        *) exit 73 ;;
      esac
      """)

      File.chmod!(fly, 0o755)

      local_env =
        Map.new(job["env"] || %{}, fn {key, value} ->
          {key, String.replace(value, "${{ github.workspace }}", dir)}
        end)

      bin = local_env["ATLAS_RELA_BIN"] || Path.join(dir, "missing-binaries")

      assert String.starts_with?(Path.expand(bin), Path.expand(dir) <> "/"),
             "the CLI must be job-local"

      env = [
        {"ATLAS_E2E_RELA_BIN", nil},
        {"ATLAS_RELA_BIN", bin},
        {"ATLAS_RELA_DATA", Path.join(dir, "data")},
        {"ATLAS_RELA_PORT", "0"},
        {"ATLAS_CONFIG_PYTHON", python},
        {"ATLAS_FLY_TOKEN_RELA", nil},
        {"ATLAS_FLY_TOKEN_CORE", nil},
        {"FLY_API_TOKEN", nil},
        {"ATLAS_CONTROL_TEST_HOST", "test.security-fixture.ts.net"},
        {"ATLAS_CONTROL_PROD_HOST", "prod.security-fixture.ts.net"},
        {"ATLAS_DEPLOY_RECOVERY", Path.join(dir, "captured-pair")},
        {"PATH", Path.join(dir, "bin") <> ":" <> System.get_env("PATH")}
      ]

      cache =
        System.get_env("ATLAS_E2E_RELA_BIN") ||
          Path.join(System.user_home!(), ".local/share/atlas/test/bin")

      # Execute the workflow's real installer steps, with the already checksum-pinned
      # test cache available to avoid a redundant network download. Without the step,
      # the validator remains absent in this isolated job, even if another job has it.
      for step <- job["steps"],
          run = step["run"],
          is_binary(run),
          String.contains?(run, "start-test.sh install") do
        File.mkdir_p!(bin)

        for file <- ["rela", "rela-server"] do
          File.cp!(Path.join(cache, file), Path.join(bin, file))
          File.chmod!(Path.join(bin, file), 0o755)
        end

        {out, code} = System.cmd("bash", ["-c", run], cd: @root, env: env, stderr_to_stdout: true)
        assert code == 0, out
      end

      {out, code} =
        System.cmd("bash", [Path.join(@root, "fly/deploy.sh"), environment, "private-check"],
          cd: @root,
          env: env,
          stderr_to_stdout: true
        )

      assert code == 73,
             "deployment must pass actual assembly validation before the mocked remote boundary:\n" <>
               out

      assert File.read!(marker) =~ "machine"
      refute File.exists?(Path.join(dir, "data")), "install mode must never start a store"
    end
  end
end
