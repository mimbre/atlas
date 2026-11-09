# Native proof of slices 8 and 9: the pull request and the issue on Flow's durable runs, in
# place of the legacy flows review_and_merge and build_and_merge, against a private Rela and real Facts, with the model compiled
# for the test environment and a manual clock. Owns and stops its private Rela and Facts.
# MIX_ENV=test mix run integration/flow_delivery_native.exs PRIVATE_DIR RELA_BIN_DIR
#
# It proves: merged, closed and open pull requests are imported as the table says (history
# completes as it was and nothing is written on it; an open one with outcomes joins its
# wait; any other open one starts its checks); the run, not the legacy flow, owns every
# pull request; restart while waiting moves nothing; a failed test sends it back; a new
# revision starts the checks again and the replaced revision's late verdict counts for
# nothing; review and test on the current revision together lead to the merge, once,
# across a Facts restart between the verdict and its reconcile; the merge by hand ends it.
# Slice 9: issues are imported as the table says (one whose pull request reported its merge
# completes as it was; every other, in Specification as on test and prod, starts building,
# with nothing written on it); the run owns every issue; an issue whose pull request is in
# its checks builds on; one whose merged pull request is linked to it completes through the
# link; changes requested on its pull request are written to it once and it builds on; the
# merge of its pull request ends it, once, in the reconcile that ends the pull request.
import ExUnit.Assertions
alias AtlasFlow.{ManualClock, Talk}
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
           ~w(decide design_and_accept issue pr_review pr_test pull_request test_and_accept_use_case)

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

  # Before the cutover, as on test and prod today: the legacy flow presented every open
  # pull request, and no flow wrote an outcome on one. One merged with its review done,
  # one closed, one open whose outcomes someone wrote, one open with a review and a test
  # of its revision r1 still open.
  merged = pull_request.(9101, %{"state" => "merged", "revision" => "r1"})
  _ = review.(merged, %{"revision" => "r1", "verdict" => "approved"})
  closed = pull_request.(9102, %{"state" => "closed"})

  ready =
    pull_request.(9103, %{
      "state" => "open",
      "revision" => "r1",
      "review_outcome" => "approved",
      "test_outcome" => "passed"
    })

  open = pull_request.(9104, %{"state" => "open", "revision" => "r1"})
  review_r1 = review.(open, %{"revision" => "r1"})
  test_r1 = test.(open, %{"revision" => "r1"})
  history = [merged, closed, ready]

  # Slice 9. The issues as on test and prod today: in Specification, with nothing a flow
  # wrote on them, presented by the legacy flow. One whose open pull request (r1, above)
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
  assert summary.(pr_run.(runs, ready)) == {"integrating", "active", 1}
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

  # The run is the one writer of every issue: the legacy flow presents none.
  for key <- issues,
      do: assert({"issue", _} = Store.selected(config, "issue", read.("issue", key)))

  # The run is the one writer of every pull request: the legacy flow presents none.
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
    "values" => %{"revision" => "r2", "update" => "updated"}
  })

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
  review_r2 = review.(open, %{"revision" => "r2"})
  test_r2 = test.(open, %{"revision" => "r2"})
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
         |> Enum.sort() == [{"review_outcome", "r2"}, {"test_outcome", "r2"}]

  # Once: a restart and another reconcile neither move nor write it again.
  facts = restart.(facts)
  version = read.("pull_request", open)["version"]
  assert {:ok, runs} = reconcile.()
  assert pr_run.(runs, open) == merge
  assert read.("pull_request", open)["version"] == version

  # Merged by hand: it ends, once; history stays as it was.
  put.("pull_request", %{"op" => "change", "key" => open, "values" => %{"state" => "merged"}})
  assert {:ok, runs} = reconcile.()
  assert summary.(pr_run.(runs, open)) == {"integrated", "completed", 5}
  # Its issue is done in the same reconcile, through the link, once.
  assert summary.(issue_run.(runs, building)) == {"done", "completed", 3}
  assert read.("issue", building)["values"]["pr_outcome"] == "integrated"
  assert {:ok, settled} = reconcile.()

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
      "requested, new revision with the replaced verdict ignored, merge once, merged; issues " <>
      "imported, building, done through the link once ok"
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
