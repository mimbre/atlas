defmodule AtlasChangeset.MixProject do
  use Mix.Project

  # The neutral change-set library (D42): the shape of a change set, its canonical form and
  # its `csf_` fingerprint, with the fixture that pins them. It is owned by no system and
  # holds none of their vocabulary; it has no dependencies and starts no process.
  def project do
    [
      app: :atlas_changeset,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: false,
      deps: []
    ]
  end

  def application, do: [extra_applications: [:crypto]]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
