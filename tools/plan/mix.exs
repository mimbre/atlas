defmodule AtlasPlan.MixProject do
  use Mix.Project

  # The one-off `atlas migrate-done-owner` (IS-Atlas-88): reads rela and writes through
  # Control with the agent client (clients/agent). Not part of the BEAM platform or of any
  # client.
  def project do
    [
      app: :atlas_plan,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: false,
      # Facts' CA store (AtlasFacts.Trust): :httpc needs one even for http.
      elixirc_paths: [
        "lib",
        Path.expand("../../beam/apps/atlas_facts/lib/atlas_facts/trust", __DIR__)
      ],
      deps: [{:atlas_agent, path: "../../clients/agent"}]
    ]
  end

  def application, do: [extra_applications: [:logger, :inets, :ssl]]
end
