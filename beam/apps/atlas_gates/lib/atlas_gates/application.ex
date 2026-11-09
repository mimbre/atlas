defmodule AtlasGates.Application do
  @moduledoc false
  use Application

  def start(_type, _args) do
    children =
      if Application.get_env(:atlas_gates, :start, true), do: [AtlasGates.Endpoint], else: []

    Supervisor.start_link(children, strategy: :one_for_one, name: AtlasGates.Supervisor)
  end
end
