defmodule AtlasE2E.DeployPrerequisitesTest do
  use ExUnit.Case, async: false
  @moduletag timeout: 60_000
  @root Path.expand("../..", __DIR__)

  for environment <- ["test", "prod"] do
    test "#{environment} deployment provisions its own pinned validator before remote I/O" do
      environment = unquote(environment)
      python = System.get_env("ATLAS_CONFIG_PYTHON") || System.find_executable("python3")

      {json, 0} =
        System.cmd(python, [
          "-c",
          "import yaml,json,sys; print(json.dumps(yaml.safe_load(open(sys.argv[1]))['jobs']))",
          Path.join(@root, ".github/workflows/ci.yml")
        ])

      job = JSON.decode!(json)["deploy-" <> environment]

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
        {"PATH", Path.join(dir, "bin") <> ":" <> System.get_env("PATH")}
      ]

      cache = AtlasE2E.Instance.rela_bin!()

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

      assert File.read!(marker) =~ "deploy"
      refute File.exists?(Path.join(dir, "data")), "install mode must never start a store"
    end
  end
end
