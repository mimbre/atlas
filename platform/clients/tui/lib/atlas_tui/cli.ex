defmodule AtlasTui.CLI do
  @moduledoc """
  `mix atlas.tui --env test` (or `bin/atlas tui --env test` from the repository root).

  Connects to Control of one environment: prod by default, test with `--env test`.
  Console is the terminal client; failed negotiation never falls back.
  Settings come from `products/software_factory/environments/<env>.json` at the repository root, or from `ATLAS_ENV_FILE`
  (a private instance), whose `"env"` must be the same environment.

  Taking a release (IS-Atlas-76, D-0105). bin/atlas says how this build takes a newer
  one: `ATLAS_TUI_HANDOFF`, a file, when it can update it; `ATLAS_UPDATE_FAILED` (why)
  when it could not. Welcomed by a Control on a newer contract with a handoff file and no
  failure, the TUI writes three lines to that file (the page it showed, Control's
  contract, its own) and exits with 75 (`update_status/0`); bin/atlas takes the newest
  build and starts it again with `--to <page>`. Without, it stays and says so.
  """

  @root Path.expand("../../../../..", __DIR__)
  # EX_TEMPFAIL: Control is newer; bin/atlas updates the build and starts it again.
  @update 75

  def update_status, do: @update

  @doc "How this build takes a newer one, from what bin/atlas set (see the moduledoc)."
  def release(env \\ System.get_env()) do
    case {env["ATLAS_UPDATE_FAILED"], env["ATLAS_TUI_HANDOFF"]} do
      {why, _} when why not in [nil, ""] ->
        {:not_updated, why}

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
      {:update, page, theirs} ->
        File.write!(
          System.fetch_env!("ATLAS_TUI_HANDOFF"),
          handoff(page, theirs, AtlasTui.Protocol.version())
        )

        System.halt(@update)

      :ok ->
        :ok
    end
  end

  defp fail(text) do
    IO.puts(:stderr, text)
    System.halt(1)
  end
end
