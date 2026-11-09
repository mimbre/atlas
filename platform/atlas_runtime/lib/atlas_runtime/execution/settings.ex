defmodule AtlasRuntime.Settings do
  @moduledoc """
  This machine's Runtime settings, from the environment's settings (`runtime` in
  `products/software_factory/environments/<env>.json`): `machine` (its name, under which
  the output endpoint is addressed), and the numbers of the turn mirror
  (`AtlasRuntime.Integrations.AtlasServer.Lifecycle`): `lease_seconds` (how often a turn's
  lease is renewed while there is activity, 60) and `silence_seconds` (a turn without
  activity this long is no longer leased, 600).
  """

  @doc "The settings, as options."
  def get do
    settings = Application.get_env(:atlas_runtime, :settings) || %{}

    [
      machine: settings["machine"] || "this machine",
      silence: seconds(settings["silence_seconds"], 600),
      lease: seconds(settings["lease_seconds"], 60)
    ]
  end

  defp seconds(nil, default), do: default * 1000
  defp seconds(n, _default) when is_number(n), do: round(n * 1000)
end
