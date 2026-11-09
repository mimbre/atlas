defmodule Mix.Tasks.AtlasCode.Server do
  @shortdoc "Runs the local Code service from $ATLAS_CODE_HOME"
  @moduledoc """
  Runs the local Code service in this OS process until it is stopped:

      cd beam/apps/atlas_code && ATLAS_CODE_HOME=/absolute/home mix atlas_code.server

  It starts no other Atlas layer. See `AtlasCode` for the home's files. Stop it with SIGTERM
  (`kill PID`), which releases the home. After Ctrl-C, a crash or SIGKILL the next start
  recovers the home itself once `ps` shows the old PID gone, so a supervisor such as launchd
  can restart it; only when that cannot be shown run `mix atlas_code.unlock`. For a faster
  restart under a supervisor run the `atlas_code` release instead (see `AtlasCode.Server`).
  """
  use Mix.Task

  @impl true
  def run(_args) do
    home =
      System.get_env("ATLAS_CODE_HOME") ||
        Mix.raise("Set ATLAS_CODE_HOME to the Code home directory")

    # Not app.start: the umbrella's runtime.exs belongs to the core and Runtime nodes.
    Mix.Task.run("compile")
    {:ok, _pid, _port} = AtlasCode.Server.serve(home)
    Process.sleep(:infinity)
  end
end
