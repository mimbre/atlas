defmodule Mix.Tasks.AtlasCode.PrBody do
  @shortdoc "Rewrites a pull's description so merging it closes nothing"
  @moduledoc """
  Rewrites the pull's description in FILE in place with every GitHub closing reference
  defused (`AtlasCode.ClosingKeywords.defuse/1`), so merging the pull closes nothing else on
  GitHub (IS-Atlas-136):

      (cd platform/atlas_code && mix atlas_code.pr_body /absolute/body.md)
      gh pr create --body-file /absolute/body.md ...

  Run it on every body an agent hands to `gh pr create` or `gh pr edit` (`--body-file`, never
  `--body`). It prints how many references it defused.
  """
  use Mix.Task

  @impl true
  def run([file]) do
    Mix.Task.run("compile")
    text = File.read!(file)
    count = AtlasCode.ClosingKeywords.count(text)
    File.write!(file, AtlasCode.ClosingKeywords.defuse(text))
    Mix.shell().info("#{file}: #{count} closing reference(s) defused")
  end

  def run(_), do: Mix.raise("Use mix atlas_code.pr_body FILE")
end
