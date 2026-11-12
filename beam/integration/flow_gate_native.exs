# Native persistence/authorization proof. Owns and stops its private Rela and Facts.
# MIX_ENV=test mix run integration/flow_gate_native.exs PRIVATE_DIR RELA_BIN_DIR
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
  now = ~U[2026-11-12 00:00:00Z]
  {:ok, clock} = ManualClock.start_link(now)

  facts_opts = [
    rela: {AtlasFacts.Rela.Http, "http://127.0.0.1:#{port}/api/v1"},
    data_dir: Path.join(dir, "facts"),
    description_extra: Path.join(root, "rela/atlas.json"),
    flow_runtime: Path.join(root, "rela/flow-runtime.json"),
    flow_input_clock: fn -> ManualClock.now(clock) end
  ]

  {:ok, facts} = AtlasFacts.Server.start_link(facts_opts)
  {:ok, gates} = AtlasGates.Endpoint.start_link(now: fn -> ManualClock.now(clock) end)
  :ok = AtlasBus.attach("control/session-gate-proof")
  readiness_deadline = System.monotonic_time(:millisecond) + 30_000

  await = fn await ->
    case Talk.read("_description", %{}) do
      %{"description" => %{"flow_runtime" => %{} = c} = d} ->
        {d, c}

      other ->
        assert System.monotonic_time(:millisecond) < readiness_deadline, inspect(other)
        await.(await)
    end
  end

  {description, config} = await.(await)

  {:ok, target} =
    AtlasFlowGenerator.Runtime.read(Path.join(root, "flow/targets/test/atlas/flows.json"))

  flows = target["flows"]

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

  put.("person", %{"op" => "create", "key" => "tester", "values" => %{"name" => "Tester"}})

  put.("agent", %{
    "op" => "create",
    "key" => "coordinator",
    "values" => %{"name" => "Coordinator"}
  })

  create = fn key, force ->
    put.("decision", %{
      "op" => "create",
      "key" => key,
      "values" => %{
        "title" => "Timeout proof #{key}",
        "decision" => "Exercise the gate",
        "status" => "proposed",
        "category" => "process",
        "scope" => "platform",
        "force" => force,
        "reversibility" => "two_way",
        "enforced_by" => "flow gate proof"
      }
    })
  end

  create.("D-9997", "direction")
  create.("D-9998", "principle")

  put.("issue", %{
    "op" => "create",
    "key" => "IS-Gate-01",
    "values" => %{"title" => "Based on timeout proof"}
  })

  put.("issue", %{"op" => "change", "key" => "IS-Gate-01", "links" => %{"based_on" => ["D-9997"]}})

  # A deploy starts the core over existing Facts, rather than first scanning an empty store.
  # Seed the slice-1 cursor before starting Flow's engine. The native gate must record
  # one verdict for its fresh migrated entry, including after engine restart.
  old = AtlasFlow.Runs.Run.new("decide", flows["decide"], read.("decision", "D-9997"), [], now)

  old =
    Map.merge(old, %{
      "definition_sha256" => "8ca16b332a083209e6e44ffc3feeca0f152c632caa4d5206ab24fe540ab3770c",
      "state" => "proposed",
      "entry" => 1,
      "pending" => %{"version" => 1, "writes" => []}
    })

  Task.async(fn ->
    :ok = AtlasBus.attach("flow")

    assert {:stored, _} =
             Talk.put(config["kind"], %{
               "op" => "create",
               "key" => old["key"],
               "by" => config["writer"]["by"],
               "values" => Store.encode(config, old)
             })
  end)
  |> Task.await(30_000)

  engine_opts = [
    clock: {ManualClock, clock},
    target: AtlasFlow.Generated.Test,
    deployed_yaml: Path.join(root, "flow/targets/test/rela/flows.yaml")
  ]

  for _ <- 1..2 do
    {:ok, engine} = AtlasFlow.Engine.start_link(engine_opts)
    AtlasFlow.Engine.round(engine)
    assert :sys.get_state(engine).refusal == nil
    GenServer.stop(engine)

    for {_, pid, _, _} <- DynamicSupervisor.which_children(AtlasFlow.Supervisor),
        do: DynamicSupervisor.terminate_child(AtlasFlow.Supervisor, pid)
  end

  assert {:ok, runs} = reconcile.()
  first = Enum.find(runs, &(&1["subject_key"] == "D-9997"))
  fixed = Enum.find(runs, &(&1["subject_key"] == "D-9998"))
  assert first["state"] == "for_person"
  assert first["entry"] == 3
  assert [migration] = first["pending"]["migrations"]
  assert migration["from"] == old["definition_sha256"]
  %{"facts" => verdicts} = Talk.read("gate_verdict", %{})
  assert Enum.count(verdicts, &(&1["values"]["subject"] == "D-9997")) == 1
  assert fixed["state"] == "for_person_always" and fixed["deadlines"]["timers"] == []
  [deadline] = first["deadlines"]["timers"]
  # Restart Facts while Flow has no process state; the durable deadline is unchanged.
  GenServer.stop(facts)
  {:ok, facts} = AtlasFacts.Server.start_link(facts_opts)
  _ = await.(await)
  ManualClock.advance(clock, 299_999)
  assert {:ok, before} = reconcile.()
  assert Enum.find(before, &(&1["key"] == first["key"]))["deadlines"]["timers"] == [deadline]
  ManualClock.advance(clock, 1)
  assert {:ok, after_limit} = reconcile.()
  late = Enum.find(after_limit, &(&1["key"] == first["key"]))
  assert late["state"] == "for_agent_unverified"
  verdict_key = late["pending"]["verdict"]["recorded"]
  verdict = read.("gate_verdict", verdict_key)
  assert verdict["links"]["follows"] == [first["pending"]["verdict"]["recorded"]]
  assert verdict["values"]["evidence"] =~ "timed_out: true"
  assert read.("decision", "D-9997")["values"]["unverified"] == true

  assert {:refused, _} =
           Talk.put("decision", %{
             "op" => "change",
             "key" => "D-9997",
             "by" => "tester",
             "values" => %{"unverified" => false}
           })

  # An ordinary authorized Control write is prepared as a trusted input before it applies.
  put.("decision", %{
    "op" => "change",
    "key" => "D-9997",
    "by" => "coordinator",
    "values" => %{"status" => "accepted", "decided_at" => "2026-11-12T00:05:00Z"},
    "links" => %{"decided_by" => ["coordinator"]}
  })

  assert {:ok, completed} = reconcile.()
  assert Enum.find(completed, &(&1["key"] == first["key"]))["state"] == "accepted"
  %{"fact" => work} = Talk.read("issue", %{"key" => "IS-Gate-01"})
  assert work["review"]["label"] == "Based on unverified decisions"
  %{"fact" => decision} = Talk.read("decision", %{"key" => "D-9997"})
  assert decision["review"]["label"] == "🔴 Unverified decision"

  put.("gate_verdict", %{
    "op" => "change",
    "key" => verdict_key,
    "by" => "tester",
    "links" => %{"reviewed_by" => ["tester"]}
  })

  assert {:ok, _} = reconcile.()
  assert read.("decision", "D-9997")["values"]["unverified"] == false
  %{"fact" => work} = Talk.read("issue", %{"key" => "IS-Gate-01"})
  assert work["review"] == nil
  %{"fact" => decision} = Talk.read("decision", %{"key" => "D-9997"})
  assert decision["review"] == nil
  # Overruling also clears the flag, and the existing replaces rule supersedes the anchor.
  create.("D-9999", "direction")
  assert {:ok, _} = reconcile.()

  put.("decision", %{
    "op" => "change",
    "key" => "D-9999",
    "links" => %{"supersedes" => ["D-9997"]}
  })

  put.("decision", %{
    "op" => "change",
    "key" => "D-9999",
    "by" => "tester",
    "values" => %{"status" => "accepted", "decided_at" => "2026-11-12T00:05:00Z"},
    "links" => %{"decided_by" => ["tester"]}
  })

  put.("gate_verdict", %{
    "op" => "change",
    "key" => verdict_key,
    "by" => "tester",
    "values" => %{"overrule_reason" => "Superseded by D-9999"},
    "links" => %{"overruled_by" => ["tester"]}
  })

  assert {:ok, _} = reconcile.()
  assert read.("decision", "D-9997")["values"]["status"] == "superseded"
  %{"fact" => work} = Talk.read("issue", %{"key" => "IS-Gate-01"})
  assert work["review"]["label"] == "Review: based on a superseded decision"
  assert {:ok, final_runs} = reconcile.()
  assert Enum.find(final_runs, &(&1["key"] == fixed["key"]))["state"] == "for_person_always"
  assert description["relations"]["reviewed_by"]["only_target"]
  GenServer.stop(gates)
  GenServer.stop(facts)
  Agent.stop(clock)

  IO.puts(
    "flow-gate native proof: timeout, follows, trusted acceptance, restart, flags, confirm, overrule, fixed wait ok"
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
