defmodule AtlasGates.Application do
  @moduledoc false
  use Application

  def start(_type, _args) do
    # The gates are the configured model's: without one, Gates does not start.
    children =
      if Application.get_env(:atlas_gates, :start, true) do
        AtlasGates.Model.configured!()
        [AtlasGates.Endpoint]
      else
        []
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: AtlasGates.Supervisor)
  end
end
