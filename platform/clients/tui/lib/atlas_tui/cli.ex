defmodule AtlasTui.CLI do
  @moduledoc """
  `mix atlas.tui --env test` (or `bin/atlas tui --env test` from the repository root).

  Connects to Control of one environment: prod by default, test with `--env test`.
  Console is the terminal client; failed negotiation never falls back.
  Settings come from `products/software_factory/environments/<env>.json` at the repository root, or from `ATLAS_ENV_FILE`
  (a private instance), whose `"env"` must be the same environment.

  Taking a release (IS-Atlas-76). bin/atlas says how this build takes a newer one:
  `ATLAS_TUI_HANDOFF`, a file, when it can update it; `ATLAS_UPDATE_FAILED` (why) and
  `ATLAS_UPDATE_ONCE` (until when) when it could not. Closed by Control as too old with a
  handoff file and no failure, the TUI writes three lines to that file (the page it
  showed, Control's contract, its own) and exits with 75 (`too_old_status/0`); bin/atlas
  takes the newest build and starts it again with `--to <page>`.
  """

  @root Path.expand("../../../../..", __DIR__)
  # EX_TEMPFAIL: closed as too old; bin/atlas updates the build and starts it again.
  @too_old 75

  def too_old_status, do: @too_old

  @doc "How this build takes a newer one, from what bin/atlas set (see the moduledoc)."
  def release(env \\ System.get_env()) do
    case {env["ATLAS_UPDATE_FAILED"], env["ATLAS_TUI_HANDOFF"]} do
      {why, _} when why not in [nil, ""] ->
        {:not_updated, why, env["ATLAS_UPDATE_ONCE"] || "it can be updated"}

      {_, file} when file not in [nil, ""] ->
        :restart

      _ ->
        nil
    end
  end

  @doc "The handoff's three lines: the page shown (empty for none), Control's contract, this one."
  def handoff(page, theirs, ours), do: Enum.map_join([page || "", theirs, ours], &(&1 <> "\n"))

  def main(args) do
    {opts, _rest, invalid} = OptionParser.parse(args, strict: [env: :string, to: :string])

    env = opts[:env] || "prod"

    cond do
      invalid != [] ->
        fail("Unknown option(s): #{Enum.map_join(invalid, " ", &elem(&1, 0))}. Use --env test.")

      env not in ["test", "prod"] ->
        fail("Atlas has no environment #{inspect(env)}. Use --env test or --env prod.")

      true ->
        root = System.get_env("ATLAS_ROOT") || @root

        file =
          System.get_env("ATLAS_ENV_FILE") ||
            Path.join(root, "products/software_factory/environments/#{env}.json")

        case File.read(file) do
          {:ok, json} ->
            settings = JSON.decode!(json)

            if settings["env"] == env,
              do: run(env, settings, opts[:to]),
              else: fail("#{file} is for #{inspect(settings["env"])}, not #{env}.")

          {:error, _} ->
            fail("Atlas has no environment #{inspect(env)} (no #{file}).")
        end
    end
  end

  defp run(env, settings, to) do
    case AtlasTui.App.run(env, settings, release: release(), to: to) do
      {:too_old, page, theirs} ->
        File.write!(
          System.fetch_env!("ATLAS_TUI_HANDOFF"),
          handoff(page, theirs, AtlasTui.Protocol.version())
        )

        System.halt(@too_old)

      :ok ->
        :ok
    end
  end

  defp fail(text) do
    IO.puts(:stderr, text)
    System.halt(1)
  end
end
