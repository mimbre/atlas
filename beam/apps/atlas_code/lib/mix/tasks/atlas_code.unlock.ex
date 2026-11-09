defmodule Mix.Tasks.AtlasCode.Unlock do
  @shortdoc "Recovers a Code home from an owner that stopped without releasing it"
  @moduledoc """
  Recovers the home whose owner, a Code service or migration, ended by a crash, SIGKILL or
  Ctrl-C and so never released it:

      cd beam/apps/atlas_code && ATLAS_CODE_HOME=/absolute/home mix atlas_code.unlock --owner OWNER

  OWNER is the ID a refused start or migration prints. The owner directory moves to its
  `service.owner.ended-OWNER` tombstone only when it still names OWNER and `ps` reports its
  PID absent; a running or undeterminable PID refuses and moves nothing.
  """
  use Mix.Task

  @impl true
  def run(args) do
    home = System.get_env("ATLAS_CODE_HOME") || Mix.raise("Set ATLAS_CODE_HOME to the Code home directory")

    owner =
      case OptionParser.parse(args, strict: [owner: :string]) do
        {[owner: owner], [], []} -> owner
        _ -> Mix.raise("Use mix atlas_code.unlock --owner OWNER")
      end

    Mix.Task.run("compile")

    case AtlasCode.unlock(home, owner) do
      {:ok, :not_owned} -> IO.puts(JSON.encode!(%{"state" => "not_owned"}))
      {:ok, {:recovered, tombstone}} -> IO.puts(JSON.encode!(%{"state" => "recovered", "tombstone" => tombstone}))
      {:error, why} when is_binary(why) -> Mix.raise(why)
      {:error, reason} -> Mix.raise("The owner directory could not be moved (#{reason}); nothing was moved")
    end
  end
end
