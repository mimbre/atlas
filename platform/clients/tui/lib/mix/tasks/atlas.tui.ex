defmodule Mix.Tasks.Atlas.Tui do
  @shortdoc "Start the Atlas TUI: mix atlas.tui --env test"
  @moduledoc "Starts the TUI. See `AtlasTui.CLI`."
  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("compile")
    AtlasTui.CLI.main(args)
  end
end
