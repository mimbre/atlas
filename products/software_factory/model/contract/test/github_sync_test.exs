defmodule Model.GithubSyncTest do
  # rela's own GitHub sync (targets/rela/scripts/github.lua), run by the pinned rela against
  # a fake GitHub API: merged is final, closed is not. A pull recorded closed that GitHub
  # lists open again (reopened) is read again, with its mergeability and checks.
  use ExUnit.Case, async: false
  @moduletag :rela
  @moduletag :tmp_dir

  defmodule FakeGitHub do
    @behaviour Plug
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, %{test: test, routes: routes}) do
      query = if conn.query_string == "", do: "", else: "?" <> conn.query_string
      send(test, {:github, conn.method, conn.request_path <> query})

      case Map.fetch(routes, conn.request_path) do
        {:ok, body} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, JSON.encode!(body))

        :error ->
          send_resp(conn, 404, "{}")
      end
    end
  end

  @sha "4700aac3d6324787f005dcf0d3bbc78ec24b2299"

  @routes %{
    # Open on GitHub: 1 (recorded closed: reopened) and 5 (its issue closed in Atlas).
    "/repos/o/r/pulls" => [%{"number" => 1}, %{"number" => 5}],
    "/repos/o/r/pulls/1" => %{
      "number" => 1,
      "state" => "open",
      "merged" => false,
      "mergeable" => false,
      "mergeable_state" => "dirty",
      "title" => "One",
      "draft" => false,
      "head" => %{"sha" => @sha}
    },
    "/repos/o/r/pulls/2" => %{"number" => 2, "state" => "closed", "merged" => false},
    "/repos/o/r/pulls/4" => %{"number" => 4, "state" => "closed", "merged" => true},
    "/repos/o/r/pulls/5" => %{"number" => 5, "state" => "open", "merged" => false},
    "/repos/o/r/commits/#{@sha}/check-runs" => %{
      "total_count" => 1,
      "check_runs" => [%{"name" => "ci", "status" => "completed", "conclusion" => "success"}]
    },
    "/repos/o/r/commits/#{@sha}/status" => %{"total_count" => 0, "statuses" => []}
  }

  defp rela(dir, args, opts \\ [stderr_to_stdout: true]) do
    Path.join(System.fetch_env!("ATLAS_RELA_BIN"), "rela")
    |> System.cmd(["--project", dir | args], opts)
  end

  defp create(dir, type, id, properties) do
    props = Enum.flat_map(properties, fn {k, v} -> ["-P", "#{k}=#{v}"] end)
    assert {_, 0} = rela(dir, ["create", type, "--id", id, "-q" | props])
  end

  defp properties(dir, id) do
    {out, 0} = rela(dir, ["show", id, "-o", "json"], [])
    JSON.decode!(out)["entity"]["properties"]
  end

  test "a pull recorded closed is read again once GitHub lists it open; merged is final",
       %{tmp_dir: tmp} do
    {:ok, _} = Application.ensure_all_started(:bandit)

    server =
      start_supervised!(
        {Bandit, plug: {FakeGitHub, %{test: self(), routes: @routes}}, ip: :loopback, port: 0}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    # The running closure: the description, schedules and scripts, without the ACL and
    # flows a running rela leaves out (scripts/config.py).
    dir = Path.join(tmp, "rela")
    File.cp_r!(Path.expand("../targets/rela"), dir)
    File.rm!(Path.join(dir, "acl.yaml"))
    File.rm!(Path.join(dir, "flows.yaml"))
    File.mkdir_p!(Path.join(dir, ".rela"))

    File.write!(
      Path.join(dir, ".rela/secrets.yaml"),
      ~s(github_api: "http://127.0.0.1:#{port}"\n)
    )

    url = &"https://github.com/o/r/pull/#{&1}"

    create(dir, "issue", "IS-Atlas-01",
      title: "Reopened",
      pr_url: url.(1),
      pr_state: "closed",
      pr_mergeable: "clean"
    )

    create(dir, "issue", "IS-Atlas-02", title: "Closed", pr_url: url.(2), pr_state: "closed")
    create(dir, "issue", "IS-Atlas-04", title: "Merged", pr_url: url.(4), pr_state: "merged")

    create(dir, "issue", "IS-Atlas-05",
      title: "Closed in Atlas",
      pr_url: url.(5),
      pr_state: "closed",
      gate_result: "close"
    )

    create(dir, "pull_request", "PR-o-r-1", url: url.(1), state: "closed")

    assert {_, 0} =
             rela(dir, [
               "--run-as",
               "integration:github",
               "script",
               Path.join(dir, "scripts/github.lua")
             ])

    assert %{"pr_state" => "open", "pr_mergeable" => "conflicting", "pr_checks" => "success"} =
             properties(dir, "IS-Atlas-01")

    assert properties(dir, "PR-o-r-1")["state"] == "open"
    assert properties(dir, "IS-Atlas-02")["pr_state"] == "closed"
    assert properties(dir, "IS-Atlas-04")["pr_state"] == "merged"
    assert properties(dir, "IS-Atlas-05")["pr_state"] == "closed"

    # One list of the repository's open pulls for the run; a pull still closed, a merged one
    # and the pull of an issue closed in Atlas are not read.
    assert_received {:github, "GET", "/repos/o/r/pulls?state=open&per_page=100&page=1"}
    refute_received {:github, "GET", "/repos/o/r/pulls?" <> _}
    refute_received {:github, "GET", "/repos/o/r/pulls/2"}
    refute_received {:github, "GET", "/repos/o/r/pulls/4"}
    refute_received {:github, "GET", "/repos/o/r/pulls/5"}
  end
end
