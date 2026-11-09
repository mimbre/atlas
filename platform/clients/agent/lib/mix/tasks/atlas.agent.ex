defmodule Mix.Tasks.Atlas.Agent do
  @shortdoc "Create and read through Control: mix atlas.agent put|get|list --env test ..."
  @moduledoc "See `AtlasAgent.CLI`. Also `bin/atlas put|get|list`."
  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("compile")
    status = AtlasAgent.CLI.main(args)
    if status != 0, do: exit({:shutdown, status})
  end
end
