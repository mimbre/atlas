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
end
