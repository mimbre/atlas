defmodule AtlasRuntime.Settings do
  @moduledoc """
  What this machine's Runtime runs, from the environment's settings (`runtime` in
  `env/<env>.json`): `machine` (its name), `agents` (`%{key => %{"port" => port}}`: the
  agents it runs, each through a port, `AtlasRuntime.Agent`), and its numbers (architecture
  v4, section 10.4): `silence_seconds` (a turn without activity this long ends, 600),
  `max_seconds` (the longest a turn runs, 7200), `lease_seconds` (how often a turn's lease
  is renewed while there is activity, 60) and `round_seconds` (how often it reconciles the
  turns with Facts, 60, and at once on a hint). An agent's own `silence_seconds` and
  `max_seconds` win over the machine's, and so does its `leave_grace_seconds` (10): how long
  a turn whose item left its agent may still end by itself, so its result is kept, before
  it is stopped (IS-Atlas-93). `crash_pause_seconds` (10) is the first pause after
  a crash, doubling with each crash in a row; `turns_dir` holds a folder per turn (the
  `claude` port's working folder). No `runtime`: no agents, nothing runs.
  """

  @doc "The engine's options."
  def get do
    settings = Application.get_env(:atlas_runtime, :settings) || %{}

    [
      machine: settings["machine"] || "this machine",
      agents: settings["agents"] || %{},
      silence: seconds(settings["silence_seconds"], 600),
      max: seconds(settings["max_seconds"], 7200),
      leave_grace: seconds(settings["leave_grace_seconds"], 10),
      lease: seconds(settings["lease_seconds"], 60),
      every: seconds(settings["round_seconds"], 60),
      stub_dir: settings["stub_dir"],
      turns_dir: settings["turns_dir"] || Path.join(System.tmp_dir!(), "atlas-turns"),
      crash_pause: seconds(settings["crash_pause_seconds"], 10),
      env_file: System.get_env("ATLAS_CLIENT_ENV_FILE") || System.get_env("ATLAS_ENV_FILE"),
      atlas_bin: System.get_env("ATLAS_ROOT") && Path.join(System.get_env("ATLAS_ROOT"), "bin")
    ]
  end

  defp seconds(nil, default), do: default * 1000
  defp seconds(n, _default) when is_number(n), do: round(n * 1000)
end
