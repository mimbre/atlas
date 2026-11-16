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
# exact revision. And the review pass: an agent reviewer with a machine is reviewed once
# by its Runtime's pass receiver (AtlasRuntime.FlowPasses, its journal on disk, with a
# stand-in for the native turn and its recorded findings: no provider runs here), on the
# frozen packet the review names; the pass waits while that Runtime is offline, across a
# Facts restart; its findings' verdict becomes the trusted verdict (`verdict`,
# `verdict_by`), stored by real Facts; a person reviewer still answers by hand; a late
# result for a replaced revision changes nothing.
import ExUnit.Assertions
alias AtlasFlow.{ManualClock, Talk}
alias AtlasFlow.Composition.Links
alias AtlasFlow.Runs.Store

defmodule ReviewProof.Runtime do
  @moduledoc """
  The native side of the reviewer's Runtime, as AtlasRuntime.FlowPasses calls it: one
  execution per pass id (counted), running until the proof ends it with the verdict its
  findings record (`finish/3`).
  """
  def validate(_state, _request), do: :ok

  def accept(state, r) do
    Agent.get_and_update(state, fn s ->
      case s.executions[r["id"]] do
        nil ->
          result = %{"execution" => "turn-#{map_size(s.executions) + 1}", "status" => "running"}
          {{:ok, result}, %{s | executions: Map.put(s.executions, r["id"], result)}}

        result ->
          {{:ok, result}, s}
      end
    end)
  end

  def lookup(state, r, execution) do
    case Agent.get(state, & &1.executions[r["id"]]) do
      %{"execution" => ^execution} = result -> {:ok, result}
      _ -> {:error, :execution_mismatch}
    end
  end

  def finish(state, id, verdict) do
    Agent.update(state, fn s ->
      update_in(s.executions[id], fn result ->
        Map.merge(result, %{
          "status" => "completed",
          "outcome" => verdict,
          "evidence" => %{"findings" => %{"verdict" => verdict}}
        })
      end)
    end)
  end

  def started(state), do: Agent.get(state, &map_size(&1.executions))
end

[dir, bin] = System.argv()
root = Path.expand("../../..", __DIR__)
data = Path.join(dir, "rela")
File.mkdir_p!(data)
python = System.get_env("ATLAS_CONFIG_PYTHON") || "python3"

