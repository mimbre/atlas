defmodule Mix.Tasks.Atlas.MigrateDoneOwner do
  @shortdoc "IS-Atlas-88: a done fact has no owner; removes the one a migration gave it"
  @moduledoc """
      atlas migrate-done-owner --env <env> [--dry-run]

  (or `mix atlas.migrate_done_owner ...` in tools/plan). See `AtlasPlan.DoneOwner`. Run it with
  `--dry-run` first: it prints the steps and writes nothing. It reads rela's description
  and facts, and writes through Control, as the migration.
  """
  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("compile")
    {:ok, _} = Application.ensure_all_started([:inets, :ssl])
    _ = AtlasFacts.Trust.load()
    {opts, _rest, invalid} = OptionParser.parse(args, strict: [env: :string, dry_run: :boolean])
    env = opts[:env] || "prod"

    status =
      with [] <- invalid,
           {:ok, settings} <- AtlasAgent.settings(env),
           {:ok, client} <- AtlasAgent.connect(env, "migration"),
           {:ok, _} <-
             AtlasPlan.DoneOwner.run(client, settings["rela"]["url"],
               dry_run: opts[:dry_run] || false
             ) do
        0
      else
        {:error, text} when is_binary(text) -> fail(text)
        {:error, other} -> fail(inspect(other))
        _ -> fail(@moduledoc |> String.split("\n") |> Enum.at(0) |> String.trim())
      end

    if status != 0, do: exit({:shutdown, status})
  end

  defp fail(text) do
    IO.puts(:stderr, "atlas migrate-done-owner: " <> text)
    1
  end
end
