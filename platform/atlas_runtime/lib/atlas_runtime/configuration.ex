defmodule AtlasRuntime.Configuration do
  @moduledoc """
  The Runtime's configuration as its supervisor sets it through Control (IS-Atlas-27): the
  whole `policy.json` document, kept on the Runtime's machinery fact and served by the
  work source in a poll answer (`work_source` `polled.configuration`). The puller of that
  source hands it here; `apply/3` checks it and writes it, or refuses it with a reason the
  puller reports on its next poll (`poll_input.configuration_refused`). A refused document
  changes nothing: the Runtime keeps the policy it had.

  A document is applied when:

  1. it is a valid policy (`AtlasRuntime.Policy.check/1`, the rules `load/1` applies);
  2. its `version` is above the version in force (the same one is already applied, and
     answers `:current`);
  3. it keeps the source it came from as it is (name, kind, `url`, `credential_file`,
     `ca_file`): that is the link the next configuration comes over;
  4. it names the same sources with the same links (name, kind, `url`,
     `credential_file`, `ca_file`) as the policy in force: each puller opens its link once,
     at boot, so a source added, removed or moved would only apply at a restart. Its
     `priority`, `max_slots`, `max_store_bytes` and `git_url` may change; they are read
     again at every offer and import.

  Then `policy.json` is written whole (`AtlasRuntime.Policy.write/2`). Everything the
  executor reads from it (profiles, options, slots, buffer, source priorities and caps) is
  read again at every resolution, offer and slot pick, so the new version applies to every
  attempt that has not started, without a restart. An attempt already started keeps the
  selection it started with. `atlas-runtime preferences` and `service status` show the
  new version, and the next poll carries it as `policy_version`.
  """

  require Logger

  alias AtlasRuntime.Policy

  # What makes a source's link: a puller opens it with these, once.
  @link ~w(name kind url credential_file ca_file)

  @type outcome ::
          {:applied, pos_integer()} | :current | {:refused, non_neg_integer(), String.t()}

  @doc """
  Applies `document`, served by source `source` (its name), to the Runtime home `home`.
  `{:applied, version}`, `:current` (that version is in force), or `{:refused, version,
  reason}`: `version` the document's own (0 when it has none), `reason` a short text that
  names no path of this machine.
  """
  @spec apply(Path.t(), String.t(), binary()) :: outcome()
  def apply(home, source, document) when is_binary(home) and is_binary(document) do
    current = Policy.load(home)

    case Policy.check(document) do
      {:error, {:invalid, why}} ->
        refuse(source, version_of(document), "invalid: " <> why)

      {:ok, policy} ->
        version = policy["version"]
        in_force = Policy.version(current) || 0

        cond do
          version == in_force ->
            :current

          version < in_force ->
            refuse(
              source,
              version,
              "version #{version} is not above #{in_force}, the one in force"
            )

          link(Policy.sources({:ok, policy}), source) != link(Policy.sources(current), source) ->
            refuse(
              source,
              version,
              "it must keep source #{source}, the link it came over, as it is"
            )

          links(Policy.sources({:ok, policy})) != links(Policy.sources(current)) ->
            refuse(
              source,
              version,
              "adding, removing or moving a source (url, credential_file, ca_file) needs a " <>
                "Runtime restart, which a configuration does not do yet"
            )

          true ->
            write(home, source, version, document)
        end
    end
  end

  defp write(home, source, version, document) do
    case Policy.write(home, document) do
      :ok ->
        Logger.info("work source #{source}: configuration version #{version} applied")
        {:applied, version}

      {:error, reason} ->
        refuse(source, version, "policy.json could not be written (#{inspect(reason)})")
    end
  end

  defp refuse(source, version, reason) do
    Logger.warning("work source #{source}: configuration version #{version} refused: #{reason}")
    {:refused, version, reason}
  end

  defp link(sources, name), do: sources |> Enum.find(&(&1["name"] == name)) |> link()
  defp link(nil), do: nil
  defp link(source), do: Map.take(source, @link)

  defp links(sources), do: sources |> Enum.map(&link/1) |> Enum.sort_by(& &1["name"])

  # A refused document's version, when it has one that can be read.
  defp version_of(document) do
    case JSON.decode(document) do
      {:ok, %{"version" => version}} when is_integer(version) and version > 0 -> version
      _ -> 0
    end
  end
end
