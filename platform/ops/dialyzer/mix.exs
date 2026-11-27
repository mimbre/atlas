defmodule AtlasDialyzer.MixProject do
  use Mix.Project

  def project do
    [app: :atlas_dialyzer, version: "0.1.0", elixir: "~> 1.18", deps: [{:dialyxir, "== 1.4.9", runtime: false}]]
  end
end
