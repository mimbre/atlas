import Config

# The Atlas environment (test or prod) is not Mix's environment. `bin/atlas-ops up --env <env>`
# sets ATLAS_ENV; its settings come from products/software_factory/environments/<env>.json at the repository root, the one
# file the BEAM node and the clients both read. There is no default: a node only starts
# for the environment it was told, so nothing reaches prod by accident.
if config_env() != :test do
  env = System.get_env("ATLAS_ENV")

  if env not in ["test", "prod"] do
    raise "ATLAS_ENV is #{inspect(env)}; start the core with bin/atlas-ops up --env test|prod"
  end

  root = System.get_env("ATLAS_ROOT") || Path.expand("../../..", __DIR__)
  # ATLAS_ENV_FILE runs a second, private instance of an environment (other ports, other
  # data), so an agent's test run never meets the one Melle is using.
  file =
    System.get_env("ATLAS_ENV_FILE") ||
      Path.join(root, "products/software_factory/environments/#{env}.json")

  settings = file |> File.read!() |> JSON.decode!()

  if settings["env"] != env do
    raise "#{file} is for #{inspect(settings["env"])}, not #{env}"
  end

  expand = &Path.expand(String.replace_prefix(&1, "~", System.user_home!()))

  config :atlas_bus, environment: env

  link = settings["bus_link"]

  if link do
    tokens = System.fetch_env!("ATLAS_BUS_LINK_TOKEN") |> JSON.decode!()
    config :atlas_bus, link: Map.merge(link, %{"mode" => "server", "tokens" => tokens})
  end

  # What Facts stores by is the model's (config :atlas, model:), compiled in; rela must
  # serve the schema it was built with, or Facts does not start.
  config :atlas_facts,
    rela_url: settings["rela"]["url"],
    # On Fly rela has an IPv6 address on the private network only.
    rela_ipv6: settings["rela"]["ipv6"] == true,
    # On Fly only the core may use rela (IS-Atlas-80): `rela.token_env` names the variable
    # (a Fly secret of both apps) with the credential rela's edge asks for. None on a Mac.
    rela_token: if(name = settings["rela"]["token_env"], do: System.fetch_env!(name)),
    # Facts' own data folder (`facts.data`; settings files before the rename said `state`).
    data_dir: expand.(get_in(settings, ["facts", "data"]) || raise("#{file} has no facts.data")),
    # The connectors at Facts' edge: only those this environment has settings for.
    connectors: settings["connectors"] || %{}

  config :atlas_control,
    host: settings["control"]["host"],
    port: settings["control"]["port"],
    # Who uses a TUI of this environment (a key), until Control has sign-in.
    tui_user: settings["tui_user"],
    # Separate read capability; absent by default, never reuse Bus writer tokens.
    runtime_read_token_env: settings["control"]["runtime_read_token_env"],
    # What this environment adds to the model's pages (AtlasControl.Model.catalog/2): the
    # shell's extra tabs ("tabs") and who may read and submit worker guidance
    # ("workers": "read" and "submit", each {"actors": [key]}). None by default.
    settings: Map.take(settings["control"], ["tabs", "workers"])

  # Flow looks at each open fact again this often, and at once on a hint.
  config :atlas_flow, tick_seconds: get_in(settings, ["flow", "tick_seconds"]) || 60

  # Flow as the Runtimes' work source (work acquisition M3): only with a `flow.work_source`
  # block, none by default. `credentials_env` names the environment variable that holds
  # the per-Runtime credentials (a core secret: runtime id → holder and token sha256; `{}`
  # when every Runtime is installed through Control, whose credentials are on their
  # machinery facts, AtlasFlow.WorkSource.Registered).
  # With `port`, Flow listens on 127.0.0.1 at that port, behind the tailnet edge (TLS ends
  # there); without one it has no listener. Flow keeps no result store: a result travels
  # over Git (IS-Atlas-100), so a `results` folder is no setting any more.
  #
  # A test environment may shorten the lease timing (a bench such as pull-e2e): the integer
  # keys `lease_ttl` (s), `poll_max` (s, 1–25), `sweep_ms` and `resync_ms`, only those
  # given. Prod refuses them and keeps Flow's defaults (AtlasFlow.Dispatch). `grace` is not
  # settable in either: the
  # Runtime's own grace and import bound assume Flow's 120 s. The wire `timing` is unchanged.
  if source = get_in(settings, ["flow", "work_source"]) do
    if Map.has_key?(source, "grace"), do: raise("#{file}: flow.work_source.grace is not settable")

    timing =
      for key <- ~w(lease_ttl poll_max sweep_ms resync_ms),
          Map.has_key?(source, key) do
        value = source[key]

        if env != "test", do: raise("#{file}: flow.work_source.#{key} is for env test only")

        if not is_integer(value) or value < 1 or (key == "poll_max" and value > 25),
          do: raise("#{file}: flow.work_source.#{key} is #{inspect(value)}")

        {String.to_atom(key), value}
      end

    config :atlas_flow,
           :work_source,
           [
             port: source["port"],
             credentials_env:
               source["credentials_env"] ||
                 raise("#{file} has no flow.work_source.credentials_env")
           ] ++ timing
  end

  # Code's receiver of Flow's integrate and publish effects (AtlasCode.Effects), with its
  # journal in `code.data`, the repositories it may integrate and publish to
  # (`code.repositories`, owner/repo) and GitHub reached with the GitHub connector's
  # settings: no secret of its own. A publication reads the issue's result from the core's
  # Code service (`code.home`). Flow runs these effects only through a receiver it is told
  # of, so both come from this one block; without it every subflow with such an effect is
  # refused, and Flow runs none.
  if code = settings["code"] do
    config :atlas_code,
      effects: %{
        "dir" => expand.(code["data"] || raise("#{file} has no code.data")),
        "repositories" => code["repositories"] || raise("#{file} has no code.repositories"),
        "merge_method" => code["merge_method"] || "merge",
        "github" =>
          {AtlasCode.Effects.GitHub,
           Map.take(get_in(settings, ["connectors", "github"]) || %{}, [
             "api",
             "token_env",
             "token_command"
           ])}
      }

    config :atlas_flow,
      effect_receivers: %{
        "code" => %{
          "contract" => 1,
          "address" => "code/effects",
          "operations" => ["integrate", "publish"]
        }
      }

    # The Code service in the core (AtlasCode.Core): a registered Code on its own home
    # (`code.home`, not `code.data`'s effects journal) that reads the repositories Flow's work
    # source takes bases from (`code.sources`: name → remote, as in a Code home's config.json,
    # e.g. {"url": …, "credentials": "none"} for an anonymous read). It serves only that work
    # source, so it starts only when `flow.work_source` is configured too. Without either,
    # nothing starts and nothing is written: the core has no Code service. A `code.home`
    # waiting for its work source is still checked, so turning the source on is one key.
    if home = code["home"] do
      sources = code["sources"]

      unless is_map(sources) and map_size(sources) > 0,
        do: raise("#{file} has code.home but no code.sources")

      if source = get_in(settings, ["flow", "work_source"]) do
        config(:atlas_code, service: %{"home" => expand.(home), "repositories" => sources})

        # Code's Git endpoint (AtlasCode.Git): Runtimes fetch their bases from Code over Git,
        # on 127.0.0.1 at `code.git_port` behind the tailnet edge, with their work source token.
        # A Runtime installed through Control is admitted by the credential registered on
        # its machinery fact too (AtlasFlow.WorkSource.Registered, IS-Atlas-116).
        if port = code["git_port"],
          do:
            config(:atlas_code,
              git: %{
                "port" => port,
                "credentials_env" => source["credentials_env"],
                "registered" => {AtlasFlow.WorkSource.Registered, :digests}
              }
            )
      end
    end
  end

  # Who fills each role the model's owners name (`"actors": {"decider": "<key>"}`): the
  # model names roles, never people. Flow and Control refuse to start without one
  # (AtlasBus.Actors); an actor whose fact does not exist yet only makes its owner wait.
  config :atlas, actors: settings["actors"]

  # Whom each agent assists (`"assists": {"<agent key>": "<person key>"}`): an agent picks
  # a flow up on that person's behalf, who becomes its supervisor (IS-Atlas-47). None by
  # default: an agent then picks nothing up.
  config :atlas, assists: settings["assists"] || %{}

  # A private instance may run another composition of the model (a profile, e2e).
  if model = settings["model"], do: config(:atlas, model: Module.concat([model]))

  # This machine's Runtime settings (AtlasRuntime.Settings); without `runtime`, the defaults.
  config :atlas_runtime, settings: settings["runtime"] || %{}
end
