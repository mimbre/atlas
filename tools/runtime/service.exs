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
end

Application.put_env(:atlas_runtime, :start, false)
{:ok, _} = Application.ensure_all_started(:atlas_runtime)
started = Enum.map(Application.started_applications(), &elem(&1, 0))

if Enum.any?([:atlas_state, :atlas_flow, :atlas_control], &(&1 in started)),
  do: raise("Runtime must not start Atlas core services")

{:ok, _} = AtlasRuntime.Service.start(dir, server && Map.delete(server, :token))
IO.puts("Runtime ready; Atlas core services remain stopped")
Process.sleep(:infinity)
