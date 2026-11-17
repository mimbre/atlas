defmodule AtlasTestAwait.MixProject do
  use Mix.Project

  # The neutral test helper every app's tests wait with: on an event, a record or a `DOWN`,
  # never on the clock (README.md). Owned by no system and naming none; no dependencies.
  # Apps take it for their tests only: `{:atlas_test_await, path: "../frameworks/test_await",
  # only: :test}`.
  def project do
    [
      app: :atlas_test_await,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: false,
      deps: []
    ]
  end

  def application, do: [extra_applications: [:ex_unit]]
end
