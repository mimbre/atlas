defmodule AtlasTui.CLI do
  @moduledoc """
  `mix atlas.tui --env test` (or `bin/atlas tui --env test` from the repository root).

  Connects to Control of one environment: prod by default, test with `--env test`.
  Console is the terminal client; failed negotiation never falls back.
  Settings come from `env/<env>.json` at the repository root, or from `ATLAS_ENV_FILE`
  (a private instance), whose `"env"` must be the same environment.
  """

  @root Path.expand("../../../..", __DIR__)

  def main(args) do
    {opts, _rest, invalid} = OptionParser.parse(args, strict: [env: :string])

    env = opts[:env] || "prod"

    cond do
      invalid != [] ->
        fail("Unknown option(s): #{Enum.map_join(invalid, " ", &elem(&1, 0))}. Use --env test.")

      env not in ["test", "prod"] ->
        fail("Atlas has no environment #{inspect(env)}. Use --env test or --env prod.")

      true ->
        root = System.get_env("ATLAS_ROOT") || @root
        file = System.get_env("ATLAS_ENV_FILE") || Path.join(root, "env/#{env}.json")

        case File.read(file) do
          {:ok, json} ->
            settings = JSON.decode!(json)

            if settings["env"] == env,
              do: AtlasTui.App.run(env, settings),
              else: fail("#{file} is for #{inspect(settings["env"])}, not #{env}.")

          {:error, _} ->
            fail("Atlas has no environment #{inspect(env)} (no #{file}).")
        end
    end
  end

  defp fail(text) do
    IO.puts(:stderr, text)
    System.halt(1)
  end
end
