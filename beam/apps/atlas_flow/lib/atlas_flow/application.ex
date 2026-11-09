defmodule AtlasFlow.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    engine =
      if Application.get_env(:atlas_flow, :start, true) do
        every = Application.get_env(:atlas_flow, :tick_seconds, 60) * 1000

        # The model is wired by configuration (`config :atlas, model: …`); without one, or
        # with a module that is no model, Flow does not start.
        [
          {AtlasFlow.Engine,
           every: every, name: AtlasFlow.Engine, model: AtlasFlow.Model.configured!()}
        ]
      else
        []
      end

    # One process per open fact, each restarted by itself when it crashes.
    children =
      [
        AtlasFlow.Activities.Pass.Inbox,
        AtlasFlow.Activities.Effect.Inbox,
        {Registry, keys: :unique, name: AtlasFlow.Items},
        {DynamicSupervisor, name: AtlasFlow.Supervisor, strategy: :one_for_one}
      ] ++ engine

    Supervisor.start_link(children, strategy: :one_for_one, name: AtlasFlow.Root)
  end
end
