defmodule AtlasRuntime.Boundary.RepositoryUrlTest do
  # D44, designer decision 2026-11-17 (repository.url): a client without choose_path names a
  # `repository` workspace only as https://<host>/… with host in the policy's
  # `repository_hosts` (default ["github.com"]). A local path, file://, git@ or a host not
  # listed is `refused: not_permitted` (no detail), before anything is stored or any helper
  # runs. A socket client (choose_path) keeps today's behaviour.
  use ExUnit.Case, async: false

  import AtlasRuntime.WorkHarness
  alias AtlasRuntime.Boundary.Work, as: F
  alias AtlasRuntime.WorkHarness.SlowStart

  @moduletag capture_log: true

  # The most a TCP token can hold (§8.1): no choose_slot, no choose_path.
  @token {"token:flow", [:submit, :cancel, :read, :read_all]}

  # The bench's policy, with repository workspaces permitted; `repository_hosts` left out,
  # so the default applies.
  @policy %{
    "profiles" => %{
      "light_work" => %{
        "permissions" => ["read-only", "dedicated-repository"],
        "cost_classes" => ["standard"],
        "options" => [%{"provider" => "openai", "harness" => "codex", "model" => "gpt-test"}]
      }
    }
  }

  defp repository(bench, instructions, url) do
    request(bench, instructions, %{
      workspace: %{kind: "repository", url: url, branch: "task/x", base: "develop"}
    })
  end

  # The core with every Service start held (`SlowStart`): an accepted work never reaches the
  # helper, so nothing is cloned.
  defp held!(bench) do
    stop_work()
    {:ok, slow} = GenServer.start(SlowStart, {bench.service, self()})
    on_exit(fn -> Process.exit(slow, :kill) end)
    start_work!(%{bench | service: slow}, heartbeat_ms: 60_000)
  end

  test "a token client is refused a local path, file://, git@ and an unlisted https host" do
    bench = start!(@policy)
    source = Path.join(bench.workspace, "source.git")
    File.mkdir_p!(source)

    for url <- [
          source,
          "file://" <> source,
          "git@github.com:owner/repo.git",
          "https://example.com/owner/repo.git"
        ] do
      assert %F.Outcome.Refused{reason: :not_permitted, detail: nil} =
               F.submit(@token, repository(bench, "complete #{url}", url)),
             url
    end

    assert %F.Outcome.Works{works: []} = F.list_work(@token, %{})
    assert launches(bench) == []
  end

  test "a token client is accepted with https://github.com/…" do
    bench = start!(@policy)
    held!(bench)
    url = "https://github.com/owner/repo.git"

    assert %F.Outcome.Accepted{work: work} =
             F.submit(@token, repository(bench, "complete from github", url))

    assert %F.Repository{url: ^url} = work.request.workspace
    assert work.client == "token:flow"
    assert_receive :start_held, 5_000
  end

  test "a socket client is still accepted with a local path" do
    bench = start!(@policy)
    held!(bench)
    local = client("local:me")
    assert :choose_path in elem(local, 1)
    source = Path.join(bench.workspace, "source.git")
    File.mkdir_p!(source)

    assert %F.Outcome.Accepted{work: work} =
             F.submit(local, repository(bench, "complete from a local path", source))

    assert %F.Repository{url: ^source} = work.request.workspace
    assert_receive :start_held, 5_000
  end
end
