defmodule AtlasE2E.MixProject do
  use Mix.Project

  # The end-to-end test: a private rela, the core and two real TUIs in tmux, driven with
  # keys and read from their screens. Not part of the BEAM platform or of any client; it
  # follows the guides in docs/guides, so its scenarios name what the screens show.
  def project do
    [
      app: :atlas_e2e,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: false,
      # Facts' CA store (AtlasFacts.Trust), the one place every :httpc user loads it from.
      elixirc_paths: [
        "lib",
        Path.expand("../beam/apps/atlas_facts/lib/atlas_facts/trust", __DIR__)
      ],
      deps: []
    ]
  end

  def application, do: [extra_applications: [:logger, :inets, :ssl, :public_key]]
end
