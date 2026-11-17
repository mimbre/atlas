# Runtime service. Neither Atlas core services nor an orchestration engine starts.
alias AtlasRuntime.Integrations.AtlasServer.Lifecycle

[dir] = System.argv()

# This Service's home, for the reads that are not handed it (the history contract's): the
# host leaves $ATLAS_RUNTIME_HOME unset for the default home.
Application.put_env(:atlas_runtime, :runtime_home, dir, persistent: true)

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
end

# What the Runtime's own start brought up, and only that: a VM that already runs other apps
# (a test run of the whole umbrella evaluates this file in its own BEAM) is not the
# Runtime starting them.
{:ok, started} = Application.ensure_all_started(:atlas_runtime)

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

# No network listener on an agent machine (the pull design): a TCP listen socket in this VM,
# whatever opened it, fails the start before ready is reported (AtlasRuntime.ListenerCheck).
case AtlasRuntime.ListenerCheck.verify() do
  :ok -> :ok
  {:error, refusal} -> raise("Runtime not ready: " <> JSON.encode!(refusal))
end

IO.puts("Runtime ready; Atlas core services remain stopped")
Process.sleep(:infinity)
