defmodule AtlasBodyLimit.MixProject do
  use Mix.Project

  # The shared request-body limit (M3 A3 fix): read a Plug request body against a byte cap
  # whatever its transfer encoding, so that a `Transfer-Encoding: chunked` body cannot get
  # past it. It is owned by no system and names none; a backend depends on it by path.
  # Plug and Bandit come from the umbrella's lockfile (products/software_factory/mix.lock),
  # whose versions this library is written and tested against (Bandit 1.10.1).
  def project do
    [
      app: :atlas_body_limit,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps_path: "../../../products/software_factory/deps",
      lockfile: "../../../products/software_factory/mix.lock",
      start_permanent: false,
      deps: [{:plug, "~> 1.19"}, {:bandit, "~> 1.10"}]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
