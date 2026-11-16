# Real production model, Facts, private Rela, Engine and Bus. All storage is native;
# the adapter delegates to HTTP and can refuse only the required parent projection.
# MIX_ENV=test mix run integration/flow_parent_settlement_native.exs DIR BIN pr_review|pr_test normal|failure|ancestor_failure
defmodule ParentSettlementNative.Rela do
  @behaviour AtlasFacts.Rela
  alias AtlasFacts.Rela.Http
  def description({base, _}), do: Http.description(base)
  def list({base, _}, plural), do: Http.list(base, plural)
  def get({base, _}, plural, key), do: Http.get(base, plural, key)
  def incoming({base, _}, plural, key, rel), do: Http.incoming(base, plural, key, rel)

  def check_create({base, _}, plural, key, props, targets),
    do: Http.check_create(base, plural, key, props, targets)

  def create({base, _}, plural, key, props, targets),
    do: Http.create(base, plural, key, props, targets)

  def delete({base, _}, plural, key, version), do: Http.delete(base, plural, key, version)

  def change({base, gate}, plural, key, props, version, targets) do
    if plural == "assignments" and key == Agent.get(gate, & &1),
      do: {:error, :unavailable},
      else: Http.change(base, plural, key, props, version, targets)
  end
end

import ExUnit.Assertions
alias AtlasFlow.{Engine, Talk}
alias AtlasFlow.Runs.Store
[dir, bin, kind, mode] = System.argv()

{relation, plural, verdict} =
  case kind do
    "pr_review" -> {"review_of", "pr_reviews", "changes_requested"}
    "pr_test" -> {"test_of", "pr_tests", "failed"}
  end

{:ok, gate} = Agent.start_link(fn -> nil end)
root = Path.expand("../../..", __DIR__)
data = Path.join(dir, "rela")
File.mkdir_p!(data)

