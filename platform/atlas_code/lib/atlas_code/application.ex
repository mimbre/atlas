defmodule AtlasCode.Application do
  @moduledoc """
  Starts what a node configures, and nothing otherwise:
  - Code's effect receiver (`AtlasCode.Effects.Endpoint`) with `config :atlas_code, :effects`;
  - the registered Code service of the core (`AtlasCode.Core`) with
    `config :atlas_code, :service`, which the core's `runtime.exs` sets only when its
    settings name a Code home and the repositories Flow's work source reads bases from.
  The local Code service (`mix atlas_code.server`, the `atlas_code` release) has neither
  configuration and starts only through `AtlasCode.Server`.
  """
  use Application

  @impl true
  def start(_type, _args) do
    children = children(Application.get_all_env(:atlas_code))
    Supervisor.start_link(children, strategy: :one_for_one, name: AtlasCode.Supervisor)
  end

  @doc false
  # The children for an application environment.
  def children(env) do
    for {key, child} <- [effects: AtlasCode.Effects.Endpoint, service: AtlasCode.Core],
        settings = env[key],
        do: {child, settings}
  end
end
