defmodule AtlasAgent.MixProject do
  use Mix.Project

  # A client of Control for agents and scripts (`atlas put`, `atlas get`, `atlas list`), not
  # part of the BEAM platform. Like the TUI it speaks Control's protocol and knows only
  # pages and blocks; which kinds exist, what a form asks and where a fact belongs come
  # from Control, which reads them from rela's description. It names no entity. It knows
  # Control's contract (bff/contract) for the version it says it implements in hello.
  def project do
    [
      app: :atlas_agent,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: false,
      deps: [
        {:atlas_transport, path: "../../transport"},
        {:atlas_bff_contract, path: "../../bff/contract"}
      ]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