{output, 0} =
  System.cmd(
    System.fetch_env!("ATLAS_CONFIG_PYTHON"),
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

assert is_binary(output)
{:ok, listener} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
{:ok, port} = :inet.port(listener)
:gen_tcp.close(listener)

server =
  Port.open({:spawn_executable, Path.join(bin, "rela-server-headless-sqlite")}, [
    :binary,
    :exit_status,
    :stderr_to_stdout,
    args: ["-project", data, "-bind", "127.0.0.1", "-port", to_string(port), "-quiet"]
  ])

{:os_pid, os_pid} = Port.info(server, :os_pid)

try do
  Application.put_env(:atlas, :model, Model.AtlasEyra)
  Application.put_env(:atlas, :actors, %{"decider" => "reviewer-1"})

  {:ok, facts} =
    AtlasFacts.Server.start_link(
      rela: {ParentSettlementNative.Rela, {"http://127.0.0.1:#{port}/api/v1", gate}},
      data_dir: Path.join(dir, "facts")
    )

  :ok = AtlasBus.attach("control/session-independent-settlement")
  deadline = System.monotonic_time(:millisecond) + 30_000

  await = fn await ->
    case Talk.read("_description", %{}) do
      %{"description" => %{"entities" => %{}}} ->
        :ok

      _ ->
        assert System.monotonic_time(:millisecond) < deadline
        await.(await)
    end
  end

  await.(await)

  for {kind, key, name} <- [
        {"person", "reviewer-1", "Reviewer"},
        {"agent", "coordinator", "Coordinator"}
      ] do
    assert {:stored, _} =
             Talk.put(kind, %{"op" => "create", "key" => key, "values" => %{"name" => name}})
  end

  pr = "PR-eyra-atlas-9501"
  issue = "IS-eyra-atlas-9501"

  assert {:stored, _} =
           Talk.put("issue", %{
             "op" => "create",
             "key" => issue,
             "values" => %{
               "title" => "Nested settlement",
               "description" => "Proof",
               "stage" => "specification"
             }
           })

  assert {:stored, _} =
           Talk.put("pull_request", %{
             "op" => "create",
             "key" => pr,
             "links" => %{"in_issue" => [issue]},
             "values" => %{
               "url" => "https://github.com/eyra/atlas/pull/9501",
               "revision" => "r1",
               "state" => "open"
             }
           })

  body =
    JSON.encode!(%{
      "properties" => %{"title" => "Independent review", "revision" => "r1"},
      "relations" => %{relation => %{"data" => [%{"type" => "pull_request", "id" => pr}]}}
    })

  request = {~c"http://127.0.0.1:#{port}/api/v1/#{plural}", [], ~c"application/json", body}

  assert {:ok, {{_, status, _}, _, raw}} =
           :httpc.request(:post, request, [timeout: 5000], body_format: :binary)

  assert status in [200, 201], raw
  %{"id" => review} = JSON.decode!(raw)
  {:ok, engine} = Engine.start_link(model: Model.AtlasEyra, environment: :test, every: 3_600_000)

  try do
    Engine.round(engine)
    assert :sys.get_state(engine).refusal == nil

    read = fn kind, key ->
      %{"fact" => fact} = Talk.transition_read(kind, %{"key" => key, "plain" => true})
      fact
    end

    assignment = "AS-" <> pr
    issue_assignment = "AS-" <> issue
    assert read.("assignment", assignment)["values"]["flow_state"] == "checking"
    config = :sys.get_state(engine).runner.config
    assert {:ok, issue_before} = Store.latest(config, "issue", "issue", issue)
    # A direct native fixture write has no hint: only the child's returned ancestor
    # subject can cause this Assignment to be projected before its settled response.
    base = "http://127.0.0.1:#{port}/api/v1"
    assert {:ok, raw_assignment} = AtlasFacts.Rela.Http.get(base, "assignments", issue_assignment)

    assert {:ok, _} =
             AtlasFacts.Rela.Http.change(
               base,
               "assignments",
               issue_assignment,
               %{"expected" => "stale"},
               raw_assignment.version,
               %{}
             )

    failed_assignment = if mode == "ancestor_failure", do: issue_assignment, else: assignment

    if mode in ["failure", "ancestor_failure"],
      do: Agent.update(gate, fn _ -> failed_assignment end)

    assert {:stored, p} =
             Talk.put(kind, %{
               "op" => "change",
               "key" => review,
               "by" => "reviewer-1",
               "values" => %{"verdict" => verdict},
               "links" => %{"verdict_by" => ["reviewer-1"]}
             })

    settled_request = %{AtlasBus.Envelope.new("request", "_settled") | address: "flow"}
    settled_request_id = settled_request.id
    :ok = AtlasBus.send(settled_request, %{"position" => p})

    if mode in ["failure", "ancestor_failure"] do
      state = :sys.get_state(engine)
      assert AtlasFlow.Settled.value(state.settled) < p
      refute_received {:atlas_bus, %{id: ^settled_request_id, class: "answer"}, _}

      assert {:ok, %{"state" => "changes_requested"}} =
               Store.latest(state.runner.config, "pull_request", "pull_request", pr)

      if mode == "ancestor_failure" do
        assert read.("assignment", issue_assignment)["values"]["expected"] == "stale"
      else
        assert read.("assignment", assignment)["values"]["flow_state"] == "checking"
      end

      Engine.round(engine)
      assert AtlasFlow.Settled.value(:sys.get_state(engine).settled) < p
      refute_received {:atlas_bus, %{id: ^settled_request_id, class: "answer"}, _}
      Agent.update(gate, fn _ -> nil end)
      Engine.round(engine)
    end

    receive do
      {:atlas_bus, %{id: id, class: "answer"}, %{"settled" => settled}}
      when id == settled_request.id ->
        assert settled >= p
    after
      5000 -> flunk("settlement did not answer")
    end

    %{config: config} = AtlasFlow.Model.load(Model.AtlasEyra, :test)
    assert {:ok, parent} = Store.latest(config, "pull_request", "pull_request", pr)
    assert parent["state"] == "changes_requested"
    projected = read.("assignment", assignment)["values"]
    assert projected["flow_state"] == "changes_requested"
    assert projected["expected"] == "Make the changes asked for"
    assert {:ok, issue_after} = Store.latest(config, "issue", "issue", issue)
    assert issue_after["entry"] == issue_before["entry"] + 1
    assert read.("assignment", issue_assignment)["values"]["flow_state"] == "author"
    assert read.("assignment", issue_assignment)["values"]["expected"] == "Build it"

    IO.puts(
      "NATIVE PARENT SETTLEMENT: #{relation}, #{mode}; durable parent and Assignment current before settled response; recovery checked."
    )
  after
    GenServer.stop(engine)
  end

  GenServer.stop(facts)
after
  System.cmd("/bin/kill", ["-TERM", to_string(os_pid)], stderr_to_stdout: true)

  receive do
    {^server, {:exit_status, _}} -> :ok
  after
    5000 ->
      System.cmd("/bin/kill", ["-KILL", to_string(os_pid)], stderr_to_stdout: true)

      receive do
        {^server, {:exit_status, _}} -> :ok
      after
        1000 -> raise "private Rela did not exit"
      end
  end

  if Port.info(server), do: Port.close(server)
  Agent.stop(gate)
end
