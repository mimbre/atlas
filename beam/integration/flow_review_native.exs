# Native proof of slice 7: the review and the test of a pull request on Flow's durable runs,
# against a private Rela and real Facts, with the model compiled for the test environment
# and a manual clock. Owns and stops its private Rela and Facts.
# MIX_ENV=test mix run integration/flow_review_native.exs PRIVATE_DIR RELA_BIN_DIR
#
# It proves: open and historical facts are imported as the table says (nothing rerun,
# nothing written on the subjects); restart while waiting keeps the original three days; a
# verdict counts only as its giver's trusted choice; a replaced review or test completes as
# superseded and its late verdict moves nothing, while the composition's link counts only
# the results for the pull request's current revision; review and test complete on one
# exact revision.
import ExUnit.Assertions
alias AtlasFlow.{ManualClock, Talk}
alias AtlasFlow.Composition.Links
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
  :ok = AtlasBus.attach("control/session-review-proof")
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
  # Slice 8 selects their pull request too (flow_delivery_native.exs).
  assert Enum.sort(Map.keys(config["selection"])) == ~w(decide pr_review pr_test pull_request)

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

  put = fn kind, content ->
    assert {:stored, _} = Talk.put(kind, content), inspect(content)
  end

  read = fn kind, key ->
    %{"fact" => fact} = Talk.transition_read(kind, %{"key" => key, "plain" => true})
    fact
  end

  run_of = fn runs, key -> Enum.find(runs, &(&1["subject_key"] == key)) end
  summary = fn run -> {run["state"], run["status"], run["entry"]} end

  for {key, name} <- [{"reviewer-1", "Reviewer"}, {"tester-1", "Tester"}],
      do: put.("person", %{"op" => "create", "key" => key, "values" => %{"name" => name}})

  pr = "PR-eyra-atlas-9001"

  put.("pull_request", %{
    "op" => "create",
    "key" => pr,
    "values" => %{"url" => "https://github.com/eyra/atlas/pull/9001", "revision" => "r1"}
  })

  # pr_review and pr_test have short ids: rela makes the id and refuses one given, and
  # Facts always gives one. So the reviews and tests are written into the private rela
  # as their facts are there before Flow runs, without an id, and go by the id rela made.
  rela_url = "http://127.0.0.1:#{port}/api/v1"

  child = fn kind, relation, values ->
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

  # Before the cutover: a review and a test finished on r0 (history), and an open review
  # and test of r1, as they are on test and prod today (no flow ever ran on them).
  review_old = child.("pr_review", "review_of", %{"revision" => "r0", "verdict" => "approved"})
  test_old = child.("pr_test", "test_of", %{"revision" => "r0", "verdict" => "failed"})
  review_r1 = child.("pr_review", "review_of", %{"revision" => "r1"})
  test_r1 = child.("pr_test", "test_of", %{"revision" => "r1"})
  before = Map.new([review_old, review_r1], &{&1, read.("pr_review", &1)})

  assert {:ok, runs} = reconcile.()
  assert summary.(run_of.(runs, review_old)) == {"approved", "completed", 1}
  assert summary.(run_of.(runs, test_old)) == {"failed", "completed", 1}
  waiting = run_of.(runs, review_r1)
  assert summary.(waiting) == {"working", "active", 1}
  assert summary.(run_of.(runs, test_r1)) == {"working", "active", 1}
  for r <- runs, r["flow"] in ~w(pr_review pr_test), do: assert(r["last_input"]["import"])
  [stalled] = waiting["deadlines"]["timers"]
  assert stalled["due"] == "2026-11-16T00:00:00.000Z"
  # The import wrote nothing on the facts it imported.
  for {key, fact} <- before, do: assert(read.("pr_review", key)["version"] == fact["version"])

  # A verdict without its giver named is no trusted choice: Facts refuses it.
  assert {:refused, _} =
           Talk.put("pr_review", %{
             "op" => "change",
             "key" => review_r1,
             "by" => "reviewer-1",
             "values" => %{"verdict" => "approved"}
           })

  # Restart while waiting, just before the three days end: nothing moves.
  ManualClock.advance(clock, 3 * 86_400_000 - 1)
  GenServer.stop(facts)
  {:ok, facts} = AtlasFacts.Server.start_link(facts_opts)
  _ = await.(await)
  assert {:ok, runs} = reconcile.()
  assert run_of.(runs, review_r1) == waiting
  # At the original due time: escalated, once.
  ManualClock.advance(clock, 1)
  assert {:ok, runs} = reconcile.()
  escalated = run_of.(runs, review_r1)
  assert summary.(escalated) == {"escalated", "active", 2}
  assert escalated["last_input"]["due"] == stalled["due"]
  assert summary.(run_of.(runs, test_r1)) == {"escalated", "active", 2}
  assert {:ok, again} = reconcile.()
  assert run_of.(again, review_r1) == escalated

  # A new revision replaces the review and the test of r1.
  put.("pull_request", %{"op" => "change", "key" => pr, "values" => %{"revision" => "r2"}})

  for {kind, key} <- [{"pr_review", review_r1}, {"pr_test", test_r1}],
      do: put.(kind, %{"op" => "change", "key" => key, "values" => %{"superseded" => true}})

  review_r2 = child.("pr_review", "review_of", %{"revision" => "r2"})
  test_r2 = child.("pr_test", "test_of", %{"revision" => "r2"})
  assert {:ok, runs} = reconcile.()
  assert summary.(run_of.(runs, review_r1)) == {"superseded", "completed", 3}
  assert summary.(run_of.(runs, test_r1)) == {"superseded", "completed", 3}
  assert summary.(run_of.(runs, review_r2)) == {"working", "active", 1}

  verdict = fn kind, key, by, value ->
    put.(kind, %{
      "op" => "change",
      "key" => key,
      "by" => by,
      "values" => %{"verdict" => value},
      "links" => %{"verdict_by" => [by]}
    })
  end

  # The replaced review's verdict comes late: stored on the fact, it moves no run.
  verdict.("pr_review", review_r1, "reviewer-1", "approved")
  assert {:ok, runs} = reconcile.()
  assert summary.(run_of.(runs, review_r1)) == {"superseded", "completed", 3}

  links = Model.AtlasEyra.composition()["links"]
  link = fn name -> Enum.find(links, &(&1["child"] == name)) end

  # What the pull request's link would take: nothing from r1; r2 is not done yet.
  select = fn runs, name, kind, relation ->
    children = Talk.read(kind, %{"linked" => %{relation => pr}})["facts"]
    by_key = Map.new(children, &{&1["key"], run_of.(runs, &1["key"])})
    Links.select(link.(name), read.("pull_request", pr), children, by_key, nil)
  end

  assert select.(runs, "pr_review", "pr_review", "review_of") == :waiting

  # Review and test complete on r2. Facts restarts between the verdict and its reconcile.
  verdict.("pr_review", review_r2, "reviewer-1", "approved")
  verdict.("pr_test", test_r2, "tester-1", "passed")
  GenServer.stop(facts)
  {:ok, facts} = AtlasFacts.Server.start_link(facts_opts)
  _ = await.(await)
  assert {:ok, runs} = reconcile.()
  assert summary.(run_of.(runs, review_r2)) == {"approved", "completed", 2}
  assert summary.(run_of.(runs, test_r2)) == {"passed", "completed", 2}
  assert run_of.(runs, review_r2)["last_input"]["input"]

  %{"inputs" => [input]} =
    Task.async(fn ->
      :ok = AtlasBus.attach("flow")

      try do
        Talk.read("flow_input", %{"run" => run_of.(runs, review_r2)["key"]})
      after
        Registry.unregister(AtlasBus.Endpoints, "flow")
      end
    end)
    |> Task.await(30_000)

  assert input["actor"] == "reviewer-1" and "reviewer" in input["roles"]

  assert {:write, "approved", %{"child" => ^review_r2, "current" => "r2"}} =
           select.(runs, "pr_review", "pr_review", "review_of")

  assert {:write, "passed", %{"child" => ^test_r2, "current" => "r2"}} =
           select.(runs, "pr_test", "pr_test", "test_of")

  # Settled: another reconcile changes nothing.
  assert {:ok, settled} = reconcile.()

  for key <- [review_old, test_old, review_r1, test_r1, review_r2, test_r2],
      do: assert(run_of.(settled, key) == run_of.(runs, key))

  GenServer.stop(facts)
  Agent.stop(clock)

  IO.puts(
    "flow-review native proof: imports, restart at the original due, trusted verdicts, " <>
      "replaced child ignored, review and test on r2 ok"
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
