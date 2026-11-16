defmodule AtlasRuntime.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children =
      [AtlasRuntime.Output, local_output()] ++
        output_endpoint(
          Application.get_env(:atlas_runtime, :server_lifecycle, false),
          AtlasRuntime.Settings.get()
        ) ++ flow_passes()

    Supervisor.start_link(children, strategy: :one_for_one, name: AtlasRuntime.Root)
  end

  # Explicit opt-in: the directory must be the native Service's durable home.
  defp flow_passes do
    case Application.get_env(:atlas_runtime, :flow_passes) do
      nil -> []
      opts -> [{AtlasRuntime.FlowPasses, opts}]
    end
  end

  # Standalone turns' public output, read only through the work contract's turn output;
  # the Bus endpoint below serves Output alone, so it is never forwarded to Server.
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
