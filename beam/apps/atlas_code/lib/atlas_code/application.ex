defmodule AtlasCode.Application do
  @moduledoc """
  Starts Code's effect receiver (`AtlasCode.Effects.Endpoint`) on a node that configures
  one (`config :atlas_code, :effects`, the core's `runtime.exs`), and nothing otherwise:
  the local Code service (`mix atlas_code.server`, the `atlas_code` release) has no such
  configuration and starts only through `AtlasCode.Server`.
  """
  use Application

  @impl true
  def start(_type, _args) do
    children =
      case Application.get_env(:atlas_code, :effects) do
        nil -> []
        settings -> [{AtlasCode.Effects.Endpoint, settings}]
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: AtlasCode.Supervisor)
  end
end
