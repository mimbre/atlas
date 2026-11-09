defmodule AtlasE2E.FlowRunTest do
  use ExUnit.Case, async: false
  @root Path.expand("../..", __DIR__)
  @bin System.get_env("ATLAS_E2E_RELA_BIN") || System.get_env("ATLAS_RELA_BIN")
  @moduletag skip:
               if(@bin == nil, do: "set ATLAS_E2E_RELA_BIN to pinned Rela 26.11.2", else: false)
  @moduletag timeout: 120_000
  @moduletag :tmp_dir

  # The child owns all services and closes the private server even on an assertion failure.
  @proof ~S"""
  import ExUnit.Assertions
  alias AtlasFlow.{Engine, Talk}
  alias AtlasFlow.Runs.{Run, Store}
  [root, dir, bin, variant] = System.argv()
  data = Path.join(dir, "rela")
  File.mkdir_p!(data)
  python = System.get_env("ATLAS_CONFIG_PYTHON") || "python3"
  {out, status} = System.cmd(python, [Path.join(root, "rela/scripts/config.py"), "copy", "--root", Path.join(root, "rela"), "--data", data], stderr_to_stdout: true)
  assert status == 0, out
  {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
  {:ok, port_number} = :inet.port(socket)
  :gen_tcp.close(socket)
  url = "http://127.0.0.1:#{port_number}/api/v1"
  server = Port.open({:spawn_executable, Path.join(bin, "rela-server")}, [:binary, :exit_status, :stderr_to_stdout, args: ["-project", data, "-bind", "127.0.0.1", "-port", to_string(port_number), "-quiet"]])
  {:os_pid, os_pid} = Port.info(server, :os_pid)
  try do
    facts_data = Path.join(dir, "facts")
    {:ok, facts} = AtlasFacts.Server.start_link(rela: {AtlasFacts.Rela.Http, url}, data_dir: facts_data,
      description_extra: Path.join(root, "rela/atlas.json"), flow_runtime: Path.join(root, "rela/flow-runtime.json"))
    :ok = AtlasBus.attach("proof")
    # Wait for the consumer's authoritative answer, not a count of connection attempts.
    # The timeout only bounds a failed startup; it never establishes readiness.
    startup_deadline = System.monotonic_time(:millisecond) + 30_000
    await_facts = fn await_facts ->
      receive do
        {^server, {:exit_status, status}} -> flunk("rela-server exited during startup: #{status}")
      after
        0 -> :ok
      end
      case Talk.read("_description", %{}) do
        %{"description" => %{"entities" => %{"flow_run" => %{}},
          "flow_runtime" => %{"version" => 1}} = description} -> description
        answer ->
          assert System.monotonic_time(:millisecond) < startup_deadline,
            "Facts did not serve the run schema and runtime metadata; last answer: #{inspect(answer)}"
          await_facts.(await_facts)
      end
    end
    description = await_facts.(await_facts)
    {:ok, clock} = AtlasFlow.ManualClock.start_link(~U[2026-11-12 00:00:00Z])
    target = if variant == "timer" do
      Code.require_file(Path.join(root, "flow/contract/lib/decision.ex"))
      [flow] = AtlasFlowContract.Decision.__flows__()
      [initial | finals] = flow.states
      initial = %{initial | timers: [%{name: :retry, period: "5m", to: :proposed, since: nil, label: nil}]}
      flow = %{flow | states: [initial | finals]}
      yaml = AtlasFlowGenerator.Rela.flows_yaml([flow])
      File.write!(Path.join(dir, "flows.yaml"), yaml)
      json = AtlasFlowGenerator.Atlas.flows_json([flow], [], AtlasFlowGenerator.Atlas.sha256(yaml))
      json_path = Path.join(dir, "flows.json")
      File.write!(json_path, json)
      Code.compile_string("defmodule PrivateTarget do\nuse AtlasFlowGenerator.Runtime, target: #{inspect(json_path)}\nend")
      PrivateTarget
    else
      File.cp!(Path.join(root, "rela/flows.yaml"), Path.join(dir, "flows.yaml"))
      AtlasFlow.Generated
    end
    opts = [clock: {AtlasFlow.ManualClock, clock}, target: target, deployed_yaml: Path.join(dir, "flows.yaml"), every: 3_600_000]
    stop_flow = fn engine ->
      GenServer.stop(engine)
      for {_, pid, _, _} <- DynamicSupervisor.which_children(AtlasFlow.Supervisor),
        do: DynamicSupervisor.terminate_child(AtlasFlow.Supervisor, pid)
    end
    flush = fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(AtlasFlow.Supervisor) do
        if Process.alive?(pid) do
          send(pid, :look)
          try do :sys.get_state(pid) catch :exit, {:normal, _} -> :ok end
        end
      end
    end
    {:stored, _} = Talk.put("person", %{"op" => "create", "key" => "tester", "values" => %{"name" => "Tester"}})
    {:stored, _} = Talk.put("agent", %{"op" => "create", "key" => "coordinator", "values" => %{"name" => "Coordinator"}})
    {:stored, _} = Talk.put("decision", %{"op" => "create", "key" => "D-9999", "values" => %{"title" => "Private proof", "decision" => "Exercise the bridge", "status" => "proposed"}})
    {:stored, _} = Talk.put("issue", %{"op" => "create", "key" => "IS-Proof-01", "values" => %{"title" => "Legacy proof"}})
    # A client cannot forge the writer identity in content.
    assert {:refused, _} = Talk.put("flow_run", %{"op" => "create", "key" => "forged", "by" => "flow", "values" => %{}})
    {:ok, engine} = Engine.start_link(opts)
    Engine.round(engine)
    flush.()
    config = description["flow_runtime"]
    key = Run.key("decide", "decision", "D-9999", 1)
    read_run = fn ->
      %{"fact" => fact} = Talk.read("flow_run", %{"key" => key, "plain" => true})
      {:ok, run} = Store.decode(config, fact)
      run
    end
    first = read_run.()
    assert first["state"] == "proposed" and first["entry"] == 1
    %{"fact" => assignment} = Talk.read("assignment", %{"key" => "AS-IS-Proof-01", "plain" => true})
    assert assignment["values"]["expected"] == "Build it"
    if variant == "timer" do
      AtlasFlow.ManualClock.advance(clock, 299_999)
      Engine.round(engine)
      assert read_run.() == first
      stop_flow.(engine)
      {:ok, engine} = Engine.start_link(opts)
      Engine.round(engine)
      assert read_run.() == first
      AtlasFlow.ManualClock.advance(clock, 2)
      Engine.round(engine)
      second = read_run.()
      assert second["entry"] == 2
      assert Run.parse!(second["last_input"]["due"]) == ~U[2026-11-12 00:05:00.000Z]
      stop_flow.(engine)
      {:ok, engine} = Engine.start_link(opts)
      Engine.round(engine)
      assert read_run.() == second
      stop_flow.(engine)
    else
      {:stored, _} = Talk.put("decision", %{"op" => "change", "key" => "D-9999", "by" => "tester",
        "values" => %{"status" => "accepted", "decided_at" => "2026-11-12T00:00:00Z"}, "links" => %{"decided_by" => ["tester"]}})
      Engine.round(engine)
      completed = read_run.()
      assert completed["status"] == "completed" and completed["state"] == "accepted"
      stop_flow.(engine)
      {:ok, engine} = Engine.start_link(opts)
      Engine.round(engine)
      assert read_run.() == completed
      stop_flow.(engine)
    end
    GenServer.stop(facts)
    Agent.stop(clock)
    IO.puts("flow-run proof: #{variant} ok")
  after
    System.cmd("/bin/kill", ["-TERM", to_string(os_pid)], stderr_to_stdout: true)
    if Port.info(server), do: Port.close(server)
  end
  """

  for variant <- ~w(normal timer) do
    @variant variant
    test "real Facts persistence: #{@variant}", %{tmp_dir: dir} do
      script = Path.join(dir, "proof.exs")
      File.write!(script, @proof)
      on_exit(fn -> File.rm_rf!(dir) end)

      {out, status} =
        System.cmd("mix", ["run", script, @root, dir, @bin, @variant],
          cd: Path.join(@root, "beam"),
          env: [{"MIX_ENV", "test"}],
          stderr_to_stdout: true
        )

      assert status == 0, out
      assert out =~ "flow-run proof: #{@variant} ok"
    end
  end

  @input_proof ~S'''
  import ExUnit.Assertions
  alias AtlasFlow.{Talk, ManualClock}
  alias AtlasFlow.Runs.{Run, Store}
  [dir, bin] = System.argv()
  # A private neutral contract and schema; no deployment selection is modified.
  data = Path.join(dir, "neutral")
  File.mkdir_p!(data)
  # Required by rela-server even though this proof uses only its HTTP API.
  File.write!(Path.join(data, "data-entry.yaml"), "app:\n  name: Private input proof\n")
  fields = ~w(request_id run flow subject_kind subject_key generation entry source_version subject_version actor roles changed_fields payload_digest status position prepared_at applied_at)
  run_fields = ~w(flow subject_kind subject_key generation definition_sha256 state entry entered_at status deadlines pending input_cursor last_input blocked_reason)
  schema = fn names, ints -> Map.new(names, &{&1, %{"type" => if(&1 in ints, do: "integer", else: "string")}}) end
  entities = %{
    "box" => %{"label" => "Box", "plural" => "boxes", "id_type" => "manual", "properties" => %{"choice" => %{"type" => "string"}}},
    "clerk" => %{"label" => "Clerk", "plural" => "clerks", "id_type" => "manual", "properties" => %{"name" => %{"type" => "string"}}},
    "cursor" => %{"label" => "Cursor", "plural" => "cursors", "id_type" => "manual", "properties" => schema.(run_fields, ~w(generation entry input_cursor))},
    "choice" => %{"label" => "Choice", "plural" => "choices", "id_type" => "manual", "properties" => schema.(fields, ~w(generation entry position))}
  }
  # JSON is a YAML subset accepted by Rela.
  File.write!(Path.join(data, "schema.yaml"), JSON.encode!(%{"version" => "1.0", "namespace" => "https://example.invalid/neutral#", "entities" => entities, "relations" => %{"chosen_by" => %{"label" => "chosen by", "from" => ["box"], "to" => ["clerk"], "max_outgoing" => 1}}}))
  projection = %{"field" => "todo"}
  config = %{"version" => 1, "kind" => "cursor", "fields" => Map.new(run_fields, &{&1, &1}), "writer" => %{"sender" => "flow", "by" => "flow"},
    "selection" => %{"sort" => %{"subject" => "box", "legacy" => "sort", "projection" => projection, "admission" => %{}, "imports" => [], "follow_through" => nil}},
    "inputs" => %{"kind" => "choice", "fields" => Map.new(fields, &{&1, &1}), "acl" => %{"clerk" => %{"update" => ["box"]}}, "roles" => %{"clerk" => "chosen_by"}}}
  File.write!(Path.join(dir, "extra.json"), JSON.encode!(%{"flows" => %{"sort" => Map.merge(projection, %{"kinds" => ["box"], "states" => [%{"name" => "waiting", "expected" => "Choose"}]})}}))
  File.write!(Path.join(dir, "runtime.json"), JSON.encode!(%{"flow_runtime" => config}))
  Code.compile_string("""
  defmodule PrivateChoiceContract do
    use AtlasFlowGenerator.Schema
    subflow :sort, subject: :box do
      run_as "system:flow"
      owner default: {:clerk, :ada}
      per_subject :one
      start :create
      initial :waiting
      state :waiting do
        wait_for [:clerk], on: :choice, yes: :done
      end
      final :done
    end
  end
  """)
  yaml = AtlasFlowGenerator.Rela.flows_yaml(PrivateChoiceContract.__flows__())
  File.write!(Path.join(dir, "flows.yaml"), yaml)
  json = AtlasFlowGenerator.Atlas.flows_json(PrivateChoiceContract.__flows__(), [], AtlasFlowGenerator.Atlas.sha256(yaml))
  File.write!(Path.join(dir, "flows.json"), json)
  Code.compile_string("defmodule PrivateChoiceTarget do\nuse AtlasFlowGenerator.Runtime, target: #{inspect(Path.join(dir, "flows.json"))}\nend")
  {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
  {:ok, port} = :inet.port(socket)
  :gen_tcp.close(socket)
  server = Port.open({:spawn_executable, Path.join(bin, "rela-server")}, [:binary, :exit_status, :stderr_to_stdout, args: ["-project", data, "-bind", "127.0.0.1", "-port", to_string(port), "-quiet"]])
  {:os_pid, os_pid} = Port.info(server, :os_pid)
  rela = {AtlasFacts.Rela.Http, "http://127.0.0.1:#{port}/api/v1"}
  facts_opts = [rela: rela, data_dir: Path.join(dir, "facts"), description_extra: Path.join(dir, "extra.json"), flow_runtime: Path.join(dir, "runtime.json")]
  input_kind = config["inputs"]["kind"]
  try do
    {:ok, facts} = AtlasFacts.Server.start_link(facts_opts)
    :ok = AtlasBus.attach("control/session-proof")
    await_facts = fn ->
      deadline = System.monotonic_time(:millisecond) + 30_000
      await = fn await, output ->
        receive do
          {^server, {:data, chunk}} -> await.(await, output <> chunk)
          {^server, {:exit_status, status}} -> flunk("rela-server exited: #{status}\n#{output}")
        after
          0 ->
            assert Port.info(server, :os_pid) == {:os_pid, os_pid}, "rela-server stopped\n#{output}"
            case Talk.read("_description", %{}) do
              %{"description" => %{"entities" => %{^input_kind => %{}}, "flow_runtime" => %{"inputs" => %{"kind" => ^input_kind}}} = d} -> d
              other ->
                assert System.monotonic_time(:millisecond) < deadline,
                  "Facts did not describe the input kind at #{inspect(rela)}: #{inspect(other)}\n#{output}"
                await.(await, output)
            end
        end
      end
      await.(await, "")
    end
    description = await_facts.()
    assert {:ok, ^config} = Store.activate(description, PrivateChoiceTarget, Path.join(dir, "flows.yaml"))
    {:stored, _} = Talk.put("clerk", %{"op" => "create", "key" => "ada", "values" => %{"name" => "Ada"}})
    {:stored, _} = Talk.put("box", %{"op" => "create", "key" => "B-1", "values" => %{}, "links" => %{"chosen_by" => ["ada"]}})
    {:ok, clock} = ManualClock.start_link(~U[2026-11-12 00:00:00Z])
    # Each reconcile runs in a fresh Flow process; only Facts survives it.
    as_flow = fn action ->
      Task.async(fn ->
        :ok = AtlasBus.attach("flow")
        try do action.() after Registry.unregister(AtlasBus.Endpoints, "flow") end
      end) |> Task.await()
    end
    reconcile = fn -> as_flow.(fn -> Store.reconcile(config, PrivateChoiceTarget.flows(), ManualClock.now(clock)) end) end
    assert {:ok, [waiting]} = reconcile.()
    %{"fact" => subject} = Talk.transition_read("box", %{"key" => "B-1", "plain" => true})
    values = %{"entry" => waiting["entry"], "request_id" => "proof-choice", "run" => waiting["key"], "source_version" => subject["version"], "changed_fields" => %{"choice" => "yes"}}
    assert {:refused, _} = Talk.put("choice", %{"op" => "submit", "by" => "stranger", "values" => Map.put(values, "roles", ["clerk"])})
    assert {:refused, _} = Talk.put("choice", %{"op" => "submit", "by" => "stranger", "values" => values})
    assert {:stored, _} = Talk.put("choice", %{"op" => "submit", "by" => "ada", "values" => values})
    # Input exists and Flow has not consumed it. Restart Facts as well as the caller.
    GenServer.stop(facts)
    assert Port.info(server, :os_pid) == {:os_pid, os_pid}
    {:ok, facts} = AtlasFacts.Server.start_link(facts_opts)
    _description = await_facts.()
    assert {:ok, [%{"state" => "done", "entry" => 2} = completed]} = reconcile.()
    assert {:ok, [^completed]} = reconcile.()
    %{"inputs" => [input]} = as_flow.(fn -> Talk.read("choice", %{"run" => waiting["key"]}) end)
    assert input["status"] == "consumed"
    assert input["actor"] == "ada" and input["roles"] == ["clerk"]
    assert completed["last_input"]["input"] == input["key"]
    assert completed["key"] == Run.key("sort", "box", "B-1", 1)
    GenServer.stop(facts)
    Agent.stop(clock)
    IO.puts("flow-input proof: authorized, restart, consumed once ok")
  after
    System.cmd("/bin/kill", ["-TERM", to_string(os_pid)], stderr_to_stdout: true)
    if Port.info(server), do: Port.close(server)
  end
  '''

  test "real Facts persistence: trusted input across restart", %{tmp_dir: dir} do
    script = Path.join(dir, "input-proof.exs")
    File.write!(script, @input_proof)
    on_exit(fn -> File.rm_rf!(dir) end)

    {out, status} =
      System.cmd("mix", ["run", script, dir, @bin],
        cd: Path.join(@root, "beam"),
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    assert out =~ "flow-input proof: authorized, restart, consumed once ok"
  end
end
