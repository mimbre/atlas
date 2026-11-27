defmodule AtlasE2E.DeployOrderTest do
  use ExUnit.Case, async: true
  @moduletag timeout: 15_000
  @root Path.expand("../../../..", __DIR__)

  setup do
    python = System.get_env("ATLAS_CONFIG_PYTHON") || System.find_executable("python3")

    {json, 0} =
      System.cmd(python, [
        "-c",
        "import yaml,json,sys; print(json.dumps(yaml.safe_load(open(sys.argv[1]))['jobs']))",
        Path.join(@root, ".github/workflows/ci.yml")
      ])

    jobs = JSON.decode!(json)
    job = jobs["deploy-test"]
    step = Enum.find(job["steps"], &String.starts_with?(&1["name"] || "", "Deploy test ("))
    dir = Path.join(System.tmp_dir!(), "atlas-deploy-order-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    work = Path.join(dir, "work")
    origin = Path.join(dir, "origin.git")
    File.mkdir_p!(Path.join(work, "platform/ops"))
    File.mkdir_p!(Path.join(work, "products/software_factory/environments"))
    File.write!(Path.join(work, "products/software_factory/environments/test.json"), """
    {"fly":{"app":"core","rela_app":"rela"}}
    """)
    File.mkdir_p!(Path.join(dir, "bin"))
    File.write!(Path.join(dir, "bin/flyctl"), """
    #!/bin/sh
    set -eu
    if [ "${FLY_FAIL:-}" = "$3" ]; then exit 1; fi
    if [ "$3" = core ]; then tag="${CORE_TAG:-unknown}"; else tag="${RELA_TAG:-unknown}"; fi
    printf '{"Machines":[{"image_ref":{"tag":"%s"}}]}' "$tag"
    """)
    File.chmod!(Path.join(dir, "bin/flyctl"), 0o755)
    git!(dir, ["init", "--bare", origin])
    git!(work, ["init", "-b", "develop"])
    git!(work, ["config", "user.name", "Deployment fixture"])
    git!(work, ["config", "user.email", "fixture@example.invalid"])
    git!(work, ["remote", "add", "origin", origin])

    # The real workflow command runs, but its only remote/mutation boundary is a
    # local recorder. No Fly invocation, credentials, client, Facts or model.
    File.write!(Path.join(work, "platform/ops/deploy.sh"), """
    #!/bin/sh
    set -eu
    printf 'rela %s\n' "$2" >> "$DEPLOY_LOG"
    if [ -n "${PAIR_READY:-}" ]; then
      touch "$PAIR_READY"
      while [ ! -e "$PAIR_RELEASE" ]; do sleep 0.01; done
    fi
    printf 'core %s\n' "$2" >> "$DEPLOY_LOG"
    """)

    File.chmod!(Path.join(work, "platform/ops/deploy.sh"), 0o755)
    gate = Path.join(@root, "platform/ops/deploy-test-current.sh")

    if File.exists?(gate),
      do: File.cp!(gate, Path.join(work, "platform/ops/deploy-test-current.sh"))

    git!(work, ["add", "."])
    git!(work, ["commit", "-m", "older source"])
    old = git!(work, ["rev-parse", "HEAD"])
    git!(work, ["push", "origin", "develop"])

    %{
      work: work,
      origin: origin,
      dir: dir,
      old: old,
      run: step["run"],
      job: job,
      jobs: jobs,
      log: Path.join(dir, "pairs")
    }
  end

  test "late older CI cannot replace the already delivered newer pair", c do
    newer = advance(c)
    assert {_, 0} = deliver(c, newer)
    git!(c.work, ["checkout", "--detach", c.old])
    {out, code} = deliver(c, c.old)
    assert code == 0, out
    assert lines(c) == ["rela develop-#{newer}", "core develop-#{newer}"]
    assert out =~ "skipping stale"
  end

  test "current detached checkout is admitted once for the complete pair", c do
    git!(c.work, ["checkout", "--detach", c.old])
    assert {_, 0} = deliver(c, c.old)
    assert lines(c) == ["rela develop-#{c.old}", "core develop-#{c.old}"]
  end

  test "stale Fly change followed by a client-only head still deploys", c do
    fly_change = advance(c)
    File.mkdir_p!(Path.join(c.work, "platform/clients/apple"))
    File.write!(Path.join(c.work, "platform/clients/apple/client"), "client")
    git!(c.work, ["add", "."])
    git!(c.work, ["commit", "-m", "client only"])
    git!(c.work, ["push", "origin", "HEAD:develop"])
    client_head = git!(c.work, ["rev-parse", "HEAD"])
    git!(c.work, ["checkout", "--detach", fly_change])
    assert {out, 0} = deliver(c, fly_change, deployed(c.old))
    assert out =~ "skipping stale"
    git!(c.work, ["checkout", "--detach", client_head])
    assert {_, 0} = deliver(c, client_head, deployed(c.old))
    assert lines(c) == ["rela develop-#{client_head}", "core develop-#{client_head}"]
    assert {out, 0} = deliver(c, client_head, deployed(client_head))
    assert out =~ "already has the Fly-relevant tree"
    assert length(lines(c)) == 2
  end

  test "client-only changes do not redeploy an equivalent pair", c do
    File.mkdir_p!(Path.join(c.work, "platform/clients/apple"))
    File.write!(Path.join(c.work, "platform/clients/apple/client"), "client")
    git!(c.work, ["add", "."])
    git!(c.work, ["commit", "-m", "client only"])
    git!(c.work, ["push", "origin", "HEAD:develop"])
    current = git!(c.work, ["rev-parse", "HEAD"])
    assert {out, 0} = deliver(c, current, deployed(c.old))
    assert out =~ "already has the Fly-relevant tree"
    assert lines(c) == []
  end

  test "unknown or mismatched deployed labels reconcile, while status failure refuses", c do
    assert {_, 0} = deliver(c, c.old, [{"CORE_TAG", "develop-#{c.old}"}, {"RELA_TAG", "unknown"}])
    assert length(lines(c)) == 2
    assert {_, code} = deliver(c, c.old, [{"FLY_FAIL", "core"}])
    assert code != 0
    assert length(lines(c)) == 2
  end

  defp deployed(sha), do: [{"CORE_TAG", "develop-#{sha}"}, {"RELA_TAG", "develop-#{sha}"}]

  test "unavailable or missing remote head refuses before any deployment", c do
    for remote <- [Path.join(c.dir, "does-not-exist"), Path.join(c.dir, "empty.git")] do
      if String.ends_with?(remote, "empty.git"), do: git!(c.dir, ["init", "--bare", remote])
      git!(c.work, ["remote", "set-url", "origin", remote])
      {_, code} = deliver(c, c.old)
      assert code != 0
      assert lines(c) == []
    end
  end

  test "mismatched or malformed build identity refuses before deployment", c do
    for sha <- [String.duplicate("0", 40), "not-a-commit"] do
      {_, code} = deliver(c, sha)
      assert code != 0
      assert lines(c) == []
    end
  end

  test "new head after admission does not interrupt the in-flight paired update", c do
    ready = Path.join(c.dir, "ready")
    release = Path.join(c.dir, "release")

    task =
      Task.async(fn -> deliver(c, c.old, [{"PAIR_READY", ready}, {"PAIR_RELEASE", release}]) end)

    # Always release the bounded fixture, even when an assertion fails.
    try do
      wait_for(ready, System.monotonic_time(:millisecond) + 3_000)
      newer = advance(c)
      File.touch!(release)
      assert {_, 0} = Task.await(task, 5_000)
      assert lines(c) == ["rela develop-#{c.old}", "core develop-#{c.old}"]
      assert {_, 0} = deliver(c, newer)

      assert lines(c) == [
               "rela develop-#{c.old}",
               "core develop-#{c.old}",
               "rela develop-#{newer}",
               "core develop-#{newer}"
             ]
    after
      File.touch!(release)
      if Process.alive?(task.pid), do: Task.await(task, 5_000)
    end
  end

  test "whole test pair is serialized without cancelling running or pending jobs", c do
    assert c.job["concurrency"] == %{
             "group" => "fly-deploy-test",
             "cancel-in-progress" => false,
             "queue" => "max"
           }
    refute c.job["if"] =~ "outputs.deploy"
    checkout = Enum.find(c.job["steps"], &(&1["uses"] == "actions/checkout@v4"))
    assert checkout["with"]["fetch-depth"] == 0

    assert Enum.any?(
             c.jobs["deploy-prod"]["steps"],
             &String.contains?(&1["run"] || "", "platform/ops/deploy.sh prod")
           )
  end

  defp advance(c) do
    File.write!(Path.join(c.work, "newer"), "next source")
    git!(c.work, ["add", "."])
    git!(c.work, ["commit", "-m", "newer source"])
    git!(c.work, ["push", "origin", "HEAD:develop"])
    git!(c.work, ["rev-parse", "HEAD"])
  end

  defp deliver(c, sha, extra \\ []) do
    System.cmd("bash", ["-c", c.run],
      cd: c.work,
      stderr_to_stdout: true,
      env:
        Map.merge(
          %{
            "GITHUB_SHA" => sha,
            "DEPLOY_LOG" => c.log,
            "PAIR_READY" => nil,
            "PAIR_RELEASE" => nil,
            "ATLAS_FLY_TOKEN_RELA" => "unused-fixture",
            "ATLAS_FLY_TOKEN_CORE" => "unused-fixture",
            "PATH" => Path.join(c.dir, "bin") <> ":" <> System.fetch_env!("PATH"),
            "CORE_TAG" => nil,
            "RELA_TAG" => nil,
            "FLY_FAIL" => nil
          },
          Map.new(extra)
        )
        |> Map.to_list()
    )
  end

  defp lines(c),
    do:
      if(File.exists?(c.log),
        do: c.log |> File.read!() |> String.split("\n", trim: true),
        else: []
      )

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    String.trim(out)
  end

  defp wait_for(path, deadline) do
    unless File.exists?(path) do
      assert System.monotonic_time(:millisecond) < deadline, "pair did not reach admission"
      Process.sleep(10)
      wait_for(path, deadline)
    end
  end
end
