defmodule AtlasCredo.MixProject do
  use Mix.Project

  def project do
    [
      app: :atlas_credo,
      version: "0.1.0",
      elixir: "~> 1.17",
      deps: [{:credo, "1.7.14", runtime: false}]
    ]
  end
end
