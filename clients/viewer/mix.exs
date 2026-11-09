defmodule AtlasViewer.MixProject do
  use Mix.Project

  def project do
    [
      app: :atlas_viewer,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: []
    ]
  end

  # OTP applications only: inets serves HTTP on 127.0.0.1, crypto makes and checks the
  # per-launch access token. No Runtime, Server or Code application is a dependency.
  def application, do: [extra_applications: [:logger, :inets, :crypto]]
end
