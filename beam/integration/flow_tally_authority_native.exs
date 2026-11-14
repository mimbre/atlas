# Private real-model/Facts/Rela regression for historical agent acceptances.
# MIX_ENV=test ATLAS_RELA_BIN=<pinned tools> mix run integration/flow_tally_authority_native.exs
# Append `before` to prove the original refusal before changing the DSL evaluator.
import ExUnit.Assertions
alias AtlasFacts.Rela
alias AtlasFlow.Talk
alias AtlasFlow.Runs.{Run, Store}

root = Path.expand("../..", __DIR__)
dir = Path.join(System.tmp_dir!(), "tally-authority-#{System.unique_integer([:positive])}")
project = Path.join(dir, "rela")
File.mkdir_p!(project)

for name <- ["schema.yaml", "data-entry.yaml", "modules", "compositions"],
    do: File.cp_r!(Path.join([root, "rela", name]), Path.join(project, name))

{:ok, socket} = :gen_tcp.listen(0, active: false, ip: {127, 0, 0, 1})
{:ok, port} = :inet.port(socket)
:gen_tcp.close(socket)

server =
  Port.open({:spawn_executable, Path.join(System.fetch_env!("ATLAS_RELA_BIN"), "rela-server")}, [
    :binary,
    :exit_status,
    args: ["-project", project, "-bind", "127.0.0.1", "-port", to_string(port), "-quiet"]
  ])

{:os_pid, pid} = Port.info(server, :os_pid)
rela = {Rela.Http, "http://127.0.0.1:#{port}/api/v1"}

