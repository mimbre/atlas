defmodule AtlasControl.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    gateway =
      if Application.get_env(:atlas_control, :start, true) do
        [
          {AtlasControl.Gateway,
           host: Application.fetch_env!(:atlas_control, :host),
           port: Application.fetch_env!(:atlas_control, :port)}
        ]
      else
        []
      end

    children =
      [
        AtlasControl.Output,
        {DynamicSupervisor, name: AtlasControl.Sessions, strategy: :one_for_one}
      ] ++ gateway

    # Losing admission state must close its sessions before admitting replacement viewers.
    Supervisor.start_link(children, strategy: :rest_for_one, name: AtlasControl.Supervisor)
  end
end