{out, status} =
  System.cmd(
    python,
    [
      Path.join(root, "platform/atlas_facts/rela/scripts/config.py"),
      "copy",
      "--root",
      Path.join(root, "products/software_factory/model/targets/rela"),
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
  Port.open({:spawn_executable, Path.join(bin, "rela-server-headless-sqlite")}, [
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
  assert Enum.sort(Map.keys(config["selection"])) ==
           ~w(decide design_and_accept follow_through issue pr_review pr_test pull_request test_and_accept_scene test_and_accept_use_case to_do)

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

  # -- The review pass of an agent reviewer -------------------------------------------------

  # The agent reviews through its Runtime on proof-desk. Its pull request and the review of
  # its revision, which names the packet the author froze of it, and its reviewer.
  put.("agent", %{
    "op" => "create",
    "key" => "revbot",
    "values" => %{"name" => "Revbot", "machine" => "proof-desk"}
  })

  pull = fn key, revision ->
    put.("pull_request", %{
      "op" => "create",
      "key" => key,
      "values" => %{
        "url" => "https://github.com/eyra/atlas/pull/#{List.last(String.split(key, "-"))}",
        "revision" => revision
      }
    })
  end

  reviewed = fn pr_key, revision, reviewer ->
    body =
      JSON.encode!(%{
        "properties" => %{
          "title" => "A review of #{pr_key}",
          "revision" => revision,
          "packet_tree" => "/private/packets/#{revision}/tree",
          "packet_id" => "packet-#{revision}",
          "packet_fingerprint" => "fpr_#{revision}"
        },
        "relations" => %{
          "review_of" => %{"data" => [%{"type" => "pull_request", "id" => pr_key}]}
        }
      })

    request =
      {~c"#{rela_url}/pr_reviews", [{~c"accept", ~c"application/json"}], ~c"application/json",
       body}

    assert {:ok, {{_, status, _}, _, raw}} =
             :httpc.request(:post, request, [timeout: 5_000], body_format: :binary)

    assert status in [200, 201], raw
    %{"id" => key} = JSON.decode!(raw)
    put.("pr_review", %{"op" => "change", "key" => key, "links" => %{"review_by" => [reviewer]}})
    key
  end

  pr_a = "PR-eyra-atlas-9002"
  pull.(pr_a, "a1")
  review_a = reviewed.(pr_a, "a1", "revbot")
  {:ok, native} = Agent.start_link(fn -> %{executions: %{}} end)

  passes_opts = [
    machine: "proof-desk",
    dir: Path.join(dir, "runtime"),
    backend: {ReviewProof.Runtime, native}
  ]

  tick = fn -> ManualClock.advance(clock, 1000) end
  pass_of = fn runs, key -> run_of.(runs, key)["pending"]["pass"] end

  # Acknowledgement barrier, no timer wait: the receiver and Flow's inbox took what was sent.
  delivered = fn passes ->
    if passes, do: :sys.get_state(passes)
    :sys.get_state(AtlasFlow.Activities.Pass.Inbox)
  end

  # Its Runtime is offline: the pass is frozen, routed to its machine, and waits.
  assert {:ok, runs} = reconcile.()
  frozen = pass_of.(runs, review_a)["request"]
  assert summary.(run_of.(runs, review_a)) == {"working", "active", 1}
  assert {frozen["owner"], frozen["machine"]} == {"revbot", "proof-desk"}
  assert frozen["request"]["cwd"] == "/private/packets/a1/tree"
  assert frozen["request"]["permissions"] == "review-packet"
  assert frozen["request"]["backend"] == "claude"

  assert frozen["request"]["packet"] == %{
           "packet_id" => "packet-a1",
           "fingerprint" => "fpr_a1",
           "revision" => "a1"
         }

  # Seed a persisted pre-fix identity before delivery. Reconciliation must use that id,
  # not regenerate it with the new formula. The real receiver must replay it unchanged.
  legacy_id =
    AtlasBus.Digest.of_term([
      frozen["run"],
      frozen["entry"],
      frozen["name"],
      frozen["owner"],
      frozen["machine"],
      frozen["fingerprint"]
    ])
    |> String.replace_prefix("sha256:", "")

  refute legacy_id == frozen["id"]
  frozen = Map.put(frozen, "id", legacy_id)

  legacy_run =
    run_of.(runs, review_a)
    |> put_in(["pending", "pass", "request"], frozen)
    |> put_in(["pending", "pass", "digest"], AtlasBus.Digest.of_term(frozen))

  Task.async(fn ->
    :ok = AtlasBus.attach(config["writer"]["sender"])

    try do
      assert {:stored, _} =
               Talk.put(config["kind"], %{
                 "op" => "change",
                 "key" => legacy_run["key"],
                 "by" => config["writer"]["by"],
                 "values" => Store.encode(config, legacy_run)
               })
    after
      Registry.unregister(AtlasBus.Endpoints, config["writer"]["sender"])
    end
  end)
  |> Task.await()

  # Facts restarts while it waits; the pass is retried as the same request, still unsent.
  GenServer.stop(facts)
  {:ok, facts} = AtlasFacts.Server.start_link(facts_opts)
  _ = await.(await)
  tick.()
  assert {:ok, runs} = reconcile.()
  assert pass_of.(runs, review_a)["request"] == frozen
  assert summary.(run_of.(runs, review_a)) == {"working", "active", 1}
  assert ReviewProof.Runtime.started(native) == 0

  # The Runtime comes up: one execution starts.
  {:ok, passes} = AtlasRuntime.FlowPasses.start_link(passes_opts)
  tick.()
  assert {:ok, _} = reconcile.()
  delivered.(passes)
  assert {:ok, runs} = reconcile.()
  assert pass_of.(runs, review_a)["execution"] == "turn-1"
  assert ReviewProof.Runtime.started(native) == 1

  # The Runtime and Flow's inbox restart, and the review ends: its findings pass it.
  GenServer.stop(passes)
  Supervisor.terminate_child(AtlasFlow.Root, AtlasFlow.Activities.Pass.Inbox)
  Supervisor.restart_child(AtlasFlow.Root, AtlasFlow.Activities.Pass.Inbox)
  {:ok, passes} = AtlasRuntime.FlowPasses.start_link(passes_opts)
  ReviewProof.Runtime.finish(native, frozen["id"], "pass")
  tick.()
  assert {:ok, _} = reconcile.()
  delivered.(passes)
  assert {:ok, runs} = reconcile.()
  done = run_of.(runs, review_a)
  assert summary.(done) == {"approved", "completed", 2}
  assert done["last_input"]["pass"] == frozen["id"]
  assert [%{"request" => ^frozen, "result" => %{"outcome" => "pass"}}] = done["pending"]["passes"]

  # Its verdict is the reviewer's, as real Facts stored it: Flow named the reviewer.
  answered = read.("pr_review", review_a)
  assert answered["values"]["verdict"] == "approved"
  assert answered["links"]["verdict_by"] == ["revbot"]

  pr_select = fn runs, pr_key ->
    children = Talk.read("pr_review", %{"linked" => %{"review_of" => pr_key}})["facts"]
    by_key = Map.new(children, &{&1["key"], run_of.(runs, &1["key"])})
    Links.select(link.("pr_review"), read.("pull_request", pr_key), children, by_key, nil)
  end

  assert {:write, "approved", %{"child" => ^review_a, "current" => "a1"}} =
           pr_select.(runs, pr_a)

  # Settled: once, however often it is reconciled.
  tick.()
  assert {:ok, again} = reconcile.()
  delivered.(passes)
  assert run_of.(again, review_a) == done
  assert ReviewProof.Runtime.started(native) == 1

  # A replaced revision: its review's pass runs, the pull request moves on and the review is
  # superseded; the pass's late result then changes nothing.
  pr_b = "PR-eyra-atlas-9003"
  pull.(pr_b, "b1")
  review_b = reviewed.(pr_b, "b1", "revbot")
  assert {:ok, _} = reconcile.()
  delivered.(passes)
  assert {:ok, runs} = reconcile.()
  late = pass_of.(runs, review_b)
  assert late["execution"] == "turn-2"
  put.("pull_request", %{"op" => "change", "key" => pr_b, "values" => %{"revision" => "b2"}})
  put.("pr_review", %{"op" => "change", "key" => review_b, "values" => %{"superseded" => true}})
  assert {:ok, runs} = reconcile.()
  assert summary.(run_of.(runs, review_b)) == {"superseded", "completed", 2}
  ReviewProof.Runtime.finish(native, late["request"]["id"], "pass")
  tick.()
  assert {:ok, _} = reconcile.()
  delivered.(passes)
  assert {:ok, runs} = reconcile.()
  assert summary.(run_of.(runs, review_b)) == {"superseded", "completed", 2}
  assert read.("pr_review", review_b)["values"]["verdict"] in [nil, ""]

  # A person reviews the new revision: no pass is frozen; they answer by hand, as before.
  review_b2 = reviewed.(pr_b, "b2", "reviewer-1")
  assert {:ok, runs} = reconcile.()
  assert summary.(run_of.(runs, review_b2)) == {"working", "active", 1}
  assert pass_of.(runs, review_b2) == nil
  verdict.("pr_review", review_b2, "reviewer-1", "changes_requested")
  assert {:ok, runs} = reconcile.()
  assert summary.(run_of.(runs, review_b2)) == {"changes_requested", "completed", 2}
  assert run_of.(runs, review_b2)["last_input"]["input"]

  assert {:write, "changes_requested", %{"child" => ^review_b2, "current" => "b2"}} =
           pr_select.(runs, pr_b)

  assert ReviewProof.Runtime.started(native) == 2

  # Assignment-only changes invalidate the binding even when its deciding fingerprint
  # stays the same. Exercise Store -> Bus -> real receiver journal, also after no answer.
  pr_c = "PR-eyra-atlas-9004"
  pull.(pr_c, "c1")
  review_c = reviewed.(pr_c, "c1", "revbot")
  assert {:ok, _} = reconcile.()
  delivered.(passes)
  assert {:ok, runs} = reconcile.()
  first = pass_of.(runs, review_c)
  first_id = first["request"]["id"]
  journal = fn id -> Path.join([dir, "runtime", "passes", id <> ".json"]) end
  first_bytes = File.read!(journal.(first_id))

  put.("pr_review", %{
    "op" => "change",
    "key" => review_c,
    "values" => %{"title" => "Assignment changed"}
  })

  assert {:ok, runs} = reconcile.()

  assert [%{"left" => true, "request" => %{"id" => ^first_id}}] =
           run_of.(runs, review_c)["pending"]["passes"]

  assert {:ok, _} = reconcile.()
  tick.()
  assert {:ok, _} = reconcile.()
  delivered.(passes)
  assert {:ok, runs} = reconcile.()
  second = pass_of.(runs, review_c)
  second_id = second["request"]["id"]
  refute second_id == first_id
  assert second["request"]["fingerprint"] == first["request"]["fingerprint"]
  assert second["execution"] == "turn-4"
  assert File.read!(journal.(first_id)) == first_bytes

  ReviewProof.Runtime.finish(native, second_id, "uncertain")
  tick.()
  assert {:ok, _} = reconcile.()
  delivered.(passes)
  assert {:ok, runs} = reconcile.()
  assert pass_of.(runs, review_c)["result"]["outcome"] == "uncertain"
  second_bytes = File.read!(journal.(second_id))

  put.("pr_review", %{
    "op" => "change",
    "key" => review_c,
    "values" => %{"title" => "Changed after no answer"}
  })

  assert {:ok, _} = reconcile.()
  assert {:ok, _} = reconcile.()
  GenServer.stop(passes)
  {:ok, passes} = AtlasRuntime.FlowPasses.start_link(passes_opts)
  tick.()
  assert {:ok, _} = reconcile.()
  delivered.(passes)
  assert {:ok, runs} = reconcile.()
  third = pass_of.(runs, review_c)
  third_id = third["request"]["id"]
  refute third_id in [first_id, second_id]
  assert third["request"]["fingerprint"] == first["request"]["fingerprint"]
  assert third["execution"] == "turn-5"
  assert File.read!(journal.(first_id)) == first_bytes
  assert File.read!(journal.(second_id)) == second_bytes

  ReviewProof.Runtime.finish(native, third_id, "pass")
  tick.()
  assert {:ok, _} = reconcile.()
  delivered.(passes)
  assert {:ok, runs} = reconcile.()
  done_c = run_of.(runs, review_c)
  assert summary.(done_c) == {"approved", "completed", 2}
  assert done_c["last_input"]["pass"] == third_id

  assert [
           %{"left" => true, "request" => %{"id" => ^first_id}},
           %{
             "left" => true,
             "request" => %{"id" => ^second_id},
             "result" => %{"outcome" => "uncertain"}
           },
           %{"request" => %{"id" => ^third_id}, "result" => %{"outcome" => "pass"}}
         ] = done_c["pending"]["passes"]

  tick.()
  assert {:ok, runs} = reconcile.()
  delivered.(passes)
  assert run_of.(runs, review_c) == done_c
  assert ReviewProof.Runtime.started(native) == 5

  IO.puts(
    "assignment-only replacements: running and no-answer, 3 distinct executions; old journals unchanged"
  )

  GenServer.stop(passes)
  Agent.stop(native)

  GenServer.stop(facts)
  Agent.stop(clock)

  IO.puts(
    "flow-review native proof: imports, restart at the original due, trusted verdicts, " <>
      "replaced child ignored, review and test on r2, and one review pass on an agent " <>
      "reviewer's Runtime (offline wait, restarts, verdict, late result ignored) ok"
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
        1_000 -> raise "private rela-server-headless-sqlite did not exit after SIGKILL"
      end
  end

  if Port.info(server), do: Port.close(server)
end
