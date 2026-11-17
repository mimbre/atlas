# Loads the Runtime service's build and configuration without Mix, before host/service.exs
# runs in the same VM (host/main.go, serviceCommands):
#
#   elixir -pz "$MIX_BUILD_PATH/lib/*/ebin" -pa "$MIX_BUILD_PATH/consolidated" \
#     -r host/boot.exs host/service.exs HOME
#
# run in the umbrella project (products/software_factory) after the host's build step
# (`mix do deps.get + compile`), with the same MIX_ENV and MIX_BUILD_PATH. `mix run` is not
# used for the long-running VM: Mix (Elixir >= 1.18) starts Mix.Sync.PubSub there, a
# loopback TCP listener that decodes what it receives with binary_to_term, and an agent
# machine runs no network listener (the pull design). What this file does is what `mix run
# --no-start --no-compile --no-deps-check` did before the script ran, and only that.
build = System.fetch_env!("MIX_BUILD_PATH")
env = String.to_atom(System.fetch_env!("MIX_ENV"))
target = String.to_atom(System.get_env("MIX_TARGET", "host"))

# The consolidated protocols take the place of those this VM loaded while it booted
# (Mix.Tasks.Compile, consolidation path). The -pa above put their directory first.
with {:ok, files} <- File.ls(Path.join(build, "consolidated")) do
  for file <- files, String.starts_with?(file, "Elixir.") do
    module = file |> Path.rootname() |> String.to_atom()
    :code.purge(module)
    :code.delete(module)
  end
end

# The project's configuration, as Mix loads it: config/config.exs with its imports when the
# project loads, persistent; then config/runtime.exs, without imports, deep merged into what
# the loaded applications hold (Mix.Tasks.Loadconfig).
config = Path.expand("config/config.exs")

if File.regular?(config) do
  {values, _files} = Config.Reader.read_imports!(config, env: env, target: target)
  Application.put_all_env(values, persistent: true)
end

# Every application the build holds is loaded, with the applications they declare, as Mix
# loads the project's and its deps' applications; none is started (`--no-start`):
# service.exs starts the Runtime.
load = fn load, app ->
  case Application.load(app) do
    :ok -> :ok
    {:error, {:already_loaded, ^app}} -> :ok
    {:error, reason} -> raise("Runtime boot: #{app} not loaded: #{inspect(reason)}")
  end

  # An optional application that is not installed is left out, as at start.
  optional = Application.spec(app, :optional_applications) || []

  for key <- [:applications, :included_applications],
      dep <- Application.spec(app, key) || [],
      not List.keymember?(Application.loaded_applications(), dep, 0),
      dep not in optional or :code.lib_dir(dep) != {:error, :bad_name},
      do: load.(load, dep)
end

for app_file <- Path.wildcard(Path.join(build, "lib/*/ebin/*.app")),
    do: load.(load, app_file |> Path.basename(".app") |> String.to_atom())

runtime = Path.expand("config/runtime.exs")

if File.regular?(runtime) do
  values = Config.Reader.read!(runtime, env: env, target: target, imports: :disabled)

  values =
    for {app, pairs} <- values,
        do: hd(Config.Reader.merge([{app, Application.get_all_env(app)}], [{app, pairs}]))

  Application.put_all_env(values, persistent: true)
end
