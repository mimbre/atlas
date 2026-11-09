defmodule AtlasFlow.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    engine =
      if Application.get_env(:atlas_flow, :start, true) do
        every = Application.get_env(:atlas_flow, :tick_seconds, 60) * 1000

        [
          {AtlasFlow.Engine,
           every: every,
           name: AtlasFlow.Engine,
           deployed_yaml: Application.get_env(:atlas_flow, :deployed_yaml)}
        ]
      else
        []
      end

    # One process per open fact, each restarted by itself when it crashes.
    children =
      [
        AtlasFlow.Activities.Pass.Inbox,
        {Registry, keys: :unique, name: AtlasFlow.Items},
        {DynamicSupervisor, name: AtlasFlow.Supervisor, strategy: :one_for_one}
      ] ++ engine

    Supervisor.start_link(children, strategy: :one_for_one, name: AtlasFlow.Root)
  end
end
