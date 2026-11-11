defmodule AtlasBus.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: AtlasBus.Endpoints},
      {Registry, keys: :duplicate, name: AtlasBus.Listeners},
      AtlasBus.Router
    ]

    link =
      case AtlasBus.Link.settings() do
        %{"mode" => "server"} = settings -> [{AtlasBus.Link.Server, settings}]
        %{"mode" => "client"} -> [AtlasBus.Link.Client]
        _ -> []
      end

    Supervisor.start_link(children ++ link, strategy: :rest_for_one, name: AtlasBus.Supervisor)
  end
end
