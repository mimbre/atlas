defmodule Mix.Tasks.AtlasCode.Migrate do
  @shortdoc "Adds revision-handle counterparts to the records of a stopped Code home"
  @moduledoc """
  Migrates the Code home in this OS process while Code is stopped:

      cd beam/apps/atlas_code && ATLAS_CODE_HOME=/absolute/home mix atlas_code.migrate

  It takes the home's service lock, so it is refused while Code runs, adds the files described
  in `AtlasCode.Migration` and prints how many records it covered. Repeating it is safe.
  """
  use Mix.Task

  @impl true
  def run(_args) do
    home =
      System.get_env("ATLAS_CODE_HOME") ||
        Mix.raise("Set ATLAS_CODE_HOME to the Code home directory")

    # Not app.start: the umbrella's runtime.exs belongs to the core and Runtime nodes.
    Mix.Task.run("compile")
    {:ok, _} = Application.ensure_all_started(:atlas_code)
    IO.puts(JSON.encode!(AtlasCode.Migration.run(home)))
  end
end
