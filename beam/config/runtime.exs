import Config

# The Atlas environment (test or prod) is not Mix's environment. `bin/atlas-ops up --env <env>`
# sets ATLAS_ENV; its settings come from env/<env>.json at the repository root, the one
# file the BEAM node and the clients both read. There is no default: a node only starts
# for the environment it was told, so nothing reaches prod by accident.
if config_env() != :test do
  env = System.get_env("ATLAS_ENV")

  if env not in ["test", "prod"] do
    raise "ATLAS_ENV is #{inspect(env)}; start the core with bin/atlas-ops up --env test|prod"
  end

  root = System.get_env("ATLAS_ROOT") || Path.expand("../..", __DIR__)
  # ATLAS_ENV_FILE runs a second, private instance of an environment (other ports, other
  # data), so an agent's test run never meets the one Melle is using.
  file = System.get_env("ATLAS_ENV_FILE") || Path.join(root, "env/#{env}.json")
  settings = file |> File.read!() |> JSON.decode!()

  if settings["env"] != env do
    raise "#{file} is for #{inspect(settings["env"])}, not #{env}"
  end

  expand = &Path.expand(String.replace_prefix(&1, "~", System.user_home!()))

  config :atlas_bus, environment: env

  role = System.get_env("ATLAS_ROLE") || "core"
  if role not in ["core", "runtime"], do: raise("unknown ATLAS_ROLE")
  link = settings["bus_link"]

  if role == "runtime" do
    unless match?(%{"mode" => "client"}, link), do: raise("Runtime needs a client bus_link")
    config :atlas_bus, link: Map.put(link, "token", System.fetch_env!("ATLAS_BUS_LINK_TOKEN"))
  else
    if link do
      tokens = System.fetch_env!("ATLAS_BUS_LINK_TOKEN") |> JSON.decode!()
      config :atlas_bus, link: Map.merge(link, %{"mode" => "server", "tokens" => tokens})
    end

    config :atlas_facts,
      flow_runtime: Path.join(root, "rela/flow-runtime.json"),
      rela_url: settings["rela"]["url"],
      # On Fly rela has an IPv6 address on the private network only.
      rela_ipv6: settings["rela"]["ipv6"] == true,
      description_extra: settings["rela"]["extra"] && Path.join(root, settings["rela"]["extra"]),
      # Facts' own data folder (`facts.data`; settings files before the rename said `state`).
      data_dir:
        expand.(get_in(settings, ["facts", "data"]) || raise("#{file} has no facts.data")),
      # The connectors at Facts' edge: only those this environment has settings for.
      connectors: settings["connectors"] || %{}

    config :atlas_control,
      host: settings["control"]["host"],
      port: settings["control"]["port"],
      # Who uses a TUI of this environment (a key), until Control has sign-in.
      tui_user: settings["tui_user"],
      # Separate read capability; absent by default, never reuse Bus writer tokens.
      runtime_read_token_env: settings["control"]["runtime_read_token_env"]

    # Flow looks at each open fact again this often, and at once on a hint.
    config :atlas_flow,
      deployed_yaml:
        Path.join(
          root,
          if(env == "test", do: "flow/targets/test/rela/flows.yaml", else: "rela/flows.yaml")
        ),
      tick_seconds: get_in(settings, ["flow", "tick_seconds"]) || 60
  end

  if role == "runtime", do: System.delete_env("ATLAS_BUS_LINK_TOKEN")

  # Runtime runs the turns of this machine's agents (IS-Atlas-15); without `runtime`, none.
  runtime = settings["runtime"] || %{}

  config :atlas_runtime,
    settings:
      if(runtime["stub_dir"],
        do: Map.put(runtime, "stub_dir", expand.(runtime["stub_dir"])),
        else: runtime
      )
end
