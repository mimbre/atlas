defmodule AtlasRuntime.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    engine =
      if Application.get_env(:atlas_runtime, :start, true) and
           Keyword.get(AtlasRuntime.Settings.get(), :agents) != %{},
         do: [{AtlasRuntime.Engine, AtlasRuntime.Settings.get() ++ [name: AtlasRuntime.Engine]}],
         else: []

    # One process per running turn, under its own supervisor: a turn whose process dies is
    # ended by the engine's next round (it reads the turn as running, with no process).
    children =
      [{Registry, keys: :unique, name: AtlasRuntime.Turns}, AtlasRuntime.Output, local_output()] ++
        output_endpoint(
          Application.get_env(:atlas_runtime, :server_lifecycle, false),
          AtlasRuntime.Settings.get()
        ) ++
        [{DynamicSupervisor, name: AtlasRuntime.Supervisor, strategy: :one_for_one}] ++ engine

    Supervisor.start_link(children, strategy: :one_for_one, name: AtlasRuntime.Root)
  end

  # Standalone turns' public output, read only through read.sock; the Bus endpoint below
  # serves Output alone, so it is never forwarded to Server.
  defp local_output,
    do:
      Supervisor.child_spec({AtlasRuntime.Output, name: AtlasRuntime.LocalOutput},
        id: AtlasRuntime.LocalOutput
      )

  # Standalone lifecycle reporting (`:server_lifecycle`, its `server.json` machine) serves
  # output as that machine only, the one its Bus link authenticates; never this node's
  # default name. Anything else that is not a machine name registers no endpoint.
  defp output_endpoint(lifecycle, settings) do
    case lifecycle do
      reporting when reporting in [false, nil] ->
        [{AtlasRuntime.OutputEndpoint, machine: Keyword.fetch!(settings, :machine)}]

      machine when is_binary(machine) and machine != "" ->
        [{AtlasRuntime.OutputEndpoint, machine: machine}]

      _ ->
        []
    end
  end
end
