# Native proof of slices 8 and 9: the pull request and the issue on Flow's durable runs, in
# place of the old flows review_and_merge and build_and_merge, against a private Rela and real Facts, with the model compiled
# for the test environment and a manual clock. Owns and stops its private Rela and Facts.
# MIX_ENV=test mix run integration/flow_delivery_native.exs PRIVATE_DIR RELA_BIN_DIR
#
# It proves: merged, closed and open pull requests are imported as the table says (history
# completes as it was and nothing is written on it; an open one with outcomes joins its
# wait; any other open one starts its checks); the run, not the old flow, owns every
# pull request; restart while waiting moves nothing; a failed test sends it back; a new
# revision starts the checks again and the replaced revision's late verdict counts for
# nothing; review and test on the current revision together lead to integrating, once,
# across a Facts restart between the verdict and its reconcile.
# The integrate effect, through Code's receiver (AtlasCode.Effects.Endpoint on this Bus,
# with a fake GitHub): the receiver passes Flow's effect contract; an approved, tested
# revision that is pushed over on GitHub is refused (blocked) and nothing is merged; new
# evidence for the new head checks and integrates it again; behind its base, it is
# updated, CI is waited for on the update, not on the revision alone; a failure between
# GitHub's merge and its outcome, with Flow and Facts restarted, gives
# one merge and one outcome; an import that is approved and passed waits blocked.
# Slice 9: issues are imported as the table says (one whose pull request reported its merge
# completes as it was; every other, in Specification as on test and prod, starts building,
# with nothing written on it); the run owns every issue; an issue whose pull request is in
# its checks builds on; one whose merged pull request is linked to it completes through the
# link; changes requested on its pull request are written to it once and it builds on; the
# merge of its pull request ends it, once, in the reconcile that ends the pull request.
import ExUnit.Assertions
alias AtlasBus.Digest
alias AtlasCode.{Effects, FakeGitHub}
alias AtlasFlow.{EffectReceiverContract, ManualClock, Talk}
alias AtlasFlow.Activities.Effect
alias AtlasFlow.Runs.Store
[dir, bin] = System.argv()
root = Path.expand("../..", __DIR__)
data = Path.join(dir, "rela")
File.mkdir_p!(data)
python = System.get_env("ATLAS_CONFIG_PYTHON") || "python3"

{out, status} =
  System.cmd(
    python,
    [
      Path.join(root, "rela/scripts/config.py"),
      "copy",
      "--root",
      Path.join(root, "rela"),
      "--data",
      data
    ],
    stderr_to_stdout: true
  )

