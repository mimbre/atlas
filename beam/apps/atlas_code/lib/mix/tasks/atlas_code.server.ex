defmodule Mix.Tasks.AtlasCode.Server do
  @shortdoc "Runs the local Code service from $ATLAS_CODE_HOME"
  @moduledoc """
  Runs the local Code service in this OS process until it is stopped:

      cd beam/apps/atlas_code && ATLAS_CODE_HOME=/absolute/home mix atlas_code.server

  It starts no other Atlas layer. See `AtlasCode` for the home's files.
  """
  use Mix.Task

  @impl true
  def run(_args) do
    home = System.get_env("ATLAS_CODE_HOME") || Mix.raise("Set ATLAS_CODE_HOME to the Code home directory")
    # Not app.start: the umbrella's runtime.exs belongs to the core and Runtime nodes.
    Mix.Task.run("compile")
    {:ok, _} = Application.ensure_all_started(:atlas_code)
    {:ok, _pid, port} = AtlasCode.start(home)
    IO.puts("Code ready on 127.0.0.1:#{port}")
    Process.sleep(:infinity)
  end
end
