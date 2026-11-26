defmodule Model.GithubSyncTest do
  # rela's own GitHub sync (targets/rela/scripts/github.lua), run by the pinned rela against
  # a fake GitHub API: merged is final, closed is not. A pull recorded closed that GitHub
  # lists open again (reopened) is read again, with its mergeability and checks. Its checks
  # and mergeability go with the head they were read for (pr_checks_head, IS-Atlas-120); the
  # pull's head becomes the issue's (pr_head) only when none is recorded or someone else
  # pushed onto it, never when GitHub has not caught up with Code's push yet. What failed
  # (pr_checks_failure) holds only the failing lines of a failed job's log (IS-Atlas-124).
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
        # A job's log: plain text, as GitHub's storage answers it.
        {:ok, {:text, body}} ->
          conn
          |> put_resp_content_type("text/plain")
          |> send_resp(200, body)

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
  # Pull 7: GitHub still has the head before Code's push (@earlier, red), behind @pushed.
  @earlier "1111111111111111111111111111111111111111"
  @pushed "3333333333333333333333333333333333333333"
  # Pull 8: someone pushed @theirs onto Code's @sha.
  @theirs "2222222222222222222222222222222222222222"

  defp open_pull(number, head),
    do: %{
      "number" => number,
      "state" => "open",
      "merged" => false,
      "mergeable" => true,
      "mergeable_state" => "clean",
      "title" => "Pull #{number}",
      "draft" => false,
      "head" => %{"sha" => head}
    }

  defp passed,
    do: %{
      "total_count" => 1,
      "check_runs" => [%{"name" => "ci", "status" => "completed", "conclusion" => "success"}]
    }

  @no_statuses %{"total_count" => 0, "statuses" => []}

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

  defp routes,
    do:
      Map.merge(@routes, %{
        "/repos/o/r/pulls/6" => open_pull(6, @sha),
        "/repos/o/r/pulls/7" => open_pull(7, @earlier),
        "/repos/o/r/pulls/8" => open_pull(8, @theirs),
        "/repos/o/r/commits/#{@earlier}/check-runs" => %{
          "total_count" => 1,
          "check_runs" => [
            %{"id" => 70, "name" => "ci", "status" => "completed", "conclusion" => "failure"}
          ]
        },
        "/repos/o/r/commits/#{@earlier}/status" => @no_statuses,
        "/repos/o/r/commits/#{@theirs}/check-runs" => passed(),
        "/repos/o/r/commits/#{@theirs}/status" => @no_statuses,
        # GitHub has not caught up with Code's push onto 7; 8 has theirs on top of Code's.
        "/repos/o/r/pulls/7/commits" => [%{"sha" => @earlier}],
        "/repos/o/r/pulls/8/commits" => [%{"sha" => @sha}, %{"sha" => @theirs}]
      })

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

  # The fake GitHub answering `routes`; its port.
  defp github(routes) do
    {:ok, _} = Application.ensure_all_started(:bandit)

    server =
      start_supervised!(
        {Bandit, plug: {FakeGitHub, %{test: self(), routes: routes}}, ip: :loopback, port: 0}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    port
  end

  # The running closure: the description the model generates (`mix model.gen --out`) with
  # the hand-written schedules and scripts, without the ACL and flows a running rela leaves
  # out (scripts/config.py). `secrets`: more of .rela/secrets.yaml than GitHub's API.
  defp project(tmp, port, secrets \\ "") do
    dir = Path.join(tmp, "rela")
    Mix.Tasks.Model.Gen.run(["--out", dir])
    File.cp!(Path.expand("../targets/rela/schedules.yaml"), Path.join(dir, "schedules.yaml"))
    File.cp_r!(Path.expand("../targets/rela/scripts"), Path.join(dir, "scripts"))
    File.rm!(Path.join(dir, "acl.yaml"))
    File.rm!(Path.join(dir, "flows.yaml"))
    File.mkdir_p!(Path.join(dir, ".rela"))

    File.write!(
      Path.join(dir, ".rela/secrets.yaml"),
      ~s(github_api: "http://127.0.0.1:#{port}"\n) <> secrets
    )

    dir
  end

  defp sync(dir) do
    assert {_, 0} =
             rela(dir, [
               "--run-as",
               "integration:github",
               "script",
               Path.join(dir, "scripts/github.lua")
             ])
  end

  test "a pull recorded closed is read again once GitHub lists it open; merged is final",
       %{tmp_dir: tmp} do
    port = github(routes())

    dir = project(tmp, port)

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

    # Its head is the one Code pushed: written with its status, kept.
    create(dir, "issue", "IS-Atlas-06",
      title: "Current",
      pr_url: url.(6),
      pr_state: "open",
      pr_head: @sha
    )

    # Code pushed @pushed; GitHub still answers the head before it, red.
    create(dir, "issue", "IS-Atlas-07",
      title: "Pushed",
      pr_url: url.(7),
      pr_state: "open",
      pr_head: @pushed,
      pr_checks: "success",
      pr_checks_head: @pushed
    )

    # Someone else pushed onto Code's head.
    create(dir, "issue", "IS-Atlas-08",
      title: "Theirs",
      pr_url: url.(8),
      pr_state: "open",
      pr_head: @sha
    )

    sync(dir)

    assert %{"pr_state" => "open", "pr_mergeable" => "conflicting", "pr_checks" => "success"} =
             one = properties(dir, "IS-Atlas-01")

    # No head was recorded (opened before Code answered with it): the pull's is taken.
    assert {one["pr_checks_head"], one["pr_head"]} == {@sha, @sha}

    assert %{"pr_checks" => "success", "pr_checks_head" => @sha, "pr_head" => @sha} =
             properties(dir, "IS-Atlas-06")

    # The red of the head before Code's push is written for that head; Code's stays the
    # issue's, so the CI gate does not take it (IS-Atlas-120).
    assert %{
             "pr_checks" => "failure",
             "pr_checks_head" => @earlier,
             "pr_head" => @pushed,
             "pr_checks_failure" => "Failing checks on 1111111: ci" <> _
           } = properties(dir, "IS-Atlas-07")

    # Someone else's push, ahead of Code's head: the CI gate goes on with theirs.
    assert %{"pr_checks" => "success", "pr_checks_head" => @theirs, "pr_head" => @theirs} =
             properties(dir, "IS-Atlas-08")

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

    # Only a pull whose head differs from the recorded one has its commits read.
    assert_received {:github, "GET", "/repos/o/r/pulls/7/commits?per_page=100&page=1"}
    assert_received {:github, "GET", "/repos/o/r/pulls/8/commits?per_page=100&page=1"}
    refute_received {:github, "GET", "/repos/o/r/pulls/1/commits" <> _}
    refute_received {:github, "GET", "/repos/o/r/pulls/6/commits" <> _}
  end

  # A recorded job log of `bin/check` (GitHub's timestamps on every line): one failing ExUnit
  # test among passing ones whose captured output holds stack traces, one of them right
  # before ExUnit's summary.
  @job_log [
             "##[group]Run bin/check",
             "Running ExUnit with seed: 4711, max_cases: 16",
             "....",
             "12:00:01.123 [error] GenServer #PID<0.512.0> terminating",
             "** (RuntimeError) boom in a passing test",
             "    (atlas_flow 0.1.0) lib/atlas_flow/runs.ex:12: AtlasFlow.Runs.go/1",
             "    (stdlib 6.0) gen_server.erl:2345: :gen_server.try_handle_call/4",
             "Last message: :go",
             "FAIL is only a word in a passing test's output",
             "...",
             "  1) test a pull's body says what its CI fix changed (AtlasCode.EffectsTest)",
             "     test/effects_test.exs:257",
             "     Assertion with =~ failed",
             "     code:  assert body =~ \"CI fix 1\"",
             "     left:  \"One typo.\"",
             "     right: \"CI fix 1\"",
             "     stacktrace:",
             "       test/effects_test.exs:300: (test)",
             "",
             "......",
             "** (EXIT from #PID<0.640.0>) shutdown: a second passing test's trace",
             "    (elixir 1.18.4) lib/task/supervised.ex:101: Task.Supervised.invoke_mfa/2",
             "Finished in 3.2 seconds (1.1s async, 2.1s sync)",
             "40 tests, 1 failure",
             "Randomized with seed 4711",
             "##[error]Process completed with exit code 2."
           ]
           |> Enum.map_join("\n", &("2026-11-25T10:00:00.1234567Z " <> &1))

  test "what failed holds the failing ExUnit test and the end of its step, none of the passing tests' traces (IS-Atlas-124)",
       %{tmp_dir: tmp} do
    port =
      github(%{
        "/repos/o/r/pulls/3" => open_pull(3, @sha),
        "/repos/o/r/commits/#{@sha}/check-runs" => %{
          "total_count" => 1,
          "check_runs" => [
            %{
              "id" => 30,
              "name" => "check",
              "status" => "completed",
              "conclusion" => "failure",
              "html_url" => "https://github.com/o/r/actions/runs/1/job/30"
            }
          ]
        },
        "/repos/o/r/commits/#{@sha}/status" => @no_statuses,
        "/repos/o/r/actions/jobs/30/logs" => {:text, @job_log}
      })

    # A token reads job logs; without github_write nothing is written to GitHub.
    dir = project(tmp, port, ~s(github_token: "test-token"\n))

    create(dir, "issue", "IS-Atlas-03",
      title: "Red",
      pr_url: "https://github.com/o/r/pull/3",
      pr_state: "open",
      pr_head: @sha
    )

    sync(dir)

    assert %{"pr_checks" => "failure", "pr_checks_failure" => failure} =
             properties(dir, "IS-Atlas-03")

    assert_received {:github, "GET", "/repos/o/r/actions/jobs/30/logs"}
    assert failure =~ "Failing checks on 4700aac: check"

    # The failure, with every line under it, and the end of the failing step.
    for line <- [
          "  1) test a pull's body says what its CI fix changed (AtlasCode.EffectsTest)",
          "     test/effects_test.exs:257",
          "     right: \"CI fix 1\"",
          "       test/effects_test.exs:300: (test)",
          "Finished in 3.2 seconds",
          "40 tests, 1 failure",
          "##[error]Process completed with exit code 2."
        ],
        do: assert(failure =~ line, failure)

    # None of what the passing tests printed.
    for line <- [
          "boom in a passing test",
          "lib/atlas_flow/runs.ex:12",
          "gen_server.erl",
          "Last message",
          "FAIL is only a word",
          "a second passing test's trace",
          "Task.Supervised",
          "GenServer #PID"
        ],
        do: refute(failure =~ line, failure)
  end
end
