defmodule AtlasCode.Migration do
  @moduledoc """
  Offline migration of a Code home from commits to revision handles, run by
  `mix atlas_code.migrate` while Code is stopped. It owns the home throughout, so it never
  runs beside a service, and it only adds files; no existing record is rewritten, moved or
  deleted:

  - `revisions/<handle>.json` for every commit an older record names;
  - `snapshots/<new hex>.json`, the version 2 manifest of each older snapshot, then
    `snapshots/<old hex>.successor` with its ID. A fresh snapshot of the same revisions gets
    the same ID;
  - `changes/<id>/request.json`, the request a client now sends for that change, and for a
    sealed change `changes/<id>/revision`;
  - `reviews/<publication id>.json` for every publication, in the same phase (`published`
    becomes `open`), keeping its branch as the review location. A publication without a pull
    request has no target, so it can never be integrated.

  Every file is published atomically, and an existing one must hold exactly the expected
  content (a review may only have advanced its phase since), so an interrupted run is repeated
  safely. `migration.json` says `running` from the first write until the last check.
  """

  @doc "Adds every missing counterpart and returns how many records of each kind it covered."
  def run(home) do
    home = Path.expand(home)
    unless File.dir?(home), do: raise("#{home} is not a directory")
    owner = AtlasCode.lock!(home, "migration")

    try do
      marker = Path.join(home, "migration.json")
      AtlasCode.write_atomic(marker, JSON.encode!(%{"state" => "running"}))
      counts = %{"snapshots" => snapshots(home), "changes" => changes(home), "reviews" => reviews(home)}

      case pending(home) do
        ["migration.json"] -> :ok
        pending -> raise "#{home} still lacks counterparts for #{Enum.join(pending, ", ")}"
      end

      AtlasCode.write_atomic(marker, JSON.encode!(Map.put(counts, "state", "complete")))
      counts
    after
      AtlasCode.release(home, owner)
    end
  end

  @doc """
  The home-relative records that keep Code from starting: an unfinished migration, and every
  older snapshot, change or publication without its counterpart.
  """
  def pending(home) do
    marker =
      case File.read(Path.join(home, "migration.json")) do
        {:ok, json} -> if JSON.decode!(json)["state"] == "complete", do: [], else: ["migration.json"]
        {:error, :enoent} -> []
      end

    snapshots =
      for hex <- listed(Path.join(home, "snapshots"), ~r/\A([0-9a-f]{64})\.json\z/),
          not current?(home, hex),
          not successor?(home, hex),
          do: "snapshots/#{hex}.json"

    changes =
      for id <- listed(Path.join(home, "changes"), ~r/\A([0-9a-f-]{36})\z/),
          change = Path.join([home, "changes", id]),
          File.exists?(Path.join(change, "change.json")),
          not File.exists?(Path.join(change, "request.json")) or
            (File.exists?(Path.join(change, "commit")) and not File.exists?(Path.join(change, "revision"))),
          do: "changes/#{id}"

    publications =
      for id <- listed(Path.join(home, "publications"), ~r/\A([0-9a-f-]{36})\.json\z/),
          not File.exists?(Path.join([home, "reviews", id <> ".json"])),
          do: "publications/#{id}.json"

    marker ++ snapshots ++ changes ++ publications
  end

  defp current?(home, hex),
    do: match?(%{"version" => 2}, home |> Path.join("snapshots/#{hex}.json") |> File.read!() |> JSON.decode!())

  defp successor?(home, hex) do
    case File.read(Path.join([home, "snapshots", hex <> ".successor"])) do
      {:ok, "sha256:" <> successor} -> File.exists?(Path.join([home, "snapshots", successor <> ".json"]))
      _ -> false
    end
  end

  # The older manifest must still hash to its ID and be canonical, so its successor's entries
  # are exactly the bytes Runtime verified.
  defp snapshots(home) do
    dir = Path.join(home, "snapshots")

    for hex <- listed(dir, ~r/\A([0-9a-f]{64})\.json\z/), reduce: 0 do
      count ->
        bytes = File.read!(Path.join(dir, hex <> ".json"))

        case JSON.decode!(bytes) do
          %{"version" => 2} ->
            count

          %{"entries" => entries, "repositories" => repositories} = manifest when map_size(manifest) == 2 ->
            unless AtlasCode.sha256(bytes) == hex and JSON.encode!(manifest) == bytes,
              do: raise("snapshots/#{hex}.json is not the canonical manifest of its ID")

            repositories =
              for %{"commit" => commit, "path" => path, "repository" => repository} = item <- repositories do
                unless map_size(item) == 3, do: raise("snapshots/#{hex}.json has an unknown repository shape")
                %{"path" => path, "repository" => repository, "revision" => AtlasCode.put_revision(home, repository, commit)}
              end

            manifest = JSON.encode!(%{"entries" => entries, "repositories" => repositories, "version" => 2})
            successor = AtlasCode.sha256(manifest)
            AtlasCode.publish!(Path.join(dir, successor <> ".json"), manifest)
            AtlasCode.publish!(Path.join(dir, hex <> ".successor"), "sha256:" <> successor)
            count + 1
        end
    end
  end

  defp changes(home) do
    dir = Path.join(home, "changes")

    for id <- listed(dir, ~r/\A([0-9a-f-]{36})\z/), File.exists?(Path.join([dir, id, "change.json"])), reduce: 0 do
      count ->
        change = Path.join(dir, id)

        %{"change_id" => ^id, "snapshot_id" => "sha256:" <> hex, "repository" => repository, "base_commit" => base} =
          old = change |> Path.join("change.json") |> File.read!() |> JSON.decode!()

        successor =
          case File.read(Path.join([home, "snapshots", hex <> ".successor"])) do
            {:ok, successor} -> successor
            {:error, :enoent} -> raise("changes/#{id} names sha256:#{hex}, which has no successor")
          end

        request = %{
          "base_revision" => AtlasCode.put_revision(home, repository, base),
          "change_id" => id,
          "entries" => old["entries"],
          "repository" => repository,
          "snapshot_id" => successor
        }

        AtlasCode.publish!(Path.join(change, "request.json"), JSON.encode!(request))

        case File.read(Path.join(change, "commit")) do
          {:ok, commit} ->
            AtlasCode.publish!(Path.join(change, "revision"), AtlasCode.put_revision(home, repository, commit))

          {:error, :enoent} ->
            :ok
        end

        count + 1
    end
  end

  @phases %{"pushing" => "pushing", "pushed" => "pushed", "published" => "open", "failed" => "failed"}

  defp reviews(home) do
    dir = Path.join(home, "publications")

    for id <- listed(dir, ~r/\A([0-9a-f-]{36})\.json\z/), reduce: 0 do
      count ->
        %{
          "request" => %{"publication_id" => ^id, "change_id" => change, "branch" => branch} = old,
          "phase" => phase,
          "repository" => repository,
          "commit" => commit
        } = publication = dir |> Path.join(id <> ".json") |> File.read!() |> JSON.decode!()

        pr = old["pull_request"] || %{}

        review = %{
          "request" => %{
            "review_id" => id,
            "change_id" => change,
            "target" => pr["base"],
            "title" => pr["title"],
            "body" => pr["body"]
          },
          "phase" => Map.fetch!(@phases, phase),
          "repository" => repository,
          "change_id" => change,
          "revision" => AtlasCode.put_revision(home, repository, commit),
          "location" => branch,
          "migrated_from" => "publications/#{id}.json"
        }

        review =
          case publication["pull_request"] do
            %{"url" => url} -> Map.put(review, "review_url", url)
            _ -> review
          end

        file = Path.join([home, "reviews", id <> ".json"])

        case File.read(file) do
          {:ok, json} ->
            stable = &Map.drop(&1, ["phase", "review_url"])

            unless stable.(JSON.decode!(json)) == stable.(review),
              do: raise("reviews/#{id}.json exists with other content")

          {:error, :enoent} ->
            File.mkdir_p!(Path.dirname(file))
            AtlasCode.write_atomic(file, JSON.encode!(review))
        end

        count + 1
    end
  end

  defp listed(dir, pattern) do
    case File.ls(dir) do
      {:ok, names} -> for name <- Enum.sort(names), [_, id] <- [Regex.run(pattern, name)], do: id
      {:error, :enoent} -> []
    end
  end
end
