# From products/software_factory:
# MIX_ENV=test mix run integration/runtime_upgrade_native.exs PRIVATE_NEW_DIR RELA_BIN_DIR
# Requires Go, Python 3, compiled Mix dependencies, and rela-server-headless-sqlite.
# PRIVATE_NEW_DIR must not exist. All Runtime, release and Rela state stays inside it.
# The real release fetch reads a deliberately absent local release, never the network.
import ExUnit.Assertions
alias AtlasFlow.Talk
alias AtlasRuntime.{Upgrade, Work}
alias AtlasRuntime.Sources.{InBeamTarget, Puller}

# The generated in-BEAM boundary translates Flow's ordinary work-source response; it
# neither supplies orders nor changes Flow's decisions. No leases are seeded in this proof.
defmodule UpgradeProof.Facade do
  use AtlasRuntimeBoundary.Generator.Targets.Boundary,
    contract: AtlasRuntimeBoundary.WorkSource,
    implementation: UpgradeProof.Source
end

defmodule UpgradeProof.Source do
  use UpgradeProof.Facade.Implementation
  alias UpgradeProof.Facade, as: F

  @impl true
  def poll({id, _rights}, input) do
    case AtlasFlow.WorkSource.poll({id, "tester"}, input) do
      {:polled, result} ->
        order = if result[:upgrade], do: struct!(F.UpgradeOrder, result.upgrade)

        %F.Outcome.Polled{
          leases: result.leases,
          cancel: result.cancel,
          lease_lost: result.lease_lost,
          timing: struct!(F.Timing, result.timing),
          configuration: result[:configuration],
          upgrade: order
        }

      {:rejected, reason} ->
        %F.Outcome.Rejected{reason: reason}
    end
  end

  @impl true
  def report({id, _rights}, input) do
    case AtlasFlow.WorkSource.report({id, "tester"}, input) do
      {:recorded, %{missing: missing}} -> %F.Outcome.Recorded{missing: missing}
      :lease_lost -> %F.Outcome.LeaseLost{}
      {:rejected, reason} -> %F.Outcome.Rejected{reason: reason}
    end
  end

  @impl true
  def get_blob({id, _rights}, input) do
    case AtlasFlow.WorkSource.get_blob({id, "tester"}, input) do
      {:blob, blob} -> struct!(F.Outcome.Blob, blob)
      :not_found -> %F.Outcome.NotFound{}
      {:rejected, reason} -> %F.Outcome.Rejected{reason: reason}
    end
  end
end

[dir, bin] = System.argv()
dir = Path.expand(dir)
assert not File.exists?(dir), "PRIVATE_NEW_DIR must not already exist"
File.mkdir_p!(dir)
root = Path.expand("../../..", __DIR__)
home = Path.join(dir, "runtime")
File.mkdir_p!(home)
File.mkdir_p!(Path.join(dir, "home"))
File.mkdir_p!(Path.join(dir, "releases"))
tool_bin = Path.join(dir, "bin")
File.mkdir_p!(tool_bin)
# The proof has no leases; this inert executable only makes the profile offerable.
File.write!(Path.join(tool_bin, "codex"), "#!/bin/sh\nexit 1\n")
File.chmod!(Path.join(tool_bin, "codex"), 0o700)
System.put_env("PATH", tool_bin <> ":" <> System.fetch_env!("PATH"))

for {name, value} <- [
      {"HOME", Path.join(dir, "home")},
      {"XDG_DATA_HOME", Path.join(dir, "data")},
      {"ATLAS_RUNTIME_HOME", home},
      {"ATLAS_RUNTIME_RELEASES", Path.join(dir, "releases")},
      {"ATLAS_RUNTIME_BUILD", "proof-old"},
      {"ATLAS_RUNTIME_EXECUTABLE", Path.join(dir, "atlas-runtime")}
    ],
    do: System.put_env(name, value)

{out, status} =
  System.cmd("go", ["build", "-o", Path.join(dir, "atlas-runtime"), "."],
    cd: Path.join(root, "platform/atlas_runtime/host"),
    stderr_to_stdout: true
  )

assert status == 0, out

policy = %{
  "version" => 1,
  "slots" => ["s1"],
  "buffer_size" => 1,
  "profiles" => %{
    "light_work" => %{
      "permissions" => ["read-only"],
      "cost_classes" => ["standard"],
      "options" => [%{"provider" => "openai", "harness" => "codex", "model" => "proof"}]
    }
  },
  "sources" => [
    %{
      "name" => "flow-proof",
      "kind" => "remote",
      "url" => "https://unused.invalid/",
      "credential_file" => "sources/flow-proof/token",
      "priority" => 1,
      "max_slots" => 1,
      "max_store_bytes" => 2_147_483_648
    }
  ]
}

File.write!(Path.join(home, "policy.json"), JSON.encode!(policy))
data = Path.join(dir, "rela")
File.mkdir_p!(data)

