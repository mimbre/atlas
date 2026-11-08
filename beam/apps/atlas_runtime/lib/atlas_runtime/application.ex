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
    # Standalone lifecycle-only reporting serves no output over its Bus link (not yet).
    output_endpoint =
      if Application.get_env(:atlas_runtime, :server_lifecycle, false),
        do: [],
        else: [{AtlasRuntime.OutputEndpoint, machine: Keyword.fetch!(AtlasRuntime.Settings.get(), :machine)}]

    children =
      [{Registry, keys: :unique, name: AtlasRuntime.Turns}, AtlasRuntime.Output] ++
        output_endpoint ++
        [{DynamicSupervisor, name: AtlasRuntime.Supervisor, strategy: :one_for_one}] ++ engine

    Supervisor.start_link(children, strategy: :one_for_one, name: AtlasRuntime.Root)
  end
end
