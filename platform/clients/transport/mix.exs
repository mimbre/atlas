defmodule AtlasControlTransport.MixProject do
  use Mix.Project

  def project do
    [app: :atlas_control_transport, version: "0.1.0", elixir: "~> 1.18", deps: []]
  end

  def application, do: [extra_applications: [:ssl, :public_key]]
end