{out, status} =
  System.cmd(
    System.get_env("ATLAS_CONFIG_PYTHON") || "python3",
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
  Port.open({:spawn_executable, Path.join(Path.expand(bin), "rela-server-headless-sqlite")}, [
    :binary,
    :exit_status,
    :stderr_to_stdout,
    args: ["-project", data, "-bind", "127.0.0.1", "-port", to_string(port), "-quiet"]
  ])

{:os_pid, os_pid} = Port.info(server, :os_pid)

try do
  Application.put_env(:atlas, :model, Model.AtlasEyra)
  Application.put_env(:atlas, :actors, %{"decider" => "tester"})
  Application.put_env(:atlas_runtime, :runtime_home, home)

  {:ok, facts} =
    AtlasFacts.Server.start_link(
      rela: {AtlasFacts.Rela.Http, "http://127.0.0.1:#{port}/api/v1"},
      data_dir: Path.join(dir, "facts")
    )

  :ok = AtlasBus.attach("control/upgrade-proof")
  deadline = System.monotonic_time(:millisecond) + 30_000

  await = fn await, predicate ->
    case predicate.() do
      {:ok, value} ->
        value

      other ->
        assert System.monotonic_time(:millisecond) < deadline, "timed out: #{inspect(other)}"
        Process.sleep(50)
        await.(await, predicate)
    end
  end

  await.(await, fn ->
    case Talk.read("_description", %{}) do
      %{"description" => %{"entities" => %{}}} -> {:ok, :ready}
      other -> other
    end
  end)

  put = fn kind, content -> assert {:stored, _} = Talk.put(kind, content), inspect(content) end

  read = fn ->
    %{"fact" => fact} = Talk.read("runtime_upgrade", %{"key" => "RU-01", "plain" => true})
    fact["values"]
  end

  Task.async(fn ->
    :ok = AtlasBus.attach("flow/delivery")

    assert {:stored, _} =
             Talk.put("machinery", %{
               "op" => "create",
               "key" => "proof-mini",
               "by" => "flow",
               "values" => %{"name" => "Proof mini"}
             })
  end)
  |> Task.await(30_000)

  put.("runtime_upgrade", %{
    "op" => "create",
    "key" => "RU-01",
    "values" => %{"build" => "proof-missing"},
    "links" => %{"upgrade_of" => ["proof-mini"]}
  })

  {:ok, delivery} = AtlasFlow.Delivery.start_link(model: Model.AtlasEyra)

  {:ok, dispatch} =
    AtlasFlow.Dispatch.start_link(
      model: Model.AtlasEyra,
      poll_wait: 1,
      sweep_ms: nil,
      resync_ms: nil
    )

  {:ok, service} = AtlasRuntime.Service.start(home)
  {:ok, work} = Work.start_link(home)

  {:ok, listener} =
    AtlasRuntime.Backend.Listener.start_link(home: home, router: AtlasRuntime.Backend.Rest)

  {:ok, puller} =
    Puller.start_link(
      name: "flow-proof",
      runtime_id: "proof-mini",
      target: {InBeamTarget, %{facade: UpgradeProof.Facade, client: {"proof-mini", [:lease]}}},
      polling: :manual,
      tick: :manual
    )

  assert Work.mode() == :open
  Puller.poll_now(puller)
  assert Work.mode() == :draining
  assert %{"step" => "draining", "from_build" => "proof-old"} = read.()
  assert Work.offer("flow-proof") == %{}
  Puller.poll_now(puller)
  assert %{"step" => "updating"} = read.()
  assert Work.mode() == :draining

  record =
    await.(await, fn ->
      case Upgrade.record(home) do
        %{"upgrade" => "RU-01", "state" => "failed", "step" => "update"} = record -> {:ok, record}
        other -> other
      end
    end)

  assert record["reason"] =~ "proof-missing"
  assert Work.mode() == :draining

  # The failed record is reported by the real puller; Flow durably records its cause
  # before ordering resume. Stop/restart Delivery before it sees the open confirmation.
  Puller.poll_now(puller)
  assert %{"step" => "updating", "failed_step" => "update", "reason" => reason} = read.()
  assert reason == record["reason"]
  assert Work.mode() == :open
  GenServer.stop(delivery)
  {:ok, delivery} = AtlasFlow.Delivery.start_link(model: Model.AtlasEyra)
  assert %{"step" => "updating", "failed_step" => "update", "reason" => ^reason} = read.()
  Puller.poll_now(puller)
  assert %{"step" => "failed", "failed_step" => "update", "reason" => ^reason} = read.()
  assert Work.mode() == :open
  assert Work.offer("flow-proof") != %{}
  assert :ok = Work.offer_done("flow-proof", 0)
  Puller.poll_now(puller)
  assert %{"state" => "failed", "upgrade" => "RU-01"} = Upgrade.record(home)
  GenServer.stop(puller)
  Supervisor.stop(listener)
  GenServer.stop(work)
  GenServer.stop(service)
  GenServer.stop(dispatch)
  GenServer.stop(delivery)
  GenServer.stop(facts)

  IO.puts(
    "runtime-upgrade native proof: drain, failed local release fetch, persisted recovery across Delivery restart, resumed"
  )
after
  System.cmd("/bin/kill", ["-TERM", to_string(os_pid)], stderr_to_stdout: true)

  receive do
    {^server, {:exit_status, _}} -> :ok
  after
    5_000 ->
      System.cmd("/bin/kill", ["-KILL", to_string(os_pid)], stderr_to_stdout: true)
  end

  if Port.info(server), do: Port.close(server)
end
