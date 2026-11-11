defmodule AtlasFacts.Application do
  @moduledoc false
  use Application

  # The connectors at Facts' edge, by their name under `connectors` in `env/<env>.json`.
  @sources %{"github" => AtlasFacts.Connector.GitHub}

  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:atlas_facts, :start, true) do
        data_dir = Application.fetch_env!(:atlas_facts, :data_dir)

        # A rela on a private IPv6 network (Fly): try IPv6 first, IPv4 next.
        if Application.get_env(:atlas_facts, :rela_ipv6),
          do: :ok = :httpc.set_options(ipfamily: :inet6fb4)

        [
          {AtlasFacts.Server,
           rela: {AtlasFacts.Rela.Http, Application.fetch_env!(:atlas_facts, :rela_url)},
           data_dir: data_dir,
           description_extra: Application.get_env(:atlas_facts, :description_extra)}
        ] ++ connectors(data_dir)
      else
        []
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: AtlasFacts.Supervisor)
  end

  # An environment without a connector's settings has no such connector: it does nothing
  # there (d-0003).
  defp connectors(data_dir) do
    for {system, settings} <- Application.get_env(:atlas_facts, :connectors, %{}),
        is_map(settings),
        source = @sources[system] do
      Supervisor.child_spec(
        {AtlasFacts.Connector,
         system: system,
         source: {source, settings},
         every: (settings["every_seconds"] || 300) * 1000,
         data_dir: data_dir},
        id: {AtlasFacts.Connector, system}
      )
    end
  end
end