assert status == 0, out
{:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
{:ok, port} = :inet.port(socket)
:gen_tcp.close(socket)

server =
  Port.open({:spawn_executable, Path.join(bin, "rela-server")}, [
    :binary,
    :exit_status,
    :stderr_to_stdout,
    args: ["-project", data, "-bind", "127.0.0.1", "-port", to_string(port), "-quiet"]
  ])

{:os_pid, os_pid} = Port.info(server, :os_pid)

try do
  now = ~U[2026-11-13 00:00:00Z]
  {:ok, clock} = ManualClock.start_link(now)

  facts_opts = [
    rela: {AtlasFacts.Rela.Http, "http://127.0.0.1:#{port}/api/v1"},
    data_dir: Path.join(dir, "facts"),
    flow_input_clock: fn -> ManualClock.now(clock) end
  ]

  Application.put_env(:atlas, :model, Model.AtlasEyra)
  Application.put_env(:atlas, :actors, %{"decider" => "reviewer-1"})
  {:ok, facts} = AtlasFacts.Server.start_link(facts_opts)
  :ok = AtlasBus.attach("control/session-delivery-proof")
  readiness_deadline = System.monotonic_time(:millisecond) + 30_000

  await = fn await ->
    case Talk.read("_description", %{}) do
      %{"description" => %{"entities" => %{}} = d} ->
        d

      other ->
        assert System.monotonic_time(:millisecond) < readiness_deadline, inspect(other)
        await.(await)
    end
  end

  served = await.(await)
  assert Map.take(served, ~w(entities relations types)) == Model.AtlasEyra.rela_schema()
  %{config: config, flows: flows, refusal: nil} = AtlasFlow.Model.load(Model.AtlasEyra, :test)

  assert Enum.sort(Map.keys(config["selection"])) ==
           ~w(decide design_and_accept follow_through issue pr_review pr_test pull_request test_and_accept_scene test_and_accept_use_case to_do)

  # GitHub, faked: the base branch and the commits the pull request will have.
  {:ok, gh} = FakeGitHub.start_link()
  FakeGitHub.commit(gh, "base")
  FakeGitHub.branch(gh, "main", "base")
  r1 = FakeGitHub.commit(gh, "r1", ["base"])
  r2 = FakeGitHub.commit(gh, "r2", ["r1"])

  # Code's receiver of the integrate effect, on this Bus, as the core starts it
  # (AtlasCode.Application).
  code = %{
    "dir" => Path.join(dir, "code"),
    "github" => {FakeGitHub, FakeGitHub.config(gh)},
    "repositories" => ["eyra/atlas"]
  }

  {:ok, _code} =
    Supervisor.start_link([{AtlasCode.Effects.Endpoint, code}], strategy: :one_for_one)

  # Acknowledgement barrier, no timer wait: every request and answer sent was handled.
  drain = fn ->
    _ = :sys.get_state(AtlasCode.Effects.Endpoint)
    _ = :sys.get_state(AtlasFlow.Activities.Effect.Inbox)
  end

  merges = fn -> for {:merge, _, _} = w <- FakeGitHub.writes(gh), do: w end

  # Each reconcile runs in a fresh Flow process: Flow keeps nothing, only Facts does.
  reconcile = fn ->
    Task.async(fn ->
      :ok = AtlasBus.attach("flow")

      try do
        Store.reconcile(config, flows, ManualClock.now(clock))
      after
        Registry.unregister(AtlasBus.Endpoints, "flow")
      end
    end)
    |> Task.await(30_000)
  end

  restart = fn facts ->
    GenServer.stop(facts)
    {:ok, facts} = AtlasFacts.Server.start_link(facts_opts)
    _ = await.(await)
    facts
  end

  put = fn kind, content ->
    assert {:stored, _} = Talk.put(kind, content), inspect(content)
  end

  read = fn kind, key ->
    %{"fact" => fact} = Talk.transition_read(kind, %{"key" => key, "plain" => true})
    fact
  end

  run_of = fn runs, flow, key ->
    Enum.find(runs, &(&1["flow"] == flow and &1["subject_key"] == key))
  end

  pr_run = fn runs, key -> run_of.(runs, "pull_request", key) end
  summary = fn run -> {run["state"], run["status"], run["entry"]} end

  outcomes = fn key ->
    Map.take(read.("pull_request", key)["values"], ~w(review_outcome test_outcome update))
  end

  for {key, name} <- [{"reviewer-1", "Reviewer"}, {"tester-1", "Tester"}],
      do: put.("person", %{"op" => "create", "key" => key, "values" => %{"name" => name}})

  pull_request = fn number, values ->
    key = "PR-eyra-atlas-#{number}"

    put.("pull_request", %{
      "op" => "create",
      "key" => key,
      "values" => Map.merge(%{"url" => "https://github.com/eyra/atlas/pull/#{number}"}, values)
    })

    key
  end

  # pr_review and pr_test have short ids: rela makes the id and refuses one given, and
  # Facts always gives one. So the reviews and tests are written into the private rela
  # without an id, as whoever asks for one makes it, and go by the id rela made.
  rela_url = "http://127.0.0.1:#{port}/api/v1"

  child = fn kind, relation, pr, values ->
    plural = Model.AtlasEyra.rela_schema()["entities"][kind]["plural"]

    body =
      JSON.encode!(%{
        "properties" => Map.merge(%{"title" => "A #{kind} of #{pr}"}, values),
        "relations" => %{relation => %{"data" => [%{"type" => "pull_request", "id" => pr}]}}
      })

    request =
      {~c"#{rela_url}/#{plural}", [{~c"accept", ~c"application/json"}], ~c"application/json",
       body}

    assert {:ok, {{_, status, _}, _, raw}} =
             :httpc.request(:post, request, [timeout: 5_000], body_format: :binary)

    assert status in [200, 201], raw
    %{"id" => key} = JSON.decode!(raw)
    prefix = Model.AtlasEyra.rela_schema()["entities"][kind]["id_prefix"]
    assert String.starts_with?(key, prefix), key
    key
  end

  review = fn pr, values -> child.("pr_review", "review_of", pr, values) end
  test = fn pr, values -> child.("pr_test", "test_of", pr, values) end

  verdict = fn kind, key, by, value ->
    put.(kind, %{
      "op" => "change",
      "key" => key,
      "by" => by,
      "values" => %{"verdict" => value},
      "links" => %{"verdict_by" => [by]}
    })
  end

  # Before the cutover, as on test and prod today: the old flow presented every open
  # pull request, and no flow wrote an outcome on one. One merged with its review done,
  # one closed, one open whose outcomes someone wrote, one open with a review and a test
  # of its revision r1 still open.
  merged = pull_request.(9101, %{"state" => "merged", "revision" => "r1"})
  _ = review.(merged, %{"revision" => "r1", "verdict" => "approved"})
  closed = pull_request.(9102, %{"state" => "closed"})

  ready =
    pull_request.(9103, %{
      "state" => "open",
      "revision" => r1,
      "review_outcome" => "approved",
      "test_outcome" => "passed"
    })

  open = pull_request.(9104, %{"state" => "open", "revision" => r1})
  FakeGitHub.put_pull(gh, 9104, %{"head" => r1})
  review_r1 = review.(open, %{"revision" => r1})
  test_r1 = test.(open, %{"revision" => r1})
  history = [merged, closed, ready]

  # Slice 9. The issues as on test and prod today: in Specification, with nothing a flow
  # wrote on them, presented by the old flow. One whose open pull request (r1, above)
  # is in its checks, one whose merged pull request is linked to it, and one on which its
  # pull request's merge was reported already (the import table's one row).
  issue = fn number, values ->
    key = "IS-Atlas-#{number}"

    put.("issue", %{
      "op" => "create",
      "key" => key,
      "values" =>
        Map.merge(
          %{"title" => "Issue #{number}", "description" => "Proof", "stage" => "specification"},
          values
        )
    })

    key
  end

  link = fn pr, key ->
    put.("pull_request", %{"op" => "change", "key" => pr, "links" => %{"in_issue" => [key]}})
  end

  building = issue.(91, %{})
  link.(open, building)
  built = issue.(92, %{})
  link.(merged, built)
  reported = issue.(93, %{"pr_outcome" => "integrated"})
  issues = [building, built, reported]
  before = Map.new(history, &{&1, read.("pull_request", &1)})
  untouched = Map.new(issues, &{&1, read.("issue", &1)})
  issue_run = fn runs, key -> run_of.(runs, "issue", key) end

  assert {:ok, runs} = reconcile.()
  assert summary.(pr_run.(runs, merged)) == {"integrated", "completed", 1}
  assert summary.(pr_run.(runs, closed)) == {"closed", "completed", 1}
  # Approved and passed, imported: it waits blocked; an import never integrates.
  assert summary.(pr_run.(runs, ready)) == {"blocked", "active", 1}
  for key <- history, do: assert(pr_run.(runs, key)["last_input"]["import"] == true)
  # Imports wrote nothing on the pull requests they imported.
  for {key, fact} <- before, do: assert(read.("pull_request", key)["version"] == fact["version"])
  # No row holds for the plain open one: it starts its checks, writing only their reset.
  waiting = pr_run.(runs, open)
  assert summary.(waiting) == {"checking", "active", 1}
  refute Map.has_key?(waiting["last_input"], "import")

  assert outcomes.(open) == %{
           "review_outcome" => "none",
           "test_outcome" => "none",
           "update" => "none"
         }

  assert summary.(run_of.(runs, "pr_review", review_r1)) == {"working", "active", 1}

  # Every issue: completed history as the table says, every other building, writing nothing.
  assert summary.(issue_run.(runs, reported)) == {"done", "completed", 1}
  assert issue_run.(runs, reported)["last_input"]["import"] == true

  for key <- [building, built] do
    assert summary.(issue_run.(runs, key)) == {"author", "active", 1}
    refute Map.has_key?(issue_run.(runs, key)["last_input"], "import")
  end

  for {key, fact} <- untouched, do: assert(read.("issue", key)["version"] == fact["version"])

  # The run is the one writer of every issue: the old flow presents none.
  for key <- issues,
      do: assert({"issue", _} = Store.selected(config, "issue", read.("issue", key)))

  # The run is the one writer of every pull request: the old flow presents none.
  for key <- [open | history],
      do:
        assert(
          {"pull_request", _} = Store.selected(config, "pull_request", read.("pull_request", key))
        )

  joined = pr_run.(runs, ready)
  first = runs
  # Restart while waiting: nothing moves, nothing is written again.
  facts = restart.(facts)
  version = read.("pull_request", open)["version"]
  assert {:ok, runs} = reconcile.()
  assert pr_run.(runs, open) == waiting
  assert pr_run.(runs, ready) == joined
  assert read.("pull_request", open)["version"] == version

  # The issue whose pull request is in its checks builds on: the link reports nothing yet.
  # On this fresh store the merged pull request's run was made after its issue's, in the
  # first reconcile; this one completes the issue through the link, once (on test and prod
  # the pull requests' runs exist already, so it completes in the reconcile that imports it).
  assert issue_run.(runs, building) == issue_run.(first, building)
  assert read.("issue", building)["version"] == untouched[building]["version"]
  assert read.("issue", building)["values"]["pr_outcome"] == nil
  done = issue_run.(runs, built)
  assert summary.(done) == {"done", "completed", 2}
  assert read.("issue", built)["values"]["pr_outcome"] == "integrated"
  assert [%{"child" => ^merged}] = done["last_input"]["sources"]
  assert issue_run.(runs, reported) == issue_run.(first, reported)

  # The test of r1 fails: the pull request goes back for changes.
  verdict.("pr_test", test_r1, "tester-1", "failed")
  assert {:ok, runs} = reconcile.()
  assert summary.(pr_run.(runs, open)) == {"changes_requested", "active", 2}
  assert outcomes.(open)["test_outcome"] == "failed"

  # Its issue hears of it in the same reconcile, once, and builds on: a new entry of the
  # same state, nothing else written.
  rebuilding = issue_run.(runs, building)
  assert summary.(rebuilding) == {"author", "active", 2}
  assert rebuilding["last_input"]["synthetic"]
  assert read.("issue", building)["values"]["pr_outcome"] == "changes_requested"
  assert issue_run.(runs, built) == done

  # A new revision: whoever pushes it reports it, and replaces the review and test of r1.
  put.("pull_request", %{
    "op" => "change",
    "key" => open,
    "values" => %{"revision" => r2, "update" => "updated"}
  })

  FakeGitHub.set_pull(gh, 9104, %{"head" => r2})

  for {kind, key} <- [{"pr_review", review_r1}, {"pr_test", test_r1}],
      do: put.(kind, %{"op" => "change", "key" => key, "values" => %{"superseded" => true}})

  assert {:ok, runs} = reconcile.()
  assert summary.(pr_run.(runs, open)) == {"checking", "active", 3}
  # Its checks start again: the issue builds on, hearing nothing new.
  assert issue_run.(runs, building) == rebuilding

  assert outcomes.(open) == %{
           "review_outcome" => "none",
           "test_outcome" => "none",
           "update" => "none"
         }

  # The replaced review's verdict comes late: it counts for nothing.
  verdict.("pr_review", review_r1, "reviewer-1", "approved")
  assert {:ok, runs} = reconcile.()
  assert summary.(pr_run.(runs, open)) == {"checking", "active", 3}
  assert outcomes.(open)["review_outcome"] == "none"

  # The review and test of r2: the review alone is not enough.
  review_r2 = review.(open, %{"revision" => r2})
  test_r2 = test.(open, %{"revision" => r2})
  assert {:ok, _} = reconcile.()
  verdict.("pr_review", review_r2, "reviewer-1", "approved")
  assert {:ok, runs} = reconcile.()
  assert summary.(pr_run.(runs, open)) == {"checking", "active", 3}
  assert outcomes.(open)["review_outcome"] == "approved"

  # The test passes; Facts restarts before the reconcile that takes it.
  verdict.("pr_test", test_r2, "tester-1", "passed")
  facts = restart.(facts)
  assert {:ok, runs} = reconcile.()
  merge = pr_run.(runs, open)
  assert summary.(merge) == {"integrating", "active", 4}
  assert merge["last_input"]["synthetic"]

  assert Enum.map(merge["pending"]["composition"]["links"], fn {field, s} ->
           {field, s["current"]}
         end)
         |> Enum.sort() == [{"review_outcome", r2}, {"test_outcome", r2}]

  # Code's receiver passes Flow's effect contract, on a request frozen from this very
  # definition for a pull request whose CI is green (its own journal and GitHub).
  {:ok, probe_gh} = FakeGitHub.start_link()
  FakeGitHub.commit(probe_gh, "r2", [])
  FakeGitHub.branch(probe_gh, "main", "r2")
  FakeGitHub.put_pull(probe_gh, 9104, %{"head" => r2})
  FakeGitHub.ci(probe_gh, r2, :success)

  probe =
    Effects.new(
      dir: Path.join(dir, "code-probe"),
      github: {FakeGitHub, FakeGitHub.config(probe_gh)},
      repositories: ["eyra/atlas"]
    )

  {:effect, spec} = flows["pull_request"].mechanism("integrating")

  {:ok, %{"request" => probe_request}} =
    Effect.freeze(
      %{"key" => "probe", "entry" => 1, "pending" => merge["pending"]},
      spec,
      read.("pull_request", open),
      Effect.receivers(),
      for(l <- config["composition"]["links"], l["parent_subject"] == "pull_request", do: l)
    )

  assert :ok = EffectReceiverContract.check!(&Effects.handle(probe, &1), [probe_request])
  assert length(FakeGitHub.writes(probe_gh)) == 1

  # A genuinely delayed merge completes only after a refused retry. Recover from the
  # real journal in a fresh receiver, and replay its eventual success exactly once.
  delayed = Map.put(probe_request, "id", Digest.of_term("delayed-native") |> String.slice(7, 64))

  probe_call = fn receiver, operation ->
    Effects.handle(receiver, %{
      "operation" => operation,
      "request" => delayed,
      "digest" => Digest.of_term(delayed)
    })
  end

  FakeGitHub.set_pull(probe_gh, 9104, %{
    "state" => "open",
    "merged" => false,
    "merge_commit" => nil
  })

  FakeGitHub.fail(probe_gh, :merge, :delayed)
  assert %{"status" => "working"} = probe_call.(probe, "submit")
  FakeGitHub.fail(probe_gh, :merge, {:refused, "no_token"})
  recovered = Effects.new(dir: probe.dir, github: probe.github, repositories: probe.repositories)
  assert %{"status" => "working"} = probe_call.(recovered, "lookup")
  assert [{:ok, delayed_sha}] = FakeGitHub.complete_merges(probe_gh)

  assert %{"status" => "done", "reference" => ^delayed_sha} =
           delayed_done = probe_call.(recovered, "lookup")

  assert probe_call.(probe, "submit") == delayed_done
  assert length(FakeGitHub.writes(probe_gh)) == 2

  # Its run approved r2 (its review and test were of r2): Code is asked to integrate r2,
  # the request stored in the run before it is sent. CI on r2 is still running: Code says
  # so, which is no answer, and Flow waits.
  {:ok, _} = reconcile.()
  drain.()
  assert {:ok, runs} = reconcile.()
  asked = pr_run.(runs, open)
  assert summary.(asked) == {"integrating", "active", 4}
  requested = asked["pending"]["effect"]["request"]

  assert {requested["payload"], requested["target"]} ==
           {%{"revision" => r2}, read.("pull_request", open)["values"]["url"]}

  assert read.("pull_request", open)["values"]["integration"] == "none"
  assert FakeGitHub.writes(gh) == []

  # Once: a restart and another reconcile neither move nor write it again.
  facts = restart.(facts)
  version = read.("pull_request", open)["version"]
  assert {:ok, runs} = reconcile.()
  assert summary.(pr_run.(runs, open)) == summary.(asked)
  assert pr_run.(runs, open)["pending"]["effect"]["request"] == requested
  assert read.("pull_request", open)["version"] == version

  # Ask again at the manual clock's retry, and take the answer.
  ask = fn ->
    ManualClock.advance(clock, 1000)
    {:ok, _} = reconcile.()
    drain.()
    reconcile.()
  end

  # Someone pushes r3 over it on GitHub; Atlas has no review or test of r3. Code refuses:
  # the head is not the revision it was asked about. Nothing is merged.
  r3 = FakeGitHub.commit(gh, "r3", ["r2"])
  FakeGitHub.set_pull(gh, 9104, %{"head" => r3})
  FakeGitHub.ci(gh, r3, :success)
  assert {:ok, runs} = ask.()
  blocked = pr_run.(runs, open)
  assert summary.(blocked) == {"blocked", "active", 5}

  assert [
           %{
             "request" => ^requested,
             "result" => %{"status" => "refused", "reason" => "stale_revision"}
           }
         ] =
           blocked["pending"]["effects"]

  assert read.("pull_request", open)["values"]["integration"] == "refused"
  assert FakeGitHub.writes(gh) == []
  # Blocked, its issue hears nothing new; a reconcile moves nothing.
  assert issue_run.(runs, building) == rebuilding
  assert {:ok, runs} = reconcile.()
  assert pr_run.(runs, open) == blocked

  # New evidence: r3 is reported, its review and test start again and both hold for r3.
  put.("pull_request", %{
    "op" => "change",
    "key" => open,
    "values" => %{"revision" => r3, "update" => "updated"}
  })

  for {kind, key} <- [{"pr_review", review_r2}, {"pr_test", test_r2}],
      do: put.(kind, %{"op" => "change", "key" => key, "values" => %{"superseded" => true}})

  assert {:ok, runs} = reconcile.()
  assert summary.(pr_run.(runs, open)) == {"checking", "active", 6}
  review_r3 = review.(open, %{"revision" => r3})
  test_r3 = test.(open, %{"revision" => r3})
  assert {:ok, _} = reconcile.()
  verdict.("pr_review", review_r3, "reviewer-1", "approved")
  verdict.("pr_test", test_r3, "tester-1", "passed")

  # Meanwhile its base moved on: r3 is behind it.
  base2 = FakeGitHub.commit(gh, "base 2", ["base"])
  FakeGitHub.branch(gh, "main", "base 2")
  assert {:ok, runs} = reconcile.()
  assert summary.(pr_run.(runs, open)) == {"integrating", "active", 7}
  {:ok, _} = reconcile.()
  drain.()
  assert {:ok, runs} = reconcile.()
  second = pr_run.(runs, open)["pending"]["effect"]["request"]
  assert second["payload"] == %{"revision" => r3} and second["id"] != requested["id"]

  # Code asks GitHub to update it from its base, fenced by r3; GitHub does so later.
  assert [{:update_branch, 9104, ^r3}] = FakeGitHub.writes(gh)
  FakeGitHub.apply_updates(gh)
  update = FakeGitHub.get_pull(gh, 9104)["head"]
  assert {:ok, [^r3, ^base2]} = FakeGitHub.parents(FakeGitHub.config(gh), "eyra/atlas", update)
  # CI on r3 alone (green above) is not CI on the update: still integrating.
  assert {:ok, runs} = ask.()
  assert summary.(pr_run.(runs, open)) == {"integrating", "active", 7}
  assert merges.() == []

  # A timed-out attempt remains uncertain through a later refusal and a Facts/Flow
  # restart. Flow keeps the same request, without recording a refused integration.
  FakeGitHub.ci(gh, update, :success)
  FakeGitHub.fail(gh, :merge, :unavailable)
  assert {:ok, _} = ask.()
  assert merges.() == []
  FakeGitHub.fail(gh, :merge, {:refused, "no_token"})
  assert {:ok, runs} = ask.()
  assert summary.(pr_run.(runs, open)) == {"integrating", "active", 7}
  assert pr_run.(runs, open)["pending"]["effect"]["request"] == second
  assert read.("pull_request", open)["values"]["integration"] == "none"
  assert length(FakeGitHub.merge_attempts(gh)) == 2
  :ok = Application.stop(:atlas_flow)
  {:ok, _} = Application.ensure_all_started(:atlas_flow)
  facts = restart.(facts)

  # A later page contains failed/pending statuses; no new merge may be attempted.
  visible = for i <- 1..30, do: %{"context" => "green-#{i}", "state" => "success"}

  for state <- ["failure", "pending", "success"] do
    FakeGitHub.ci(
      gh,
      update,
      {:evidence, %{"check_runs" => [], "total_count" => 0},
       %{"state" => state, "total_count" => 31, "statuses" => visible}}
    )

    assert {:ok, runs} = ask.()
    assert summary.(pr_run.(runs, open)) == {"integrating", "active", 7}
    assert pr_run.(runs, open)["pending"]["effect"]["request"] == second
    assert length(FakeGitHub.merge_attempts(gh)) == 2
    assert read.("pull_request", open)["values"]["integration"] == "none"
  end

  # Green CI alone is insufficient if the base advanced meanwhile. No branch update
  # is safe while an earlier merge might still complete.
  FakeGitHub.ci(gh, update, :success)
  FakeGitHub.commit(gh, "base 3", ["base 2"])
  FakeGitHub.branch(gh, "main", "base 3")
  assert {:ok, _} = ask.()
  assert length(FakeGitHub.merge_attempts(gh)) == 2
  assert [{:update_branch, 9104, ^r3}] = FakeGitHub.writes(gh)
  FakeGitHub.branch(gh, "main", "base 2")

  # With fresh green CI and a current base, handling fails after the retried merge,
  # before its outcome write. The existing exception/recovery proof still applies.
  FakeGitHub.fail(gh, :merge, :crash)
  receiver = Process.whereis(AtlasCode.Effects.Endpoint)
  ManualClock.advance(clock, 1000)
  {:ok, _} = reconcile.()
  drain.()
  # The endpoint contains the failure and answers working; the core stays up.
  assert Process.whereis(AtlasCode.Effects.Endpoint) == receiver
  assert Process.alive?(receiver)
  assert [{:merge, 9104, ^update}] = merges.()
  assert read.("pull_request", open)["values"]["integration"] == "none"

  # Flow got no terminal answer. Flow and Facts restart; Code keeps its uncertain journal.
  :ok = Application.stop(:atlas_flow)
  {:ok, _} = Application.ensure_all_started(:atlas_flow)
  facts = restart.(facts)
  assert {:ok, runs} = reconcile.()
  assert summary.(pr_run.(runs, open)) == {"integrating", "active", 7}
  assert pr_run.(runs, open)["pending"]["effect"]["request"] == second

  # Asked again by lookup: merged, at the update, once.
  assert {:ok, runs} = ask.()
  integrated = pr_run.(runs, open)
  assert summary.(integrated) == {"integrated", "completed", 8}
  merged_at = FakeGitHub.get_pull(gh, 9104)["merge_commit"]

  assert [
           _,
           %{
             "request" => ^second,
             "result" => %{"status" => "done", "reference" => ^merged_at} = result
           }
         ] =
           integrated["pending"]["effects"]

  assert result["outputs"] == %{"sha" => merged_at, "head" => update}
  assert result["digest"] == Digest.of_term(second)
  assert read.("pull_request", open)["values"]["integration"] == "done"
  assert length(merges.()) == 1

  # Its issue is done in the same reconcile, through the link, once.
  assert summary.(issue_run.(runs, building)) == {"done", "completed", 3}
  assert read.("issue", building)["values"]["pr_outcome"] == "integrated"

  # Settled: another restart, retry deadline and reconcile change nothing and ask nothing.
  :ok = Application.stop(:atlas_flow)
  {:ok, _} = Application.ensure_all_started(:atlas_flow)
  ManualClock.advance(clock, 60_000)
  assert {:ok, settled} = reconcile.()
  drain.()
  assert length(FakeGitHub.writes(gh)) == 2

  for key <- [open | history],
      do: assert(pr_run.(settled, key) == pr_run.(runs, key))

  for key <- issues, do: assert(issue_run.(settled, key) == issue_run.(runs, key))
  assert issue_run.(settled, reported) == issue_run.(first, reported)
  assert read.("issue", reported)["version"] == untouched[reported]["version"]

  for {key, fact} <- before, do: assert(read.("pull_request", key)["version"] == fact["version"])

  GenServer.stop(facts)
  Agent.stop(clock)

  IO.puts(
    "flow-delivery native proof: imports, one writer, restart while waiting, changes " <>
      "requested, new revision with the replaced verdict ignored; Code's receiver passes the " <>
      "effect contract, a pushed-over head is refused with nothing merged, new evidence " <>
      "integrates the new head after updating it from its base and CI on the update; " <>
      "delayed completion survives a refused retry; uncertain retries survive refusal/restart " <>
      "and wait for complete CI and a current base; a crash " <>
      "between GitHub's merge and the outcome gives one merge (#{merged_at}); issues imported, " <>
      "building, done through the link once ok"
  )
after
  System.cmd("/bin/kill", ["-TERM", to_string(os_pid)], stderr_to_stdout: true)

  receive do
    {^server, {:exit_status, _}} -> :ok
  after
    5_000 ->
      System.cmd("/bin/kill", ["-KILL", to_string(os_pid)], stderr_to_stdout: true)

      receive do
        {^server, {:exit_status, _}} -> :ok
      after
        1_000 -> raise "private rela-server did not exit after SIGKILL"
      end
  end

  if Port.info(server), do: Port.close(server)
end
