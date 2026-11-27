# Private real Rela/Facts/Control proof; run from products/software_factory:
# MIX_ENV=test mix run integration/decision_details_native.exs PRIVATE_DIR RELA_BIN_DIR
import ExUnit.Assertions
alias AtlasFlow.Talk

[dir, bin] = System.argv()
root = Path.expand("../../..", __DIR__)
data = Path.join(dir, "rela")
File.mkdir_p!(data)
assert {:ok, _, _} = Kernel.ParallelCompiler.compile(Path.wildcard(Path.join(root, "platform/clients/{transport,agent}/lib/**/*.ex")))
{out, status} = System.cmd(System.get_env("ATLAS_CONFIG_PYTHON") || "python3", [
  Path.join(root, "platform/atlas_facts/rela/scripts/config.py"), "copy", "--root",
  Path.join(root, "products/software_factory/model/targets/rela"), "--data", data
], stderr_to_stdout: true)
assert status == 0, out
{:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
{:ok, port} = :inet.port(socket)
:gen_tcp.close(socket)
server = Port.open({:spawn_executable, Path.join(bin, "rela-server-headless-sqlite")}, [
  :binary, :exit_status, :stderr_to_stdout,
  args: ["-project", data, "-bind", "127.0.0.1", "-port", to_string(port), "-quiet"]
])
{:os_pid, pid} = Port.info(server, :os_pid)

try do
  Application.put_env(:atlas, :model, Model.AtlasEyra)
  Application.put_env(:atlas, :actors, %{"decider" => "ada"})
  {:ok, facts} = AtlasFacts.Server.start_link(
    rela: {AtlasFacts.Rela.Http, "http://127.0.0.1:#{port}/api/v1"},
    data_dir: Path.join(dir, "facts")
  )
  :ok = AtlasBus.attach("control/session-decision-details-proof")
  deadline = System.monotonic_time(:millisecond) + 30_000
  await = fn await ->
    case Talk.read("_description", %{}) do
      %{"description" => %{"entities" => %{}}} -> :ok
      other ->
        assert System.monotonic_time(:millisecond) < deadline, inspect(other)
        await.(await)
    end
  end
  await.(await)
  assert {:stored, _} = Talk.put("person", %{"op" => "create", "key" => "ada", "values" => %{"name" => "ada"}})
  {:ok, gateway} = AtlasControl.Gateway.start_link(port: 0, model: Model.AtlasEyra)
  settings = %{"env" => AtlasBus.environment(), "control" => %{"host" => "127.0.0.1", "port" => AtlasControl.Gateway.port(gateway)}}
  definition = File.read!(Path.join(root, "products/software_factory/e2e/fixtures/decision-options.json"))
  assert {:stored, _} = Talk.put("decision", %{
    "op" => "create", "key" => "D-private-details", "by" => "ada",
    "values" => %{"title" => "Private details", "decision" => "A private rule", "status" => "proposed",
      "options" => definition, "category" => "product", "scope" => "software",
      "reversibility" => "two_way", "force" => "direction"}
  })
  System.put_env("ATLAS_AS", "ada")
  assert {:ok, client} = AtlasAgent.Client.connect(AtlasBus.environment(), settings)
  assert {:ok, page} = AtlasAgent.Client.open(client, "/k/decision/D-private-details")
  blocks = Map.new(page["blocks"], &{&1["id"], &1["props"]})
  assert blocks["decision-detail-0"]["title"] == "Authority and status"
  assert blocks["decision-detail-1"]["title"] == "Scope and reversibility"
  assert blocks["decision-detail-2"]["title"] == "Usage and enforcement"
  assert hd(blocks["decision-raw-options"]["fields"])["value"] == definition
  assert Enum.any?(page["markup"], fn mark ->
    mark["kind"] == "section" and mark["props"]["title"] == "Technical details" and
      mark["props"]["collapsible"] == true
  end)
  AtlasAgent.Client.close(client)
  Process.unlink(gateway)
  GenServer.stop(gateway, :shutdown)
  GenServer.stop(facts)
  IO.puts("decision_details_native: real Control grouped details and exact stored definition: pass")
after
  System.cmd("/bin/kill", ["-TERM", to_string(pid)], stderr_to_stdout: true)
  receive do
    {^server, {:exit_status, _}} -> :ok
  after
    5_000 -> System.cmd("/bin/kill", ["-KILL", to_string(pid)], stderr_to_stdout: true)
  end
  if Port.info(server), do: Port.close(server)
end
