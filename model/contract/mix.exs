defmodule Model.MixProject do
  use Mix.Project

  # Atlas's flows: the subflows, one file per subject, and the gates they name.
  # Only declarations live here; the DSL and its checks belong to model/dsl.
  def project do
    [
      app: :model,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: false,
      deps: [{:rela_dsl, path: "../dsl"}]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
