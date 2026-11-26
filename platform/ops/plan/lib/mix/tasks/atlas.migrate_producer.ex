defmodule Mix.Tasks.Atlas.MigrateProducer do
  @shortdoc "UC-Atlas-23: every scene, use case and issue records its producer"
  @moduledoc """
      atlas migrate-producer --env <env> [--dry-run]

  (or `mix atlas.migrate_producer ...` in platform/ops/plan). See `AtlasPlan.Producer`. Run
  it with `--dry-run` first: it prints the steps and writes nothing. It reads Facts' items
  and their link history through Control, and writes through Control, as the migration.
  The environment's `core.json` (beside its settings) says whom each agent assists and
  who the configured decider is.
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
           {:ok, core} <- core(env),
           {:ok, client} <- AtlasAgent.connect(env, "migration"),
           {:ok, _} <-
             AtlasPlan.Producer.run(client,
               assists: core["assists"] || %{},
               decider: get_in(core, ["actors", "decider"]),
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

  # Whom agents assist and who decides, as the environment's core settings say.
  defp core(env) do
    file = Path.join(AtlasAgent.root(), "products/software_factory/environments/#{env}/core.json")

    with {:ok, json} <- File.read(file),
         {:ok, %{} = core} <- JSON.decode(json) do
      {:ok, core}
    else
      _ -> {:error, "no readable #{file}"}
    end
  end

  defp fail(text) do
    IO.puts(:stderr, "atlas migrate-producer: " <> text)
    1
  end
end
