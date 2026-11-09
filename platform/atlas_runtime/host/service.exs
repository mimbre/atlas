# Runtime service. Neither Atlas core services nor an orchestration engine starts.
alias AtlasRuntime.Integrations.AtlasServer.Lifecycle

[dir] = System.argv()

# Opt-in Atlas Server lifecycle reporting (`server.json`): its Bus link is configured before
# anything starts. Without it, nothing connects and the service is unchanged.
server = Lifecycle.load!(dir)

if server do
  Application.put_env(:atlas_bus, :environment, server.environment, persistent: true)
  Application.put_env(:atlas_bus, :link, Lifecycle.link(server), persistent: true)
  # Its output endpoint is this machine's: `runtime@<machine>/output`, the link's own.
  Application.put_env(:atlas_runtime, :server_lifecycle, server.machine, persistent: true)
  # The reporter writes the Server's turn and execution records under the model's names
  # (AtlasRuntime.Model). The service runs with MIX_ENV=test, where no model is
  # configured, so it is wired here, as config.exs wires it for the core.
  Application.put_env(:atlas, :model, Model.AtlasEyra, persistent: true)
  # Flow's passes for this machine reach the Service here (AtlasRuntime.FlowPasses), at
  # `runtime@<machine>/passes`, the one pass endpoint the link lets this machine attach;
  # its journal is under this Service's home, whose admissions it recovers.
  Application.put_env(:atlas_runtime, :flow_passes, [machine: server.machine, dir: dir],
    persistent: true
  )
end

{:ok, _} = Application.ensure_all_started(:atlas_runtime)
started = Enum.map(Application.started_applications(), &elem(&1, 0))

if Enum.any?([:atlas_facts, :atlas_flow, :atlas_control], &(&1 in started)),
  do: raise("Runtime must not start Atlas core services")

{:ok, _} = AtlasRuntime.Service.start(dir, server && Map.delete(server, :token))

# The work core (AtlasRuntime.Work) follows the Service and starts turns through it. A store
# it cannot read is a logged refusal: the Service keeps running, and the work contract
# answers "not accepting" until the store is repaired and the Runtime restarted.
case AtlasRuntime.Work.start_link(dir) do
  {:ok, _} -> :ok
  {:error, reason} -> IO.puts(:stderr, "Runtime work core not started: #{inspect(reason)}")
end

# The work contract's REST backend on backend.sock (mode 0600, the socket owner as client):
# the work commands are served there, no longer on runtime.sock. A listener that cannot start
# stops the service, so a running service always serves work.
case AtlasRuntime.Backend.Listener.start_link(home: dir, router: AtlasRuntime.Backend.Rest) do
  {:ok, _} -> :ok
  {:error, reason} -> raise("Runtime backend not listening on backend.sock: #{inspect(reason)}")
end

IO.puts("Runtime ready; Atlas core services remain stopped")
Process.sleep(:infinity)