try do
  deadline = System.monotonic_time(:millisecond) + 10_000

  await = fn await ->
    case Rela.description(rela) do
      {:ok, _} ->
        :ok

      other ->
        assert System.monotonic_time(:millisecond) < deadline, inspect(other)
        Process.sleep(25)
        await.(await)
    end
  end

  await.(await)
  schema = Model.AtlasEyra.rela_schema()
  plural = fn kind -> schema["entities"][kind]["plural"] end

  # Import only into this disposable native store: this is historical acceptance,
  # not a new acceptance through today's contract. No verdict is manufactured.
  assert {:ok, []} = Rela.create(rela, plural.("person"), "melle", %{"name" => "Melle"}, %{})

  assert {:ok, []} =
           Rela.create(rela, plural.("agent"), "coordinator", %{"name" => "Coordinator"}, %{})

  values = %{
    "title" => "Historical agent acceptance",
    "decision" => "Preserve the recorded acceptance.",
    "consequences" => "Carry it out.",
    "category" => "technology",
    "scope" => "instance",
    "reversibility" => "two_way",
    "force" => "direction",
    "status" => "accepted"
  }

  assert {:ok, []} =
           Rela.create(rela, plural.("assignment"), "AS-D-0025", %{"of" => "D-0025"}, %{})

  assert {:ok, []} =
           Rela.create(rela, plural.("decision"), "D-0025", values, %{
             "decided_by" => {"agent", ["coordinator"]},
             "delegated_by" => {"person", ["melle"]},
             "assignment" => {"assignment", ["AS-D-0025"]}
           })

  assert {:ok, []} = Rela.list(rela, plural.("gate_verdict"))
  assert {:ok, original} = Rela.get(rela, plural.("decision"), "D-0025")
  current = %{"values" => original.properties, "links" => original.links}

  # The actual compiled model with native lookups, including the actor's real kind.
  lookup = %{
    "current" => fn -> current end,
    "fact" => fn kind, key ->
      case Rela.get(rela, plural.(kind), key) do
        {:ok, fact} -> fact
        _ -> nil
      end
    end,
    "list" => fn kind -> Rela.list(rela, plural.(kind)) end,
    "incoming" => fn kind, key, relation ->
      {:ok, keys} = Rela.incoming(rela, plural.(kind), key, relation)
      keys
    end,
    "fingerprint" => &AtlasBus.SubjectFingerprint.of/2
  }

  change = %{"op" => "change", "key" => "D-0025", "values" => %{"work" => 0}}
  actor = %{"by" => "flow", "sender" => "flow"}
  checked = Model.AtlasEyra.check("decision", change, actor, lookup)
  before? = System.argv() == ["before"]

  authority =
    Model.AtlasEyra.__rela__(:description).extension["entities"]["decision"]["authority"]

  if before?,
    do: assert(checked == {:refuse, [authority["error"]]}),
    else: assert(checked == :ok)

  runner = AtlasFlow.Model.load(Model.AtlasEyra, :test, %{"decider" => "melle"})
  now = ~U[2026-11-14 14:16:57Z]

  # Preserve a prior completed decide run while the new follow_through runs.
  history =
    Run.new(
      "decide",
      runner.flows["decide"],
      Map.put(current, "key", "D-0025"),
      [%{"when" => %{"status" => ["accepted"]}, "state" => "accepted"}],
      now
    )

  assert history["status"] == "completed"

  assert {:ok, []} =
           Rela.create(
             rela,
             plural.(runner.config["kind"]),
             history["key"],
             Store.encode(runner.config, history),
             %{}
           )

  assert {:ok, prior_run} = Rela.get(rela, plural.(runner.config["kind"]), history["key"])
  runner = update_in(runner.config["selection"], &Map.take(&1, ["follow_through"]))

  {:ok, facts} =
    AtlasFacts.Server.start_link(
      rela: rela,
      data_dir: Path.join(dir, "facts"),
      model: Model.AtlasEyra
    )

  try do
    :ok = AtlasBus.attach("control/session-tally-proof")

    as_endpoint = fn endpoint, fun ->
      Task.async(fn ->
        :ok = AtlasBus.attach(endpoint)
        fun.()
      end)
      |> Task.await(30_000)
    end

    as_flow = fn fun -> as_endpoint.("flow", fun) end

    put = fn values, extra ->
      Talk.put("decision", Map.merge(Map.put(change, "values", values), extra))
    end

    result = as_flow.(fn -> put.(%{"work" => 0}, %{"by" => "flow"}) end)

    if before? do
      assert result == {:refused, [authority["error"]]}
      assert {:ok, ^original} = Rela.get(rela, plural.("decision"), "D-0025")

      IO.puts(
        "BEFORE: real agent-decided accepted fact, no verdict; compiled model and native Facts refuse exact Flow work=0 with acceptance authority error; history unchanged"
      )
    else
      assert {:stored, _} = result

      for n <- [2, 0] do
        assert {:stored, _} = as_flow.(fn -> put.(%{"work" => n}, %{"by" => "flow"}) end)
      end

      # Ordinary sessions and forged Flow identities cannot write its tally.
      for by <- ["melle", "coordinator", "flow", nil, false] do
        assert {:refused, _} = put.(%{"work" => 7}, %{"by" => by})
      end

      for by <- ["melle", "coordinator", nil, false] do
        assert {:refused, _} = as_flow.(fn -> put.(%{"work" => 7}, %{"by" => by}) end)
      end

      for endpoint <- ["runtime/tally-forgery", "flow/forged"] do
        assert {:refused, _} =
                 as_endpoint.(endpoint, fn -> put.(%{"work" => 7}, %{"by" => "flow"}) end)
      end

      for by <- ["melle", "coordinator"] do
        assert {:refused, _} = put.(%{"no_work" => true}, %{"by" => by})
      end

      for mixed <- [
            %{"work" => 7, "title" => "Edited"},
            %{"work" => 7, "title" => values["title"]},
            %{"work" => 7, "status" => "accepted"},
            %{"work" => 7, "no_work" => true},
            %{"work" => 7, "unverified" => false},
            %{"work" => 7, "status" => "superseded"}
          ] do
        assert {:refused, _} = as_flow.(fn -> put.(mixed, %{"by" => "flow"}) end)
      end

      assert {:refused, _} =
               as_flow.(fn ->
                 put.(%{"work" => 7}, %{"by" => "flow", "links" => %{"decided_by" => ["melle"]}})
               end)

      assert {:refused, _} = put.(%{"title" => "Edited"}, %{"by" => "melle"})

      assert {:refused, _} =
               as_flow.(fn ->
                 put.(%{"work" => 7}, %{
                   "by" => "flow",
                   "links" => %{"decided_by" => ["coordinator"]}
                 })
               end)

      # The same agent still cannot newly accept without a fresh verdict.
      assert {:stored, _} =
               Talk.put("decision", %{
                 "op" => "create",
                 "key" => "D-0026",
                 "by" => "melle",
                 "values" => Map.put(values, "status", "proposed")
               })

      for by <- ["coordinator", "flow", false], tally <- [%{}, %{"work" => 0}] do
        assert {:refused, _} =
                 Talk.put("decision", %{
                   "op" => "change",
                   "key" => "D-0026",
                   "by" => by,
                   "values" => Map.put(tally, "status", "accepted")
                 })
      end

      assert {:refused, _} =
               as_flow.(fn ->
                 Talk.put("decision", %{
                   "op" => "change",
                   "key" => "D-0026",
                   "by" => "flow",
                   "values" => %{"status" => "accepted", "work" => 0}
                 })
               end)

      assert {:stored, _} =
               Talk.put("decision", %{
                 "op" => "change",
                 "key" => "D-0026",
                 "by" => "melle",
                 "values" => %{"status" => "accepted"}
               })

      assert {:ok, final} = Rela.get(rela, plural.("decision"), "D-0025")
      assert Map.delete(final.properties, "work") == original.properties
      assert final.links == original.links
      assert final.properties["work"] == 0
      assert {:ok, []} = Rela.list(rela, plural.("gate_verdict"))

      # Recover an already persisted pending singleton, as on the deployed wait.
      # The private cursor owes exactly the Flow work=0 write; do not drop it.
      pending_run =
        Run.new(
          "follow_through",
          runner.flows["follow_through"],
          Map.put(current, "key", "D-0025"),
          runner.config["selection"]["follow_through"]["imports"],
          now
        )

      pending_write = %{
        "id" => Run.digest({pending_run["key"], "tally-proof", 0}),
        "kind" => "decision",
        "content" => Map.put(change, "by", "flow")
      }

      pending_run = put_in(pending_run, ["pending", "writes"], [pending_write])

      assert {:stored, _} =
               as_flow.(fn ->
                 Talk.put(runner.config["kind"], %{
                   "op" => "create",
                   "key" => pending_run["key"],
                   "by" => "flow",
                   "values" => Store.encode(runner.config, pending_run)
                 })
               end)

      assert {:ok, persisted} =
               as_flow.(fn ->
                 Store.latest(runner.config, "follow_through", "decision", "D-0025")
               end)

      assert persisted["pending"]["writes"] == [pending_write]

      {:ok, [waiting]} =
        as_flow.(fn ->
          Store.reconcile_subjects(runner.config, runner.flows, now, [persisted], [
            {"decision", "D-0025"}
          ])
        end)

      assert {waiting["state"], waiting["status"], waiting["generation"]} ==
               {"waiting", "active", 1}

      assert waiting["pending"]["writes"] == []

      assert {:ok, _} =
               as_flow.(fn -> AtlasFlow.Runs.Projection.project(runner, "decision", "D-0025") end)

      assert {:stored, _} =
               Talk.put("scene", %{
                 "op" => "create",
                 "key" => "SC-Atlas-01",
                 "by" => "melle",
                 "values" => %{"title" => "Carry out the historical decision"},
                 "links" => %{"based_on" => ["D-0025"]}
               })

      {:ok, [completed]} =
        as_flow.(fn ->
          Store.reconcile_subjects(runner.config, runner.flows, now, [waiting], [
            {"decision", "D-0025"}
          ])
        end)

      assert {completed["state"], completed["status"]} == {"carried_out", "completed"}
      assert completed["pending"]["writes"] == []

      assert {:ok, [^completed]} =
               as_flow.(fn ->
                 Store.reconcile_subjects(runner.config, runner.flows, now, [completed], [
                   {"decision", "D-0025"}
                 ])
               end)

      assert {:ok, ^prior_run} = Rela.get(rela, plural.(runner.config["kind"]), history["key"])
      assert {:ok, carried_out} = Rela.get(rela, plural.("decision"), "D-0025")
      assert carried_out.properties["work"] == 1
      assert Map.delete(carried_out.properties, "work") == original.properties
      assert carried_out.links == original.links

      IO.puts(
        "AFTER: exact Flow tally writes 0/2/0 pass; forged identities, ordinary sessions, mixed fields/links and new agent acceptance refuse; accepted fields/links preserved, no verdict fabricated"
      )

      IO.puts(
        "FLOW: native follow_through drains persisted work=0, waits, completes at work=1, replays stably; prior completed decide run unchanged"
      )
    end
  after
    GenServer.stop(facts)
  end
after
  System.cmd("kill", ["-TERM", to_string(pid)], stderr_to_stdout: true)
end
