defmodule AtlasCode.Service do
  @moduledoc """
  Code's behaviour, as public functions of a started Code's settings: what each HTTP route
  of `AtlasCode` did in its body, moved here unchanged. A function takes the settings of the
  Code instance it acts for and the request as decoded JSON (any term: what does not match
  the request's shape is refused as before), and answers `{status, body}` (or a tar
  stream, for an archive), exactly as the route answered.

  The settings are those `AtlasCode.start/2` serves (the home, the allowed repositories,
  the token digests, `gh`; `:role` added per request by the HTTP routes). Who may call is
  not decided here: the HTTP routes check the bearer token and the reviewing role before
  they call, and the boundary facade (`AtlasCode.Boundary`, implemented by
  `AtlasCode.Running`) checks its caller's right. Every function the contract
  (`AtlasCodeBoundary.Code`) declares is reached through that facade: `resolve_reference/2`,
  `create_snapshot/2`, `get_manifest/2`, the changes (`create_change/2`,
  `put_change_blob/4`, `seal_change/2`) and the reviews (`create_review/2`,
  `update_review/2`); `get_blob/3` only through it (it has no HTTP route). The others
  (`health/0`, `get_archive/3`, `create_integration/2`) are called directly.
  """
  import AtlasCode,
    only: [
      handle: 2,
      put_revision: 3,
      write_atomic: 2,
      fingerprint: 1,
      github_slug: 1,
      publish!: 2,
      sha256: 1
    ]

  @blob_bytes AtlasCode.blob_bytes()
  @git_config [
    "-c",
    "credential.helper=",
    "-c",
    "credential.helper=!gh auth git-credential",
    "-c",
    "core.hooksPath=/dev/null"
  ]
  @ustar_size 0o77777777777
  # The largest chunk of a blob's stream (`get_blob/3`).
  @chunk_bytes 64 * 1024

  @typedoc "The settings of a started Code (see `AtlasCode.start/2`)."
  @type settings :: %{
          required(:home) => Path.t(),
          required(:repositories) => %{String.t() => String.t()},
          required(:token) => binary(),
          required(:orchestrator) => binary() | nil,
          required(:gh) => String.t(),
          optional(:role) => :runtime | :orchestrator
        }

  @typedoc "An HTTP status and the JSON body Code answers with it."
  @type response :: {pos_integer(), map()}

  @doc "`GET /v1/health`."
  @spec health() :: response()
  def health,
    do:
      {200,
       %{"service" => "atlas-code", "version" => to_string(Application.spec(:atlas_code, :vsn))}}

  @doc "`POST /v1/references/resolve`: the revision handle of a branch's current commit."
  @spec resolve_reference(settings(), term()) :: response()
  def resolve_reference(settings, request) do
    case request do
      %{"repository" => repository, "reference" => reference}
      when map_size(request) == 2 and is_binary(repository) and is_binary(reference) ->
        cond do
          not Map.has_key?(settings.repositories, repository) ->
            error(403, "forbidden", "Repository is not allowed", %{"repository" => repository})

          not branch?(reference) ->
            error(400, "invalid_request", "reference must be a valid reference name")

          true ->
            resolve(settings, repository, reference)
        end

      _ ->
        malformed(:resolve_reference)
    end
  end

  @doc "`POST /v1/snapshots`: a snapshot of revisions, each at its path."
  @spec create_snapshot(settings(), term()) :: response()
  def create_snapshot(settings, request) do
    with %{"repositories" => [_ | _] = list} when map_size(request) == 1 <- request,
         true <-
           Enum.all?(list, fn item ->
             match?(
               %{"repository" => r, "revision" => v, "path" => p}
               when is_binary(r) and is_binary(v) and is_binary(p),
               item
             ) and
               map_size(item) == 3
           end) do
      cond do
        Enum.any?(list, &(not revision?(&1["revision"]))) ->
          error(400, "invalid_request", "revision must be rev_<64 lowercase hex characters>")

        bad = Enum.find(list, &(not safe_path?(&1["path"]))) ->
          error(400, "invalid_request", "path must be relative and normalized", %{
            "path" => bad["path"]
          })

        pair = overlap(Enum.map(list, & &1["path"])) ->
          error(400, "invalid_request", "paths must be unique and must not contain each other", %{
            "paths" => pair
          })

        bad = Enum.find(list, &(not Map.has_key?(settings.repositories, &1["repository"]))) ->
          error(403, "forbidden", "Repository is not allowed", %{
            "repository" => bad["repository"]
          })

        true ->
          snapshot(Enum.sort_by(list, & &1["path"]), settings)
      end
    else
      _ -> malformed(:create_snapshot)
    end
  end

  @doc """
  The refusal of a request that does not have the capability's shape (not an object, a
  member missing, unknown or of another type): the same answer whether the facade or this
  module finds it.
  """
  @spec malformed(
          :resolve_reference
          | :create_snapshot
          | :create_change
          | :create_review
          | :update_review
        ) :: response()
  def malformed(:resolve_reference),
    do:
      error(
        400,
        "invalid_request",
        "Body must be {\"repository\": string, \"reference\": string}"
      )

  def malformed(:create_snapshot),
    do:
      error(
        400,
        "invalid_request",
        ~s(Body must be {"repositories": [{"repository", "revision", "path"}, …]})
      )

  def malformed(:create_change),
    do:
      error(
        400,
        "invalid_request",
        ~s(Body must be {"change_id", "snapshot_id", "repository", "base_revision", "entries": [{"path", "op", …}, …]})
      )

  def malformed(:create_review),
    do:
      error(
        400,
        "invalid_request",
        ~s(Body must be {"review_id", "change_id", "target", "title", "body", "fingerprint"?})
      )

  def malformed(:update_review),
    do:
      error(
        400,
        "invalid_request",
        ~s(Body must be {"update_id", "review_id", "change_id", "revision", "fingerprint"})
      )

  @doc """
  The request's own checks of a capability that takes a request body, the first thing
  that capability does: `:ok`, or the refusal it answers (as `create_change/2`,
  `create_review/2` and `update_review/2` would) without looking at anything else.

  The HTTP routes run it before the boundary facade, so a body is refused exactly as
  before the facade: the facade leaves out an optional member given as null, which these
  checks refuse, and names a mistyped member in its own words.
  """
  @spec check_request(:create_change | :create_review | :update_review, term()) ::
          :ok | response()
  def check_request(:create_change, request), do: checked(change_request(request))
  def check_request(:create_review, request), do: checked(review_request(request))
  def check_request(:update_review, request), do: checked(update_request(request))

  defp checked({:ok, _request}), do: :ok
  defp checked(refusal), do: refusal

  @doc "`GET /v1/snapshots/{id}/manifest`."
  @spec get_manifest(settings(), String.t()) :: response()
  def get_manifest(settings, id) do
    with {:ok, id, manifest} <- manifest(settings.home, id),
         do: {200, Map.put(manifest, "snapshot_id", id)}
  end

  @doc """
  One blob of a snapshot, by the sha256 of a manifest entry (a file's bytes, or a symlink's
  target): `{200, %{"sha256", "size", "content"}}`. No HTTP route serves it; the boundary
  facade does (`get_blob`).

  Before it answers, the entry's revision is reached as for an archive (fetched into the
  cache when it is not there), so its refusals are those of `get_archive/3` plus
  `invalid_request` for a malformed sha256 and `not_found` for one no entry has.

  `content` is a lazy stream of binary chunks of at most #{div(@chunk_bytes, 1024)} KiB: no
  byte is read until it is enumerated, and then one chunk at a time from `git cat-file`,
  started in the enumerating process and stopped when the enumeration ends or halts. Each
  enumeration reads anew. At the end the bytes are checked against the entry's size and
  sha256; a mismatch, or a cache that lost the object, raises in the enumerating process.
  """
  @spec get_blob(settings(), String.t(), String.t()) :: response()
  def get_blob(settings, id, digest) do
    if sha256?(digest),
      do: blob_entry(settings, id, digest),
      else: error(400, "invalid_request", "sha256 must be 64 lowercase hex characters")
  end

  @doc """
  `GET /v1/snapshots/{id}/archive?path=…`: `{:tar, size, write}` on success, where
  `write.(deliver)` streams the tar through `deliver` (one piece at a time; it raises when
  the client is gone) and answers `:sent`, or `:close` when the stream broke off.
  """
  @spec get_archive(settings(), String.t(), String.t() | nil) ::
          response() | {:tar, non_neg_integer(), (function() -> :sent | :close)}
  def get_archive(settings, id, path), do: archive(settings, id, path)

  @doc "`POST /v1/changes`."
  @spec create_change(settings(), term()) :: response()
  def create_change(settings, request),
    do: with({:ok, request} <- change_request(request), do: create(settings, request))

  @doc "`PUT /v1/changes/{id}/blobs/{sha256}`: `bytes` is the raw body."
  @spec put_change_blob(settings(), String.t(), String.t(), binary()) :: response()
  def put_change_blob(settings, id, digest, bytes),
    do: locked_change(settings, id, &upload(&1, &2, digest, bytes))

  @doc "`POST /v1/changes/{id}/seal`."
  @spec seal_change(settings(), String.t()) :: response()
  def seal_change(settings, id), do: locked_change(settings, id, &seal(settings, &1, &2))

  @doc "`POST /v1/reviews`. The caller has checked the reviewing role."
  @spec create_review(settings(), term()) :: response()
  def create_review(settings, request),
    do: with({:ok, request} <- review_request(request), do: review(settings, request))

  @doc "`POST /v1/review-updates`. The caller has checked the reviewing role."
  @spec update_review(settings(), term()) :: response()
  def update_review(settings, request),
    do: with({:ok, request} <- update_request(request), do: update(settings, request))

  @doc "`POST /v1/integrations`. The caller has checked the reviewing role."
  @spec create_integration(settings(), term()) :: response()
  def create_integration(settings, request),
    do: with({:ok, request} <- integration_request(request), do: integrate(settings, request))

  defp branch?(ref) do
    String.valid?(ref) and not String.contains?(ref, <<0>>) and
      match?(
        {output, 0} when output == ref <> "\n",
        System.cmd("git", ["check-ref-format", "--branch", ref], stderr_to_stdout: true)
      )
  end

  defp sha?(value), do: Regex.match?(~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/, value)

  # Relative, normalized, UTF-8 and no `.git` component: used for request paths and for every
  # path inside a snapshotted tree, so materializing `<path>/<file>` cannot leave the folder.
  defp safe_path?(path) do
    String.valid?(path) and not String.contains?(path, "\\") and
      not Regex.match?(~r/[\x00-\x1f\x7f]/, path) and
      Enum.all?(
        String.split(path, "/"),
        &(&1 not in ["", ".", ".."] and String.downcase(&1) != ".git")
      )
  end

  defp overlap(paths) do
    indexed = Enum.with_index(paths)

    Enum.find_value(indexed, fn {a, i} ->
      Enum.find_value(indexed, fn {b, j} ->
        i != j and (a == b or String.starts_with?(b, a <> "/")) and [a, b]
      end)
    end)
  end

  # The commits the remote reports for exactly `name`, or `{:failed, exit status}`.
  defp ls_remote(git_dir, url, name) do
    # Git output is never returned: it may echo the remote URL or credential prompts.
    case System.cmd("git", @git_config ++ git_dir ++ ["ls-remote", "--exit-code", url, name],
           env: [{"GIT_TERMINAL_PROMPT", "0"}],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        for line <- String.split(output, "\n"),
            [commit, ^name] <- [String.split(line, "\t")],
            sha?(commit),
            do: commit

      {_, 2} ->
        []

      {_, status} ->
        {:failed, status}
    end
  end

  defp resolve(settings, repository, reference) do
    case ls_remote([], settings.repositories[repository], "refs/heads/" <> reference) do
      [commit] ->
        {200,
         %{
           "repository" => repository,
           "reference" => reference,
           "revision" => put_revision(settings.home, repository, commit)
         }}

      [] ->
        error(404, "unknown_reference", "Reference not found", %{
          "repository" => repository,
          "reference" => reference
        })

      {:failed, status} ->
        error(503, "provider_unavailable", "git ls-remote failed with exit status #{status}")

      _ ->
        error(503, "provider_unavailable", "Git returned an ambiguous reference")
    end
  end

  # The commit behind a handle of `repository`; handles of other repositories are refused.
  defp revision(home, repository, handle) do
    case File.read(Path.join([home, "revisions", handle <> ".json"])) do
      {:ok, json} ->
        %{"commit" => commit, "repository" => owner} = JSON.decode!(json)

        unless handle(owner, commit) == handle,
          do: raise("revisions/#{handle}.json does not match its name")

        if owner == repository,
          do: {:ok, commit},
          else:
            error(409, "repository_mismatch", "The revision belongs to another repository", %{
              "repository" => repository,
              "revision" => handle
            })

      {:error, :enoent} ->
        error(404, "unknown_revision", "Revision not found", %{
          "repository" => repository,
          "revision" => handle
        })
    end
  end

  defp revision?(value), do: is_binary(value) and Regex.match?(~r/\Arev_[0-9a-f]{64}\z/, value)

  defp snapshot(repositories, settings) do
    repositories = Enum.map(repositories, &Map.take(&1, ["path", "repository", "revision"]))

    acquired =
      Enum.reduce_while(repositories, [], fn %{"repository" => repository, "revision" => handle} =
                                               item,
                                             acc ->
        with {:ok, commit} <- revision(settings.home, repository, handle),
             {:ok, dir} <- acquire(settings, repository, commit, handle) do
          {:cont,
           [
             {dir, %{"repository" => repository, "commit" => commit, "path" => item["path"]}}
             | acc
           ]}
        else
          response -> {:halt, response}
        end
      end)

    with [_ | _] <- acquired do
      results = Enum.flat_map(acquired, fn {dir, repository} -> entries(dir, repository) end)

      case for({:refused, entry} <- results, do: entry) do
        [] ->
          # Elixir encodes maps of up to 32 keys in sorted key order, so this JSON is canonical.
          manifest =
            JSON.encode!(%{
              "entries" =>
                results |> Enum.map(fn {:ok, entry} -> entry end) |> Enum.sort_by(& &1["path"]),
              "repositories" => repositories,
              "version" => 2
            })

          hex = sha256(manifest)
          publish!(Path.join([settings.home, "snapshots", hex <> ".json"]), manifest)
          {200, %{"snapshot_id" => "sha256:" <> hex, "repositories" => repositories}}

        refused ->
          error(422, "unsupported_content", "The repository content cannot be snapshotted", %{
            "entries" => refused
          })
      end
    end
  end

  defp acquire(%{home: home, repositories: allowed}, repository, commit, handle) do
    case allowed do
      %{^repository => url} ->
        dir = cache(home, repository, url)

        case locked(dir, fn -> fetch(dir, url, commit) end) do
          :ok ->
            {:ok, dir}

          :missing ->
            error(404, "not_found", "The revision is on no reference of the remote", %{
              "repository" => repository,
              "revision" => handle
            })

          {:failed, status} ->
            error(503, "provider_unavailable", "git fetch failed with exit status #{status}")
        end

      _ ->
        error(403, "forbidden", "Repository is not allowed", %{"repository" => repository})
    end
  end

  defp cache(home, repository, url),
    do: Path.join([home, "cache", sha256([repository, 0, url]) <> ".git"])

  # shortcut: fetches branch heads only, so commits reachable from no branch are 404; fetch by SHA when needed.
  defp fetch(dir, url, commit) do
    if commit?(dir, commit) do
      :ok
    else
      {_, 0} = System.cmd("git", ["init", "--bare", "--quiet", dir], stderr_to_stdout: true)

      args =
        @git_config ++
          ["--git-dir", dir, "fetch", "--quiet", "--no-tags", url, "+refs/heads/*:refs/heads/*"]

      # Git output is never returned: it may echo the remote URL or credential prompts.
      case System.cmd("git", args, env: [{"GIT_TERMINAL_PROMPT", "0"}], stderr_to_stdout: true) do
        {_, 0} -> if commit?(dir, commit), do: :ok, else: :missing
        {_, status} -> {:failed, status}
      end
    end
  end

  defp commit?(dir, commit),
    do:
      match?(
        {"commit\n", 0},
        System.cmd("git", ["--git-dir", dir, "cat-file", "-t", commit], stderr_to_stdout: true)
      )

  defp tree(dir, commit) do
    {output, 0} =
      System.cmd("git", ["--git-dir", dir, "ls-tree", "-r", "-z", "--full-tree", "-l", commit])

    for record <- :binary.split(output, <<0>>, [:global, :trim_all]) do
      [meta, path] = :binary.split(record, "\t")
      [mode, _type, oid, size] = String.split(meta, " ", trim: true)
      {mode, oid, size, path}
    end
  end

  # Blob bytes are hashed as stored: no .gitattributes filters, export-subst or LFS expansion.
  defp entries(dir, %{"repository" => repository, "commit" => commit, "path" => root}) do
    cat_file(dir, fn port ->
      for {mode, oid, size, path} <- tree(dir, commit) do
        entry = %{"repository" => repository, "path" => root <> "/" <> path, "mode" => mode}

        cond do
          not safe_path?(path) ->
            refused(repository, path, "unsafe_path")

          mode in ["100644", "100755"] ->
            digest = blob(port, oid, :crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
            hex = Base.encode16(:crypto.hash_final(digest), case: :lower)

            {:ok,
             Map.merge(entry, %{
               "kind" => "file",
               "size" => String.to_integer(size),
               "sha256" => hex
             })}

          mode == "120000" ->
            target = blob(port, oid, "", &(&2 <> &1))

            if internal_link?(path, target),
              do:
                {:ok,
                 Map.merge(entry, %{
                   "kind" => "symlink",
                   "size" => byte_size(target),
                   "sha256" => sha256(target),
                   "target" => target
                 })},
              else: refused(repository, path, "symlink_target")

          mode == "160000" ->
            refused(repository, path, "submodule")

          true ->
            refused(repository, path, "unsupported_mode")
        end
      end
    end)
  end

  defp refused(repository, path, reason),
    do:
      {:refused,
       %{"repository" => repository, "path" => String.replace_invalid(path), "reason" => reason}}

  # A relative UTF-8 target that resolves inside the repository root.
  defp internal_link?(path, target) do
    directories = path |> String.split("/") |> Enum.drop(-1)

    String.valid?(target) and target != "" and not String.starts_with?(target, "/") and
      not String.contains?(target, <<0>>) and
      Enum.reduce_while(directories ++ String.split(target, "/"), [], fn
        "..", [] -> {:halt, :escapes}
        "..", [_ | parent] -> {:cont, parent}
        segment, stack when segment in ["", "."] -> {:cont, stack}
        segment, stack -> {:cont, [segment | stack]}
      end) != :escapes
  end

  defp manifest(home, id) do
    case Regex.run(~r/\Asha256:([0-9a-f]{64})\z/, URI.decode(id)) do
      [id, hex] ->
        case File.read(Path.join([home, "snapshots", hex <> ".json"])) do
          {:ok, json} ->
            case JSON.decode!(json) do
              %{"version" => 2} = manifest -> {:ok, id, manifest}
              _ -> superseded(home, id, hex)
            end

          {:error, :enoent} ->
            error(404, "not_found", "Snapshot not found", %{"snapshot_id" => id})
        end

      _ ->
        error(400, "invalid_request", "snapshot id must be sha256:<64 lowercase hex characters>")
    end
  end

  # A manifest from before revision handles is kept as evidence; only its successor is served.
  defp superseded(home, id, hex) do
    successor =
      case File.read(Path.join([home, "snapshots", hex <> ".successor"])) do
        {:ok, successor} -> successor
        {:error, :enoent} -> nil
      end

    error(
      409,
      "snapshot_superseded",
      "The snapshot predates revision handles; use its successor",
      %{
        "snapshot_id" => id,
        "successor" => successor
      }
    )
  end

  # Archive members are named relative to the repository root, not prefixed by its snapshot path.
  defp archive(settings, id, path) do
    with {:ok, _id, manifest} <- manifest(settings.home, id),
         %{"repository" => repository, "revision" => handle} <-
           Enum.find(manifest["repositories"], &(&1["path"] == path)) ||
             error(404, "not_found", "Path is not in the snapshot", %{"path" => path}),
         {:ok, commit} <- revision(settings.home, repository, handle),
         {:ok, dir} <- acquire(settings, repository, commit, handle) do
      oids = Map.new(tree(dir, commit), fn {_mode, oid, _size, file} -> {file, oid} end)
      prefix = path <> "/"

      members =
        for %{"path" => full} = entry <- manifest["entries"], String.starts_with?(full, prefix) do
          name = binary_part(full, byte_size(prefix), byte_size(full) - byte_size(prefix))

          case entry do
            %{"kind" => "symlink", "target" => target} ->
              {tar_header(name, 0o777, 0, "2", target), nil, 0}

            %{"mode" => "100755", "size" => size} ->
              {tar_header(name, 0o755, size, "0", ""), Map.fetch!(oids, name), size}

            %{"size" => size} ->
              {tar_header(name, 0o644, size, "0", ""), Map.fetch!(oids, name), size}
          end
        end

      size =
        Enum.reduce(members, 1024, fn {header, _oid, size}, total ->
          total + IO.iodata_length(header) + padded(size)
        end)

      {:tar, size, fn deliver -> send_tar(deliver, dir, members) end}
    end
  end

  # The blob of the first entry with `digest` (entries with the same digest have the same
  # bytes), named inside its repository's revision.
  defp blob_entry(settings, id, digest) do
    with {:ok, id, manifest} <- manifest(settings.home, id),
         %{"repository" => repository, "path" => full, "size" => size} <-
           Enum.find(manifest["entries"], &(&1["sha256"] == digest)) ||
             error(404, "not_found", "No entry of the snapshot has this sha256", %{
               "snapshot_id" => id,
               "sha256" => digest
             }),
         %{"path" => root, "revision" => handle} =
           Enum.find(
             manifest["repositories"],
             &(&1["repository"] == repository and String.starts_with?(full, &1["path"] <> "/"))
           ),
         {:ok, commit} <- revision(settings.home, repository, handle),
         {:ok, dir} <- acquire(settings, repository, commit, handle) do
      name = binary_part(full, byte_size(root) + 1, byte_size(full) - byte_size(root) - 1)

      {200,
       %{
         "sha256" => digest,
         "size" => size,
         "content" => blob_stream(dir, commit <> ":" <> name, size, digest)
       }}
    end
  end

  defp blob_stream(dir, object, size, digest) do
    Stream.resource(
      fn -> open_blob(dir, object, size) end,
      &next_chunk(&1, digest),
      fn {port, _left, _buffer, _hash} -> close_port(port) end
    )
  end

  # Git's complaints come as data, so a cache without the object fails on the header line
  # (Git output is never passed on).
  defp open_blob(dir, object, size) do
    port =
      Port.open({:spawn_executable, System.find_executable("git")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["--git-dir", dir, "cat-file", "--batch"]
      ])

    try do
      true = Port.command(port, [object, ?\n])
      {line, rest} = line(port, "")
      expected = Integer.to_string(size)

      case String.split(line, " ") do
        [_oid, "blob", ^expected] -> {port, size, rest, :crypto.hash_init(:sha256)}
        _ -> raise "the cache does not hold the blob of #{object} with #{size} bytes"
      end
    rescue
      error ->
        close_port(port)
        reraise error, __STACKTRACE__
    end
  end

  # One chunk per step: of what the pipe delivered, at most @chunk_bytes, never past the blob.
  defp next_chunk({port, 0, buffer, hash} = state, digest) do
    case buffer do
      "\n" <> _ ->
        hex = Base.encode16(:crypto.hash_final(hash), case: :lower)
        unless hex == digest, do: raise("the blob read has sha256 #{hex}, not #{digest}")
        {:halt, state}

      "" ->
        next_chunk({port, 0, receive_data(port), hash}, digest)
    end
  end

  defp next_chunk({port, left, "", hash}, digest),
    do: next_chunk({port, left, receive_data(port), hash}, digest)

  defp next_chunk({port, left, buffer, hash}, _digest) do
    take = Enum.min([byte_size(buffer), left, @chunk_bytes])
    <<chunk::binary-size(take), rest::binary>> = buffer
    {[chunk], {port, left - take, rest, :crypto.hash_update(hash, chunk)}}
  end

  # Closes a cat-file port and drops what it sent that nobody read.
  defp close_port(port) do
    # A port whose git has exited is closed already.
    if Port.info(port), do: Port.close(port)
    flush_port(port)
  end

  defp flush_port(port) do
    receive do
      {^port, _message} -> flush_port(port)
    after
      0 -> :ok
    end
  end

  # Streams one blob at a time: memory stays at one pipe chunk plus the member headers.
  # `deliver` writes one piece to the client and raises when it cannot.
  defp send_tar(deliver, dir, members) do
    cat_file(dir, fn port ->
      for {header, oid, size} <- members do
        deliver.(header)
        if oid, do: blob(port, oid, :ok, fn chunk, :ok -> deliver.(chunk) end)
        deliver.(zeros(padded(size) - size))
      end
    end)

    deliver.(zeros(1024))
    :sent
  rescue
    # The status line is already out: closing early makes the short body detectable.
    _ -> :close
  end

  defp tar_header(name, mode, size, type, link) do
    pax =
      for {key, value, needed} <- [
            {"path", name, byte_size(name) > 100},
            {"linkpath", link, byte_size(link) > 100},
            {"size", Integer.to_string(size), size > @ustar_size}
          ],
          needed do
        record = " #{key}=#{value}\n"

        length =
          Enum.find(
            byte_size(record)..(byte_size(record) + 20),
            &(&1 == byte_size(record) + byte_size(Integer.to_string(&1)))
          )

        [Integer.to_string(length), record]
      end

    header = ustar_header(name, mode, if(size > @ustar_size, do: 0, else: size), type, link)

    if pax == [],
      do: header,
      else: [
        ustar_header("PaxHeader", 0o644, IO.iodata_length(pax), "x", ""),
        pax,
        zeros(padded(IO.iodata_length(pax)) - IO.iodata_length(pax)),
        header
      ]
  end

  # Deterministic ustar header: mtime 0, uid/gid 0, no user or group names.
  defp ustar_header(name, mode, size, type, link) do
    header =
      IO.iodata_to_binary([
        field(name, 100),
        octal(mode, 8),
        octal(0, 8),
        octal(0, 8),
        octal(size, 12),
        octal(0, 12),
        "        ",
        type,
        field(link, 100),
        "ustar\0",
        "00",
        field("", 32),
        field("", 32),
        octal(0, 8),
        octal(0, 8),
        field("", 155),
        field("", 12)
      ])

    <<head::binary-size(148), _checksum::binary-size(8), tail::binary>> = header
    [head, header |> :binary.bin_to_list() |> Enum.sum() |> octal(7), " ", tail]
  end

  defp field(value, size) do
    value = binary_part(value, 0, min(byte_size(value), size))
    [value, zeros(size - byte_size(value))]
  end

  defp octal(value, size),
    do: String.pad_leading(Integer.to_string(value, 8), size - 1, "0") <> <<0>>

  defp padded(size), do: size + rem(512 - rem(size, 512), 512)
  defp zeros(size), do: :binary.copy(<<0>>, size)

  defp cat_file(dir, fun) do
    port =
      Port.open({:spawn_executable, System.find_executable("git")}, [
        :binary,
        :exit_status,
        args: ["--git-dir", dir, "cat-file", "--batch"]
      ])

    try do
      fun.(port)
    after
      Port.close(port)
    end
  end

  # Feeds one blob's bytes to `fun` chunk by chunk; requests are sequential, so nothing else is pending.
  defp blob(port, oid, acc, fun) do
    true = Port.command(port, [oid, ?\n])
    {line, rest} = line(port, "")
    [^oid, "blob", size] = String.split(line, " ")
    bytes(port, String.to_integer(size), rest, acc, fun)
  end

  defp line(port, buffer) do
    case :binary.split(buffer, "\n") do
      [line, rest] -> {line, rest}
      [_] -> line(port, buffer <> receive_data(port))
    end
  end

  defp bytes(_port, size, buffer, acc, fun) when byte_size(buffer) > size do
    <<chunk::binary-size(size), ?\n>> = buffer
    fun.(chunk, acc)
  end

  defp bytes(port, size, buffer, acc, fun),
    do: bytes(port, size - byte_size(buffer), receive_data(port), fun.(buffer, acc), fun)

  defp receive_data(port) do
    receive do
      {^port, {:data, data}} -> data
      {^port, {:exit_status, status}} -> raise "git cat-file exited with status #{status}"
    after
      60_000 -> raise "git cat-file timed out"
    end
  end

  # The request's own checks, before Code looks at anything; entries sorted by path.
  defp change_request(request) do
    with %{
           "change_id" => id,
           "snapshot_id" => snapshot_id,
           "repository" => repository,
           "base_revision" => base,
           "entries" => [_ | _] = entries
         }
         when map_size(request) == 5 and is_binary(id) and is_binary(snapshot_id) and
                is_binary(repository) and is_binary(base) <- request do
      cond do
        not uuid?(id) ->
          error(400, "invalid_request", "change_id must be a lowercase UUID", %{"change_id" => id})

        not revision?(base) ->
          error(400, "invalid_request", "base_revision must be rev_<64 lowercase hex characters>")

        bad = Enum.find(entries, &(not entry?(&1))) ->
          error(
            400,
            "invalid_request",
            ~s(An entry must be {"path", "op": "delete"}, {"path", "op": "write", "kind": "file", "mode": "100644|100755", "size", "sha256"} or {"path", "op": "write", "kind": "symlink", "mode": "120000", "target", "size", "sha256"} with the target's size and sha256),
            %{"entry" => bad}
          )

        bad = Enum.find(entries, &(not safe_path?(&1["path"]))) ->
          error(400, "invalid_request", "path must be relative and normalized", %{
            "path" => bad["path"]
          })

        path =
            entries
            |> Enum.frequencies_by(& &1["path"])
            |> Enum.find_value(fn {path, count} -> count > 1 and path end) ->
          error(400, "invalid_request", "paths must be unique", %{"path" => path})

        digest =
            entries
            |> Enum.filter(&(&1["op"] == "write"))
            |> Enum.group_by(& &1["sha256"], & &1["size"])
            |> Enum.find_value(fn {digest, sizes} -> length(Enum.uniq(sizes)) > 1 and digest end) ->
          error(400, "invalid_request", "One sha256 must have one size", %{"sha256" => digest})

        true ->
          {:ok, %{request | "entries" => Enum.sort_by(entries, & &1["path"])}}
      end
    else
      _ -> malformed(:create_change)
    end
  end

  defp uuid?(value),
    do: Regex.match?(~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/, value)

  defp sha256?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp entry?(%{"op" => "delete", "path" => path} = entry) when map_size(entry) == 2,
    do: is_binary(path)

  defp entry?(
         %{"op" => "write", "kind" => "file", "path" => path, "mode" => mode, "size" => size} =
           entry
       )
       when map_size(entry) == 6 and is_binary(path) and mode in ["100644", "100755"] and
              is_integer(size) and size in 0..@blob_bytes,
       do: sha256?(entry["sha256"])

  # Symlink targets travel in the request; their size and sha256 must describe the target bytes.
  defp entry?(%{"op" => "write", "kind" => "symlink", "mode" => "120000", "path" => path} = entry)
       when map_size(entry) == 7 and is_binary(path) and
              is_binary(:erlang.map_get("target", entry)),
       do:
         entry["size"] == byte_size(entry["target"]) and
           entry["sha256"] == sha256(entry["target"])

  defp entry?(_entry), do: false

  # Keyed by AtlasCode, as before the move, so a lock means the same to every caller.
  defp locked(key, fun), do: :global.trans({{AtlasCode, key}, self()}, fun, [node()])

  # The stored body is the canonical JSON (sorted keys, entries sorted by path), so a repeat
  # with the entries in another order is the same change.
  defp create(settings, %{"change_id" => id} = request) do
    dir = Path.join([settings.home, "changes", id])
    json = JSON.encode!(request)

    locked(dir, fn ->
      case File.read(Path.join(dir, "request.json")) do
        {:ok, ^json} ->
          state(dir, request)

        {:ok, _other} ->
          error(409, "conflict", "change_id was already used with a different body", %{
            "change_id" => id
          })

        {:error, :enoent} ->
          with :ok <- check(settings, request) do
            File.mkdir_p!(Path.join(dir, "blobs"))

            for %{"kind" => "symlink", "sha256" => digest, "target" => target} <-
                  request["entries"],
                do: put_blob(dir, digest, target)

            write_atomic(Path.join(dir, "request.json"), json)
            state(dir, request)
          end
      end
    end)
  end

  # The resulting tree must satisfy the snapshot policy: the base already does, so only written
  # paths can add a file/directory clash or an escaping symlink. Replacements are explicit:
  # every base path under a written path, and a base file above one, must be deleted.
  defp check(settings, %{
         "snapshot_id" => snapshot_id,
         "repository" => repository,
         "base_revision" => base,
         "entries" => entries
       }) do
    with {:ok, _id, manifest} <- manifest(settings.home, snapshot_id),
         true <-
           Map.has_key?(settings.repositories, repository) ||
             error(403, "forbidden", "Repository is not allowed", %{"repository" => repository}),
         %{"path" => root} <-
           Enum.find(
             manifest["repositories"],
             &(&1["repository"] == repository and &1["revision"] == base)
           ) || base_error(manifest, repository, base) do
      prefix = root <> "/"

      base_paths =
        for %{"path" => path} <- manifest["entries"],
            String.starts_with?(path, prefix),
            into: MapSet.new(),
            do: binary_part(path, byte_size(prefix), byte_size(path) - byte_size(prefix))

      {deletes, writes} = Enum.split_with(entries, &(&1["op"] == "delete"))

      tree =
        base_paths
        |> MapSet.difference(MapSet.new(deletes, & &1["path"]))
        |> MapSet.union(MapSet.new(writes, & &1["path"]))

      directories =
        for path <- tree, directory <- ancestors(path), into: MapSet.new(), do: directory

      conflict =
        Enum.find_value(writes, fn %{"path" => path} ->
          if parent = Enum.find(ancestors(path), &(&1 in tree)),
            do: [parent, path],
            else:
              path in directories and
                [path, Enum.find(tree, &String.starts_with?(&1, path <> "/"))]
        end)

      refused =
        for %{"kind" => "symlink", "path" => path, "target" => target} <- writes,
            not internal_link?(path, target),
            do: elem(refused(repository, path, "symlink_target"), 1)

      cond do
        bad = Enum.find(deletes, &(&1["path"] not in base_paths)) ->
          error(400, "invalid_request", "A deleted path must be a file or symlink in the base", %{
            "path" => bad["path"]
          })

        conflict ->
          error(
            400,
            "invalid_request",
            "A path would be both a file and a directory; delete every base path it replaces",
            %{"paths" => conflict}
          )

        refused != [] ->
          error(422, "unsupported_content", "The change content cannot be accepted", %{
            "entries" => refused
          })

        true ->
          :ok
      end
    end
  end

  defp base_error(manifest, repository, base) do
    case Enum.find(manifest["repositories"], &(&1["repository"] == repository)) do
      nil ->
        error(404, "not_found", "Repository is not in the snapshot", %{"repository" => repository})

      %{"revision" => revision} ->
        error(
          409,
          "base_mismatch",
          "base_revision is not the repository's revision in the snapshot",
          %{
            "repository" => repository,
            "base_revision" => base,
            "revision" => revision
          }
        )
    end
  end

  defp ancestors(path) do
    parts = String.split(path, "/")
    for n <- 1..(length(parts) - 1)//1, do: parts |> Enum.take(n) |> Enum.join("/")
  end

  # Uploads and seals of one change are serialized; the change must already exist.
  defp locked_change(settings, id, fun) do
    dir = Path.join([settings.home, "changes", id])

    if uuid?(id) do
      locked(dir, fn ->
        case File.read(Path.join(dir, "request.json")) do
          {:ok, json} -> fun.(dir, JSON.decode!(json))
          {:error, :enoent} -> error(404, "not_found", "Change not found", %{"change_id" => id})
        end
      end)
    else
      error(400, "invalid_request", "change id must be a lowercase UUID")
    end
  end

  defp upload(dir, request, digest, body) do
    sizes =
      for %{"op" => "write", "sha256" => ^digest, "size" => size} <- request["entries"],
          uniq: true,
          do: size

    case sizes do
      [] ->
        error(404, "not_found", "The change writes no blob with this sha256")

      [size] when byte_size(body) != size ->
        error(400, "invalid_request", "The body is #{byte_size(body)} bytes, not #{size}", %{
          "sha256" => digest
        })

      [_size] ->
        if sha256(body) == digest do
          put_blob(dir, digest, body)
          state(dir, request)
        else
          error(400, "invalid_request", "The body does not match its sha256", %{
            "sha256" => digest
          })
        end
    end
  end

  defp put_blob(dir, digest, bytes) do
    file = Path.join([dir, "blobs", digest])
    unless File.exists?(file), do: write_atomic(file, bytes)
  end

  defp state(dir, %{"change_id" => id, "entries" => entries}) do
    case File.read(Path.join(dir, "revision")) do
      {:ok, revision} ->
        {200, %{"change_id" => id, "state" => "sealed", "missing" => [], "revision" => revision}}

      {:error, :enoent} ->
        missing =
          for %{"op" => "write", "sha256" => digest} <- entries,
              not File.exists?(Path.join([dir, "blobs", digest])),
              uniq: true,
              do: digest

        {200, %{"change_id" => id, "state" => "open", "missing" => Enum.sort(missing)}}
    end
  end

  # Sealing is the only transition and happens once; a repeat returns the recorded revision.
  # The commit is deterministic, so a seal interrupted before `revision` was written repeats.
  defp seal(settings, dir, %{"repository" => repository, "base_revision" => handle} = request) do
    case state(dir, request) do
      {200, %{"state" => "open", "missing" => [_ | _] = missing}} ->
        error(422, "incomplete_upload", "Upload every blob before sealing", %{
          "missing" => missing
        })

      {200, %{"state" => "open"}} ->
        with {:ok, base} <- revision(settings.home, repository, handle),
             {:ok, git_dir} <- acquire(settings, repository, base, handle),
             {:ok, commit} <- locked(git_dir, fn -> commit(git_dir, dir, base, request) end) do
          write_atomic(
            Path.join(dir, "revision"),
            put_revision(settings.home, repository, commit)
          )

          state(dir, request)
        end

      sealed ->
        sealed
    end
  end

  # Builds the commit in Code's cache from the exact base with a temporary index: no checkout,
  # no refs/heads, no push. GIT_WORK_TREE only gives update-index a root for --force-remove;
  # read-tree without -u, --cacheinfo and --force-remove never read or write it. Author,
  # committer and date (the base's committer date) are fixed, so a change always gives the same commit.
  # Written paths that are new to the base and ignored by the resulting tree's .gitignore files
  # are left out, as `git add -A` would; see ignored/4.
  defp commit(git_dir, dir, base, %{"change_id" => id, "entries" => entries}) do
    index = Path.join(dir, "index.#{System.unique_integer([:positive])}.tmp")
    env = [{"GIT_INDEX_FILE", index}, {"GIT_WORK_TREE", dir} | identity(git_dir, base)]

    git = fn args ->
      System.cmd("git", ["-c", "core.hooksPath=/dev/null", "--git-dir", git_dir | args],
        cd: dir,
        env: env
      )
    end

    run = fn args ->
      {output, 0} = git.(args)
      String.trim(output)
    end

    try do
      run.(["read-tree", base])
      tracked = MapSet.new(:binary.split(run.(["ls-files", "-z"]), <<0>>, [:global, :trim_all]))
      {deletes, writes} = Enum.split_with(entries, &(&1["op"] == "delete"))
      digests = writes |> Enum.map(& &1["sha256"]) |> Enum.uniq()

      # Chunks of 500 keep each command line far below the OS argument limit.
      oids =
        for chunk <- Enum.chunk_every(digests, 500),
            oid <-
              String.split(
                run.([
                  "hash-object",
                  "-w",
                  "--no-filters",
                  "--" | Enum.map(chunk, &("blobs/" <> &1))
                ]),
                "\n"
              ),
            do: oid

      oid = Map.new(Enum.zip(digests, oids))

      for chunk <- Enum.chunk_every(deletes, 500),
          do: run.(["update-index", "--force-remove", "--" | Enum.map(chunk, & &1["path"])])

      for chunk <- Enum.chunk_every(writes, 500) do
        run.([
          "update-index",
          "--add"
          | Enum.flat_map(
              chunk,
              &["--cacheinfo", "#{&1["mode"]},#{oid[&1["sha256"]]},#{&1["path"]}"]
            )
        ])
      end

      untracked = for %{"path" => path} <- writes, path not in tracked, do: path

      for chunk <- Enum.chunk_every(ignored(git_dir, dir, env, untracked), 500),
          do: run.(["update-index", "--force-remove", "--" | chunk])

      tree = run.(["write-tree"])

      commit =
        run.(["commit-tree", "--no-gpg-sign", "-p", base, "-m", "Atlas change #{id}", tree])

      case claim(git_dir, "refs/atlas/changes/" <> id, commit) do
        :ok ->
          {:ok, commit}

        :taken ->
          error(409, "conflict", "The change is sealed differently in Code's cache", %{
            "change_id" => id
          })
      end
    after
      File.rm(index)
    end
  end

  # The paths Git would ignore, judged by `check-ignore --no-index` in a scratch work tree that holds
  # only the index's .gitignore files (blob bytes, no filters; symlinks are never read as rules,
  # as in Git). Exclude files outside the repository (core.excludesFile) do not apply.
  defp ignored(_git_dir, _dir, _env, []), do: []

  defp ignored(git_dir, dir, env, paths) do
    work_tree = Path.join(dir, "ignore.#{System.unique_integer([:positive])}.tmp")

    git = fn args, opts ->
      System.cmd(
        "git",
        [
          "-c",
          "core.excludesFile=/dev/null",
          "-c",
          "core.quotePath=false",
          "--git-dir",
          git_dir | args
        ],
        opts
      )
    end

    try do
      File.mkdir_p!(work_tree)
      {listing, 0} = git.(["ls-files", "-s", "-z"], cd: dir, env: env)

      for record <- :binary.split(listing, <<0>>, [:global, :trim_all]),
          [meta, path] = :binary.split(record, "\t"),
          [mode, oid, _stage] = String.split(meta, " "),
          mode != "120000",
          Path.basename(path) == ".gitignore" do
        {bytes, 0} = git.(["cat-file", "blob", oid], cd: dir, env: env)
        File.mkdir_p!(Path.dirname(Path.join(work_tree, path)))
        File.write!(Path.join(work_tree, path), bytes)
      end

      # Request paths have no control characters or backslashes, so with quotePath off Git quotes
      # only a path containing `"`, as `"` <> the path with `\"` for each `"` <> `"`.
      quoted =
        Map.new(paths, fn path ->
          if String.contains?(path, ~s(")),
            do: {~s(") <> String.replace(path, ~s("), ~s(\\")) <> ~s("), path},
            else: {path, path}
        end)

      for chunk <- Enum.chunk_every(paths, 500),
          line <-
            (case git.(["check-ignore", "--no-index", "--" | chunk],
                    cd: work_tree,
                    env: List.keystore(env, "GIT_WORK_TREE", 0, {"GIT_WORK_TREE", work_tree})
                  ) do
               {output, 0} -> String.split(output, "\n", trim: true)
               {_none, 1} -> []
             end),
          do: Map.fetch!(quoted, line)
    after
      File.rm_rf!(work_tree)
    end
  end

  # The fixed identity of Code's commits, dated by the committer date of `commit`.
  defp identity(git_dir, commit) do
    {raw, 0} = System.cmd("git", ["--git-dir", git_dir, "cat-file", "commit", commit])
    [_, date] = Regex.run(~r/^committer .* (\d+ [+-]\d{4})$/m, raw)

    [
      {"GIT_AUTHOR_NAME", "Atlas Code"},
      {"GIT_AUTHOR_EMAIL", "atlas-code@localhost"},
      {"GIT_AUTHOR_DATE", date},
      {"GIT_COMMITTER_NAME", "Atlas Code"},
      {"GIT_COMMITTER_EMAIL", "atlas-code@localhost"},
      {"GIT_COMMITTER_DATE", date}
    ]
  end

  # The empty old value makes update-ref refuse to move an existing ref; an existing ref
  # with the same (deterministic) commit is an attempt interrupted before it was recorded.
  defp claim(git_dir, ref, commit) do
    case System.cmd("git", ["--git-dir", git_dir, "update-ref", ref, commit, ""],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        :ok

      _ ->
        {current, 0} = System.cmd("git", ["--git-dir", git_dir, "rev-parse", "--verify", ref])
        if String.trim(current) == commit, do: :ok, else: :taken
    end
  end

  defp review_request(request) do
    case request do
      %{
        "review_id" => id,
        "change_id" => change,
        "target" => target,
        "title" => title,
        "body" => text
      } =
          request
      when (map_size(request) == 5 or
              (map_size(request) == 6 and is_map_key(request, "fingerprint"))) and
             is_binary(id) and is_binary(change) and is_binary(target) and is_binary(title) and
             is_binary(text) ->
        cond do
          not uuid?(id) ->
            error(400, "invalid_request", "review_id must be a lowercase UUID")

          not optional_fingerprint?(request) ->
            error(400, "invalid_request", "fingerprint must be fpr_<64 lowercase hex characters>")

          not uuid?(change) ->
            error(400, "invalid_request", "change_id must be a lowercase UUID")

          not branch?(target) ->
            error(400, "invalid_request", "target must be a valid reference name")

          String.trim(title) == "" or String.length(title) > 256 or
              String.contains?(title, ["\n", "\r"]) ->
            error(
              400,
              "invalid_request",
              "title must be one non-empty line of at most 256 characters"
            )

          not String.contains?(text, "Written by an AI agent") ->
            error(
              400,
              "invalid_request",
              ~s(body must carry the attribution "Written by an AI agent")
            )

          true ->
            {:ok, request}
        end

      _ ->
        malformed(:create_review)
    end
  end

  # A review makes a sealed change visible on the remote at a location only Code names, and on
  # GitHub also opens its pull request. The record is written before any remote effect and
  # after every phase, so a repeat resumes where the last attempt stopped. One lock covers all
  # reviews, which makes the location claim race-free.
  # shortcut: reviews are serialized, remote calls included; lock per repository if that gets slow.
  defp review(settings, %{"review_id" => id} = request) do
    dir = Path.join(settings.home, "reviews")
    file = Path.join(dir, id <> ".json")

    locked(dir, fn ->
      case File.read(file) do
        {:ok, json} ->
          case JSON.decode!(json) do
            %{"request" => ^request, "phase" => "open"} = record ->
              reviewed(record)

            %{"request" => ^request, "phase" => "failed"} ->
              location_taken()

            %{"request" => ^request} = record ->
              with {:ok, target} <- provider(settings, record),
                   do: advance(settings, file, record, target, false)

            _ ->
              error(409, "conflict", "review_id was already used with a different body", %{
                "review_id" => id
              })
          end

        {:error, :enoent} ->
          with {:ok, record} <- review_record(settings, request),
               {:ok, target} <- provider(settings, record) do
            File.mkdir_p!(dir)
            advance(settings, file, save(file, record), target, true)
          end
      end
    end)
  end

  # Repository and revision come only from the sealed change. A location is claimed by the
  # first review that records it, even if that review later failed.
  defp review_record(settings, %{"review_id" => id, "change_id" => change_id} = request) do
    dir = Path.join([settings.home, "changes", change_id])

    case {File.read(Path.join(dir, "request.json")), File.read(Path.join(dir, "revision"))} do
      {{:error, :enoent}, _} ->
        error(404, "not_found", "Change not found", %{"change_id" => change_id})

      {_, {:error, :enoent}} ->
        error(409, "change_not_sealed", "Only a sealed change can be reviewed", %{
          "change_id" => change_id
        })

      {{:ok, json}, {:ok, revision}} ->
        %{"repository" => repository} = stored = JSON.decode!(json)
        location = "work/review-" <> id
        reviews = Path.join(settings.home, "reviews")

        names =
          case File.ls(reviews) do
            {:ok, names} -> names
            {:error, :enoent} -> []
          end

        claimed =
          Enum.any?(names, fn name ->
            String.ends_with?(name, ".json") and
              match?(
                %{"repository" => ^repository, "location" => ^location},
                reviews |> Path.join(name) |> File.read!() |> JSON.decode!()
              )
          end)

        cond do
          mismatch = fingerprint_mismatch(request, change_id, fn -> stored end) ->
            mismatch

          claimed ->
            location_taken()

          true ->
            {:ok,
             %{
               "request" => request,
               "phase" => "pushing",
               "repository" => repository,
               "change_id" => change_id,
               "revision" => revision,
               "location" => location
             }}
        end
    end
  end

  defp optional_fingerprint?(%{"fingerprint" => value}),
    do: is_binary(value) and Regex.match?(~r/\Afpr_[0-9a-f]{64}\z/, value)

  defp optional_fingerprint?(_request), do: true

  # nil when the request names no fingerprint or names the change's own; `stored` loads the
  # change's request.json only when it is needed.
  defp fingerprint_mismatch(%{"fingerprint" => expected}, change_id, stored) do
    actual = fingerprint(stored.())

    if actual != expected,
      do:
        error(409, "fingerprint_mismatch", "The change's content is not the given fingerprint", %{
          "change_id" => change_id,
          "fingerprint" => actual
        })
  end

  defp fingerprint_mismatch(_request, _change_id, _stored), do: nil

  # Checked on every attempt with remote effects: the repository must still be allowed and the
  # sealed commit in Code's cache. Only https://github.com/OWNER/REPO remotes get a pull request;
  # any other remote's review is the pushed location itself.
  defp provider(settings, %{"repository" => repository, "revision" => handle}) do
    url = settings.repositories[repository]

    with true <-
           url != nil ||
             error(403, "forbidden", "Repository is not allowed", %{"repository" => repository}),
         {:ok, commit} <- revision(settings.home, repository, handle) do
      dir = cache(settings.home, repository, url)

      if commit?(dir, commit),
        do: {:ok, %{url: url, dir: dir, slug: github_slug(url), commit: commit}},
        else:
          error(
            409,
            "conflict",
            "The sealed revision is not in Code's cache for the configured remote",
            %{
              "revision" => handle
            }
          )
    end
  end

  defp advance(settings, file, record, target, first) do
    with {:ok, record} <- push(file, record, target, first),
         {:ok, record} <- pull_request(settings.gh, file, record, target),
         do: reviewed(save(file, %{record | "phase" => "open"}))
  end

  defp push(_file, %{"phase" => "pushed"} = record, _target, _first), do: {:ok, record}

  defp push(
         file,
         %{"location" => location} = record,
         %{url: url, dir: dir, commit: commit},
         first
       ) do
    ref = "refs/heads/" <> location

    # A repeat still in phase pushing may follow our own push whose response was lost, so the
    # location at exactly our commit counts as ours. A third party creating the same location
    # at the same commit is indistinguishable, and harmless.
    case if(first, do: [], else: ls_remote(["--git-dir", dir], url, ref)) do
      [^commit] ->
        {:ok, save(file, %{record | "phase" => "pushed"})}

      [] ->
        # The empty lease and the remote's own old-value check refuse an existing location, even
        # a fast-forward. One already at the commit is reported "=" with exit 0, so only "*"
        # (new ref) is our write.
        args =
          @git_config ++
            [
              "--git-dir",
              dir,
              "push",
              "--porcelain",
              "--force-with-lease=#{ref}:",
              url,
              "#{commit}:#{ref}"
            ]

        {output, status} =
          System.cmd("git", args, env: [{"GIT_TERMINAL_PROMPT", "0"}], stderr_to_stdout: true)

        cond do
          status == 0 and flag(output, "#{commit}:#{ref}") == "*" ->
            {:ok, save(file, %{record | "phase" => "pushed"})}

          # No status line: the outcome is unknown, so the phase stays pushing for a repeat.
          flag(output, "#{commit}:#{ref}") == nil ->
            error(503, "provider_unavailable", "git push failed with exit status #{status}")

          true ->
            case ls_remote(["--git-dir", dir], url, ref) do
              [_ | _] ->
                failed(file, record)

              _ ->
                error(
                  503,
                  "provider_unavailable",
                  "git push was refused with exit status #{status}"
                )
            end
        end

      [_ | _] ->
        failed(file, record)

      {:failed, status} ->
        error(503, "provider_unavailable", "git ls-remote failed with exit status #{status}")
    end
  end

  # The porcelain status flag of `spec`, or nil when Git printed no status line for it.
  defp flag(output, spec) do
    Enum.find_value(String.split(output, "\n"), fn line ->
      case String.split(line, "\t") do
        [flag, ^spec | _] -> flag
        _ -> nil
      end
    end)
  end

  defp failed(file, record) do
    save(file, %{record | "phase" => "failed"})
    location_taken()
  end

  defp location_taken,
    do:
      error(
        409,
        "location_taken",
        "The review location already exists or is claimed; Code never overwrites it"
      )

  # An existing pull request for the location is one an earlier attempt created before its
  # response was lost, so it is adopted rather than duplicated. gh output is never returned.
  defp pull_request(_gh, _file, record, %{slug: nil}), do: {:ok, record}

  # Publications without a pull request were migrated without a target: nothing to open.
  defp pull_request(_gh, _file, %{"request" => %{"target" => nil}} = record, _target),
    do: {:ok, record}

  defp pull_request(gh, file, %{"request" => request, "location" => location} = record, %{
         slug: slug
       }) do
    executable = System.find_executable(gh)

    run = fn args ->
      System.cmd(executable, args,
        cd: Path.dirname(file),
        env: [{"GH_PROMPT_DISABLED", "1"}, {"GIT_TERMINAL_PROMPT", "0"}],
        stderr_to_stdout: true
      )
    end

    url =
      executable &&
        case run.([
               "pr",
               "list",
               "--repo=" <> slug,
               "--head=" <> location,
               "--state",
               "all",
               "--json",
               "url"
             ]) do
          {output, 0} ->
            case JSON.decode(output) do
              {:ok, [%{"url" => url}]} -> url
              {:ok, []} -> create_pull_request(run, file, slug, location, request)
              _ -> nil
            end

          _ ->
            nil
        end

    if is_binary(url),
      do: {:ok, Map.put(record, "review_url", url)},
      else:
        error(
          502,
          "review_incomplete",
          "The review is pushed but its pull request is not created; repeat the request",
          %{
            "phase" => "pushed"
          }
        )
  end

  defp create_pull_request(run, file, slug, location, %{
         "target" => base,
         "title" => title,
         "body" => body
       }) do
    body_file = file <> ".body.tmp"
    File.write!(body_file, body)

    try do
      args = ["pr", "create", "--repo=" <> slug, "--head=" <> location, "--base=" <> base]

      case run.(args ++ ["--title=" <> title, "--body-file=" <> body_file]) do
        {output, 0} ->
          case Regex.run(~r{^https://github\.com/\S+/pull/\d+$}m, output) do
            [url] -> url
            nil -> nil
          end

        _ ->
          nil
      end
    after
      File.rm(body_file)
    end
  end

  defp reviewed(%{"request" => request} = record) do
    reply = %{
      "review_id" => request["review_id"],
      "change_id" => record["change_id"],
      "repository" => record["repository"],
      "target" => request["target"],
      "revision" => record["revision"],
      "state" => "open"
    }

    {200, if(url = record["review_url"], do: Map.put(reply, "review_url", url), else: reply)}
  end

  defp update_request(request) do
    case request do
      %{
        "update_id" => id,
        "review_id" => review,
        "change_id" => change,
        "revision" => revision,
        "fingerprint" => _fingerprint
      } = request
      when map_size(request) == 5 and is_binary(id) and is_binary(review) and is_binary(change) ->
        cond do
          not uuid?(id) ->
            error(400, "invalid_request", "update_id must be a lowercase UUID")

          not uuid?(review) ->
            error(400, "invalid_request", "review_id must be a lowercase UUID")

          not uuid?(change) ->
            error(400, "invalid_request", "change_id must be a lowercase UUID")

          not revision?(revision) ->
            error(400, "invalid_request", "revision must be rev_<64 lowercase hex characters>")

          not optional_fingerprint?(request) ->
            error(400, "invalid_request", "fingerprint must be fpr_<64 lowercase hex characters>")

          true ->
            {:ok, request}
        end

      _ ->
        malformed(:update_review)
    end
  end

  # An update moves an open review's location to another sealed change, after a decision on
  # exactly that change's fingerprint. Code commits the change's tree as a child of the review's
  # current head (fixed identity, the head's committer date, so the commit is deterministic) and
  # fast-forwards the location with a lease on that head: a location someone else moved is never
  # overwritten. The pull request follows its branch, so no provider call is needed. The record
  # is written before the push; `pushing` is the only phase that is resumed. Updates share the
  # reviews lock, so they never interleave with a review or with each other.
  defp update(settings, %{"update_id" => id} = request) do
    file = Path.join([settings.home, "review-updates", id <> ".json"])

    locked(Path.join(settings.home, "reviews"), fn ->
      case File.read(file) do
        {:ok, json} ->
          case JSON.decode!(json) do
            %{"request" => ^request, "phase" => "pushing"} = record ->
              with {:ok, target} <- update_target(settings, record),
                   do: move(settings, file, record, target)

            %{"request" => ^request} = record ->
              update_outcome(record)

            _ ->
              error(409, "conflict", "update_id was already used with a different body", %{
                "update_id" => id
              })
          end

        {:error, :enoent} ->
          with {:ok, record, target} <- update_record(settings, request) do
            File.mkdir_p!(Path.dirname(file))
            move(settings, file, save(file, record), target)
          end
      end
    end)
  end

  # Every check runs before any record or remote effect, in the contract's order.
  defp update_record(
         settings,
         %{"review_id" => review_id, "change_id" => change_id, "revision" => revision} = request
       ) do
    with {:ok, review} <- open_review(settings, review_id),
         {:ok, stored, sealed} <- sealed_change(settings, change_id) do
      cond do
        stored["repository"] != review["repository"] ->
          error(409, "repository_mismatch", "The change is for another repository", %{
            "repository" => review["repository"],
            "change_id" => change_id
          })

        review["revision"] != revision ->
          error(409, "revision_mismatch", "revision is not the review's current revision", %{
            "review_id" => review_id,
            "revision" => review["revision"]
          })

        mismatch = fingerprint_mismatch(request, change_id, fn -> stored end) ->
          mismatch

        true ->
          record = %{
            "request" => request,
            "phase" => "pushing",
            "review_id" => review_id,
            "repository" => review["repository"],
            "location" => review["location"],
            "change_id" => change_id,
            "sealed" => sealed,
            "previous_revision" => revision
          }

          record =
            if url = review["review_url"], do: Map.put(record, "review_url", url), else: record

          with {:ok, %{dir: dir, head: head, sealed: tree} = target} <-
                 update_target(settings, record),
               {:ok, child} <- locked(dir, fn -> child(dir, head, tree, request) end) do
            handle = put_revision(settings.home, review["repository"], child)
            {:ok, Map.put(record, "revision", handle), target}
          end
      end
    end
  end

  defp open_review(settings, review_id) do
    case File.read(Path.join([settings.home, "reviews", review_id <> ".json"])) do
      {:ok, json} ->
        case JSON.decode!(json) do
          %{"phase" => "open"} = review ->
            {:ok, review}

          _ ->
            error(409, "review_not_open", "Only an open review can be updated", %{
              "review_id" => review_id
            })
        end

      {:error, :enoent} ->
        error(404, "not_found", "Review not found", %{"review_id" => review_id})
    end
  end

  defp sealed_change(settings, change_id) do
    dir = Path.join([settings.home, "changes", change_id])

    case {File.read(Path.join(dir, "request.json")), File.read(Path.join(dir, "revision"))} do
      {{:error, :enoent}, _} ->
        error(404, "not_found", "Change not found", %{"change_id" => change_id})

      {_, {:error, :enoent}} ->
        error(409, "change_not_sealed", "Only a sealed change can update a review", %{
          "change_id" => change_id
        })

      {{:ok, json}, {:ok, revision}} ->
        {:ok, JSON.decode!(json), revision}
    end
  end

  # Checked on every attempt with remote effects, like a review's provider: the repository must
  # still be allowed and the review's head and the change's sealed commit in Code's cache.
  defp update_target(settings, %{"repository" => repository} = record) do
    url = settings.repositories[repository]

    with true <-
           url != nil ||
             error(403, "forbidden", "Repository is not allowed", %{"repository" => repository}),
         {:ok, head} <- revision(settings.home, repository, record["previous_revision"]),
         {:ok, sealed} <- revision(settings.home, repository, record["sealed"]) do
      dir = cache(settings.home, repository, url)

      if commit?(dir, head) and commit?(dir, sealed),
        do: {:ok, %{url: url, dir: dir, head: head, sealed: sealed}},
        else:
          error(
            409,
            "conflict",
            "The review's or the change's revision is not in Code's cache for the configured remote",
            %{"revision" => record["previous_revision"], "change_id" => record["change_id"]}
          )
    end
  end

  # The sealed change's tree on top of the review's head, kept on a private ref so Git never
  # prunes it. The same update always gives the same commit, so a repeat after a crash reclaims it.
  defp child(dir, head, sealed, %{"update_id" => id, "change_id" => change}) do
    {output, 0} =
      System.cmd(
        "git",
        [
          "-c",
          "core.hooksPath=/dev/null",
          "--git-dir",
          dir,
          "commit-tree",
          "--no-gpg-sign",
          "-p",
          head,
          "-m",
          "Atlas change #{change}",
          "-m",
          "Review update #{id}",
          sealed <> "^{tree}"
        ],
        env: identity(dir, head)
      )

    commit = String.trim(output)

    case claim(dir, "refs/atlas/updates/" <> id, commit) do
      :ok ->
        {:ok, commit}

      :taken ->
        error(409, "conflict", "The update is recorded differently in Code's cache", %{
          "update_id" => id
        })
    end
  end

  # Fast-forwards the location from the review's head to the update's commit. Every attempt asks
  # the remote first: a location already at the commit is an earlier push whose response was lost.
  defp move(
         settings,
         file,
         %{"location" => location, "repository" => repository} = record,
         %{url: url, dir: dir, head: head} = target
       ) do
    ref = "refs/heads/" <> location
    {:ok, child} = revision(settings.home, repository, record["revision"])

    case ls_remote(["--git-dir", dir], url, ref) do
      [^child] ->
        advanced(settings, file, record)

      [^head] ->
        args =
          @git_config ++
            [
              "--git-dir",
              dir,
              "push",
              "--porcelain",
              "--force-with-lease=#{ref}:#{head}",
              url,
              "#{child}:#{ref}"
            ]

        {output, status} =
          System.cmd("git", args, env: [{"GIT_TERMINAL_PROMPT", "0"}], stderr_to_stdout: true)

        flag = flag(output, "#{child}:#{ref}")

        cond do
          status == 0 and flag in [" ", "="] ->
            advanced(settings, file, record)

          # No status line: the outcome is unknown, so the phase stays pushing for a repeat.
          flag == nil ->
            error(503, "provider_unavailable", "git push failed with exit status #{status}")

          true ->
            case ls_remote(["--git-dir", dir], url, ref) do
              [^child] ->
                advanced(settings, file, record)

              # Still at the head: the remote itself refused the update.
              [^head] ->
                update_outcome(
                  save(
                    file,
                    %{record | "phase" => "refused"} |> Map.put("code", "update_refused")
                  )
                )

              {:failed, _} ->
                error(
                  503,
                  "provider_unavailable",
                  "git push was refused with exit status #{status}"
                )

              current ->
                diverged(settings, file, record, target, child, current)
            end
        end

      {:failed, status} ->
        error(503, "provider_unavailable", "git ls-remote failed with exit status #{status}")

      current ->
        diverged(settings, file, record, target, child, current)
    end
  end

  # The location is at neither the head nor the update: someone else moved or removed it. It
  # holds the update only when it contains the update's commit (pushed on top after a lost reply).
  defp diverged(settings, file, record, %{url: url, dir: dir}, child, [commit]) do
    case locked(dir, fn -> fetch(dir, url, commit) end) do
      :ok ->
        if ancestor?(dir, child, commit),
          do: advanced(settings, file, record),
          else: location_moved(settings, file, record, commit)

      :missing ->
        location_moved(settings, file, record, commit)

      {:failed, status} ->
        error(503, "provider_unavailable", "git fetch failed with exit status #{status}")
    end
  end

  defp diverged(settings, file, record, _target, _child, []),
    do: location_moved(settings, file, record, nil)

  defp diverged(_settings, _file, _record, _target, _child, _current),
    do: error(503, "provider_unavailable", "Git returned an ambiguous reference")

  defp location_moved(settings, file, record, commit) do
    current = commit && put_revision(settings.home, record["repository"], commit)

    update_outcome(
      save(
        file,
        Map.merge(record, %{
          "phase" => "refused",
          "code" => "location_moved",
          "current" => current
        })
      )
    )
  end

  # The review follows its location: revision and change become the update's, once per update.
  defp advanced(settings, file, %{"request" => %{"update_id" => id}} = record) do
    review_file = Path.join([settings.home, "reviews", record["review_id"] <> ".json"])
    review = review_file |> File.read!() |> JSON.decode!()
    updates = Map.get(review, "updates", [])

    unless id in updates do
      save(
        review_file,
        Map.merge(review, %{
          "revision" => record["revision"],
          "change_id" => record["change_id"],
          "updates" => updates ++ [id]
        })
      )
    end

    update_outcome(save(file, %{record | "phase" => "updated"}))
  end

  defp update_outcome(%{"phase" => "updated", "request" => request} = record) do
    reply = %{
      "update_id" => request["update_id"],
      "review_id" => record["review_id"],
      "change_id" => record["change_id"],
      "repository" => record["repository"],
      "previous_revision" => record["previous_revision"],
      "revision" => record["revision"],
      "state" => "open"
    }

    {200, if(url = record["review_url"], do: Map.put(reply, "review_url", url), else: reply)}
  end

  defp update_outcome(%{"phase" => "refused", "code" => "location_moved"} = record),
    do:
      error(
        409,
        "location_moved",
        "The review location is not at the review's revision; Code never overwrites it",
        %{"review_id" => record["review_id"], "current" => record["current"]}
      )

  defp update_outcome(%{"phase" => "refused", "code" => "update_refused"} = record),
    do:
      error(
        409,
        "update_refused",
        "The remote refused to move the review location, for example by branch policy; Code never bypasses it",
        %{"review_id" => record["review_id"]}
      )

  defp integration_request(request) do
    case request do
      %{
        "integration_id" => id,
        "review_id" => review,
        "revision" => revision,
        "target_revision" => target
      } =
          request
      when (map_size(request) == 4 or
              (map_size(request) == 5 and is_map_key(request, "fingerprint"))) and
             is_binary(id) and is_binary(review) ->
        cond do
          not uuid?(id) ->
            error(400, "invalid_request", "integration_id must be a lowercase UUID")

          not optional_fingerprint?(request) ->
            error(400, "invalid_request", "fingerprint must be fpr_<64 lowercase hex characters>")

          not uuid?(review) ->
            error(400, "invalid_request", "review_id must be a lowercase UUID")

          not (revision?(revision) and revision?(target)) ->
            error(
              400,
              "invalid_request",
              "revision and target_revision must be rev_<64 lowercase hex characters>"
            )

          true ->
            {:ok, request}
        end

      _ ->
        error(
          400,
          "invalid_request",
          ~s(Body must be {"integration_id", "review_id", "revision", "target_revision", "fingerprint"?})
        )
    end
  end

  # An integration moves the review's target from exactly target_revision to the review's
  # revision: a fast-forward when the revision already contains the target, otherwise a merge
  # built in Code's cache. The push carries a lease on target_revision, so it never replaces
  # work Code has not seen. Every outcome is recorded and replayed for the same request;
  # `integrating` is the only phase that is resumed. One lock covers all integrations.
  defp integrate(settings, %{"integration_id" => id} = request) do
    dir = Path.join(settings.home, "integrations")
    file = Path.join(dir, id <> ".json")

    locked(dir, fn ->
      case File.read(file) do
        {:ok, json} ->
          case JSON.decode!(json) do
            %{"request" => ^request, "phase" => "integrating"} = record ->
              with {:ok, context} <- context(settings, record),
                   do: land(file, record, context, false)

            %{"request" => ^request} = record ->
              outcome(record)

            _ ->
              error(409, "conflict", "integration_id was already used with a different body", %{
                "integration_id" => id
              })
          end

        {:error, :enoent} ->
          with {:ok, record, context} <- integration(settings, request) do
            File.mkdir_p!(dir)
            prepare(file, record, context)
          end
      end
    end)
  end

  defp integration(settings, %{"review_id" => review_id, "revision" => revision} = request) do
    case File.read(Path.join([settings.home, "reviews", review_id <> ".json"])) do
      {:error, :enoent} ->
        error(404, "not_found", "Review not found", %{"review_id" => review_id})

      {:ok, json} ->
        review = JSON.decode!(json)

        cond do
          review["phase"] != "open" ->
            error(409, "review_not_open", "Only an open review can be integrated", %{
              "review_id" => review_id
            })

          review["request"]["target"] == nil ->
            error(
              409,
              "review_has_no_target",
              "The review has no target; open a new review of the change",
              %{
                "review_id" => review_id
              }
            )

          review["revision"] != revision ->
            error(409, "revision_mismatch", "revision is not the review's revision", %{
              "review_id" => review_id,
              "revision" => review["revision"]
            })

          # The review's current change is what its location holds, so the check covers it.
          mismatch =
              fingerprint_mismatch(request, review["change_id"], fn ->
                Path.join([settings.home, "changes", review["change_id"], "request.json"])
                |> File.read!()
                |> JSON.decode!()
              end) ->
            mismatch

          true ->
            record = %{
              "request" => request,
              "phase" => "integrating",
              "repository" => review["repository"],
              "target" => review["request"]["target"]
            }

            with {:ok, context} <- context(settings, record), do: {:ok, record, context}
        end
    end
  end

  # Checked on every attempt with remote effects, like a review's provider.
  defp context(settings, %{"repository" => repository, "request" => request}) do
    url = settings.repositories[repository]

    with true <-
           url != nil ||
             error(403, "forbidden", "Repository is not allowed", %{"repository" => repository}),
         {:ok, change} <- revision(settings.home, repository, request["revision"]),
         {:ok, expected} <- revision(settings.home, repository, request["target_revision"]) do
      {:ok,
       %{
         home: settings.home,
         url: url,
         dir: cache(settings.home, repository, url),
         change: change,
         expected: expected
       }}
    end
  end

  defp prepare(
         file,
         %{"target" => target} = record,
         %{url: url, dir: dir, expected: expected} = context
       ) do
    case ls_remote(["--git-dir", dir], url, "refs/heads/" <> target) do
      [^expected] ->
        case locked(dir, fn -> fetch(dir, url, expected) end) do
          :ok ->
            candidate(file, record, context)

          :missing ->
            moved(
              file,
              record,
              context,
              ls_remote(["--git-dir", dir], url, "refs/heads/" <> target)
            )

          {:failed, status} ->
            error(503, "provider_unavailable", "git fetch failed with exit status #{status}")
        end

      current ->
        moved(file, record, context, current)
    end
  end

  defp candidate(file, record, %{dir: dir, change: change, expected: expected} = context) do
    id = record["request"]["integration_id"]

    cond do
      ancestor?(dir, change, expected) ->
        result = %{
          "phase" => "integrated",
          "method" => "already_integrated",
          "result" => record["request"]["target_revision"]
        }

        outcome(save(file, Map.merge(record, result)))

      ancestor?(dir, expected, change) ->
        land(file, candidate!(file, record, dir, change, "fast_forward"), context, true)

      true ->
        case merge(dir, expected, change, id) do
          {:ok, merged} ->
            land(file, candidate!(file, record, dir, merged, "merge"), context, true)

          {:conflict, paths} ->
            outcome(save(file, Map.merge(record, %{"phase" => "conflicted", "paths" => paths})))
        end
    end
  end

  # The candidate keeps a private ref, so Git never prunes it, and is recorded before the push.
  defp candidate!(file, record, dir, commit, method) do
    :ok = claim(dir, "refs/atlas/integrations/" <> record["request"]["integration_id"], commit)
    save(file, Map.merge(record, %{"candidate" => commit, "method" => method}))
  end

  # A merge of the review onto the exact target in Code's cache: no checkout, and a fixed
  # identity and date (the target's committer date), so a repeat gives the same commit.
  defp merge(dir, target, change, id) do
    args = [
      "--git-dir",
      dir,
      "merge-tree",
      "--write-tree",
      "--name-only",
      "--no-messages",
      "-z",
      target,
      change
    ]

    case System.cmd("git", ["-c", "core.hooksPath=/dev/null" | args]) do
      {output, 0} ->
        [tree | _] = :binary.split(output, <<0>>, [:global, :trim_all])

        {merged, 0} =
          System.cmd(
            "git",
            [
              "--git-dir",
              dir,
              "commit-tree",
              "--no-gpg-sign",
              "-p",
              target,
              "-p",
              change,
              "-m",
              "Atlas integration #{id}",
              tree
            ],
            env: identity(dir, target)
          )

        {:ok, String.trim(merged)}

      {output, 1} ->
        [_tree | paths] = :binary.split(output, <<0>>, [:global, :trim_all])
        {:conflict, paths |> Enum.map(&String.replace_invalid/1) |> Enum.uniq() |> Enum.sort()}
    end
  end

  defp ancestor?(dir, ancestor, commit) do
    case System.cmd("git", ["--git-dir", dir, "merge-base", "--is-ancestor", ancestor, commit],
           stderr_to_stdout: true
         ) do
      {_, 0} -> true
      {_, 1} -> false
    end
  end

  # Pushes the recorded candidate. A first attempt has just seen the target at
  # target_revision; a repeat asks the remote, since an earlier push may have landed.
  defp land(
         file,
         %{"target" => target, "candidate" => candidate} = record,
         %{url: url, dir: dir, expected: expected} = context,
         first
       ) do
    ref = "refs/heads/" <> target

    case if(first, do: [expected], else: ls_remote(["--git-dir", dir], url, ref)) do
      [^candidate] ->
        landed(file, record, context)

      [^expected] ->
        args =
          @git_config ++
            [
              "--git-dir",
              dir,
              "push",
              "--porcelain",
              "--force-with-lease=#{ref}:#{expected}",
              url,
              "#{candidate}:#{ref}"
            ]

        {output, status} =
          System.cmd("git", args, env: [{"GIT_TERMINAL_PROMPT", "0"}], stderr_to_stdout: true)

        flag = flag(output, "#{candidate}:#{ref}")

        cond do
          status == 0 and flag in [" ", "="] ->
            landed(file, record, context)

          # No status line: the outcome is unknown, so the phase stays integrating for a repeat.
          flag == nil ->
            error(503, "provider_unavailable", "git push failed with exit status #{status}")

          true ->
            # Rejected: a target still at target_revision was refused by the remote itself.
            case ls_remote(["--git-dir", dir], url, ref) do
              [^candidate] ->
                landed(file, record, context)

              [^expected] ->
                outcome(save(file, %{record | "phase" => "refused"}))

              {:failed, _} ->
                error(
                  503,
                  "provider_unavailable",
                  "git push was refused with exit status #{status}"
                )

              current ->
                reconcile(file, record, context, current)
            end
        end

      {:failed, status} ->
        error(503, "provider_unavailable", "git ls-remote failed with exit status #{status}")

      current ->
        reconcile(file, record, context, current)
    end
  end

  # The target moved past the lease: the integration landed only if the target contains the candidate.
  defp reconcile(file, record, %{url: url, dir: dir} = context, [commit]) do
    case locked(dir, fn -> fetch(dir, url, commit) end) do
      :ok ->
        if ancestor?(dir, record["candidate"], commit),
          do: landed(file, record, context),
          else: moved(file, record, context, [commit])

      :missing ->
        moved(file, record, context, [commit])

      {:failed, status} ->
        error(503, "provider_unavailable", "git fetch failed with exit status #{status}")
    end
  end

  defp reconcile(file, record, context, []), do: moved(file, record, context, [])

  defp reconcile(_file, _record, _context, _current),
    do: error(503, "provider_unavailable", "Git returned an ambiguous reference")

  defp moved(_file, _record, _context, {:failed, status}),
    do: error(503, "provider_unavailable", "git ls-remote failed with exit status #{status}")

  defp moved(file, record, %{home: home}, current) when length(current) < 2 do
    handle =
      case current do
        [commit] -> put_revision(home, record["repository"], commit)
        [] -> nil
      end

    outcome(save(file, Map.merge(record, %{"phase" => "target_moved", "current" => handle})))
  end

  defp moved(_file, _record, _context, _current),
    do: error(503, "provider_unavailable", "Git returned an ambiguous reference")

  defp landed(file, %{"repository" => repository, "candidate" => candidate} = record, %{
         home: home
       }),
       do:
         outcome(
           save(
             file,
             Map.merge(record, %{
               "phase" => "integrated",
               "result" => put_revision(home, repository, candidate)
             })
           )
         )

  defp outcome(%{"phase" => "integrated", "request" => request} = record),
    do:
      {200,
       %{
         "integration_id" => request["integration_id"],
         "review_id" => request["review_id"],
         "repository" => record["repository"],
         "target" => record["target"],
         "revision" => record["result"],
         "method" => record["method"],
         "state" => "integrated"
       }}

  defp outcome(%{"phase" => "target_moved"} = record),
    do:
      error(
        409,
        "target_moved",
        "The target is not at target_revision; resolve it again and use a new integration_id",
        %{
          "target" => record["target"],
          "current" => record["current"]
        }
      )

  defp outcome(%{"phase" => "conflicted"} = record),
    do:
      error(
        409,
        "integration_conflict",
        "The review conflicts with the target; the target was not changed",
        %{
          "target" => record["target"],
          "paths" => record["paths"]
        }
      )

  defp outcome(%{"phase" => "refused"} = record),
    do:
      error(
        409,
        "integration_refused",
        "The remote refused to update the target, for example by branch policy; Code never bypasses it",
        %{
          "target" => record["target"]
        }
      )

  defp save(file, record) do
    write_atomic(file, JSON.encode!(record))
    record
  end

  @doc false
  # Code's error body: `{"error": {"code", "message", "details"}}` with its HTTP status.
  def error(status, code, message, details \\ %{}),
    do: {status, %{"error" => %{"code" => code, "message" => message, "details" => details}}}
end
