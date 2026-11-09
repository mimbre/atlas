defmodule AtlasCode do
  @moduledoc """
  Local Code service: `GET /v1/health`, `POST /v1/references/resolve`, `POST /v1/snapshots`,
  `GET /v1/snapshots/{id}/manifest`, `GET /v1/snapshots/{id}/archive?path=…`,
  `POST /v1/changes`, `PUT /v1/changes/{id}/blobs/{sha256}`, `POST /v1/changes/{id}/seal`,
  `POST /v1/reviews` and `POST /v1/integrations` on 127.0.0.1 over OTP `:inets` httpd. Every
  request, health included, needs `Authorization: Bearer <token>`: the runtime token or the
  orchestrator token. Only the orchestrator token may review or integrate.

  Clients see repository names, reference names, `sha256:` snapshot IDs, opaque
  `rev_<64 hex>` revision handles and their own UUIDs. Commits, branches, refs, remote URLs and
  Git output stay inside Code; Git is its only backend.

  The home directory holds:
  - `config.json`: `{"port": N, "repositories": {"github.com/owner/repo": "<git remote URL or path>"},
    "gh"?: "<gh executable>"}`. The repository keys are the only names the API accepts; `gh`
    defaults to `gh` on PATH.
  - `runtime.token`: the bearer token, an owner-only (0600) regular file.
  - `orchestrator.token` (optional): the reviewing token, same file rules, different from
    `runtime.token`. Without it Code starts and refuses every review and integration.
  - `service.owner/owner.json`: `{"kind", "owner", "os_pid", "node", "started_at"}` of the
    service or `mix atlas_code.migrate` that owns the home; while it exists nothing else may.
    Releasing renames it to `service.owner.ended-<owner>`, which is kept. After a crash,
    SIGKILL or Ctrl-C it stays until `mix atlas_code.unlock --owner <owner>` recovers it.
  - `cache/<sha256 of name and remote>.git`: Code's private bare clone per repository.
    Sealed changes live there on `refs/atlas/changes/<change id>`, integration candidates on
    `refs/atlas/integrations/<integration id>`.
  - `revisions/<handle>.json`: `{"commit", "repository"}`, written before any reply carries the
    handle. A handle is the SHA-256 of its repository and commit, so it never changes.
  - `snapshots/<hex>.json`: the canonical version 2 manifest whose SHA-256 is the snapshot ID.
    A manifest from before revision handles stays as written, next to `<hex>.successor`.
  - `changes/<change id>/`: `request.json` (the canonical request), `blobs/<sha256>` (verified
    bytes) and, once sealed, `revision`. Older changes also keep `change.json` and `commit`.
  - `reviews/<review id>.json`: `{"request", "phase", "repository", "change_id", "revision",
    "location", "review_url"?}`, written before any remote effect. Phases: `pushing`, then
    `pushed`, then `open`; or `failed` when the review location already existed.
    Publications from before revision handles keep their `publications/<id>.json`.
  - `integrations/<integration id>.json`: `{"request", "phase", "repository", "target", …}`.
    Phases: `integrating`, then `integrated`; or the terminal `target_moved`, `conflicted` or
    `refused`.
  - `migration.json`: written by `AtlasCode.Migration`; Code starts only when it is complete
    and every older record has its counterpart.
  """
  require Record
  Record.defrecordp(:mod, Record.extract(:mod, from_lib: "inets/include/httpd.hrl"))

  # JSON bodies are bounded per endpoint; only blob uploads may reach @blob_bytes.
  @body_bytes 16 * 1024
  @change_bytes 1024 * 1024
  @blob_bytes 64 * 1024 * 1024
  @paths %{
    "/v1/health" => ~c"GET",
    "/v1/references/resolve" => ~c"POST",
    "/v1/snapshots" => ~c"POST",
    "/v1/changes" => ~c"POST",
    "/v1/reviews" => ~c"POST",
    "/v1/integrations" => ~c"POST"
  }
  @git_config [
    "-c",
    "credential.helper=",
    "-c",
    "credential.helper=!gh auth git-credential",
    "-c",
    "core.hooksPath=/dev/null"
  ]
  @ustar_size 0o77777777777

  @doc "Starts the HTTP server for `home`; returns its pid and bound port."
  def start(home) do
    settings = open!(home)

    started =
      try do
        :inets.start(:httpd,
          port: settings.port,
          bind_address: {127, 0, 0, 1},
          server_name: ~c"atlas-code",
          server_root: String.to_charlist(settings.home),
          document_root: String.to_charlist(settings.home),
          modules: [__MODULE__],
          max_body_size: @blob_bytes,
          # Bodies over one chunk reach `do/1` in pieces, so the token and the per-endpoint
          # limit are checked before more than 64 KiB is buffered.
          max_client_body_chunk: 64 * 1024,
          atlas_code: Map.drop(settings, [:port, :owner])
        )
      rescue
        error ->
          release(settings.home, settings.owner)
          reraise error, __STACKTRACE__
      end

    case started do
      {:ok, pid} ->
        :persistent_term.put({__MODULE__, pid}, {settings.home, settings.owner})
        {:ok, pid, :httpd.info(pid)[:port]}

      {:error, reason} ->
        release(settings.home, settings.owner)
        raise "Code cannot serve #{settings.home}: #{inspect(reason)}"
    end
  end

  @doc """
  Stops the server and only then gives up the home. A server that does not report stopping
  keeps the home owned; `{:error, reason}` says why.
  """
  def stop(pid) do
    ref = Process.monitor(pid)
    result = :inets.stop(:httpd, pid)

    stopped =
      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> true
      after
        10_000 -> false
      end

    case {result, stopped, :persistent_term.get({__MODULE__, pid}, nil)} do
      {:ok, true, {home, owner}} ->
        :persistent_term.erase({__MODULE__, pid})

        case release(home, owner) do
          {:ok, _tombstone} -> :ok
          error -> error
        end

      {:ok, true, nil} ->
        {:error, :not_owner}

      {:ok, false, _} ->
        Process.demonitor(ref, [:flush])
        {:error, :still_running}

      {error, _, _} ->
        Process.demonitor(ref, [:flush])
        error
    end
  end

  @doc false
  # Validates the home, takes its ownership and refuses records that predate revision
  # handles. Only the digests of the tokens are kept, for constant-time comparisons.
  def open!(home) do
    home = Path.expand(home)
    config = home |> Path.join("config.json") |> File.read!() |> JSON.decode!()
    port = config["port"]
    repositories = config["repositories"]

    unless is_integer(port) and port in 0..65_535,
      do: raise("config.json port must be an integer from 0 to 65535")

    unless is_map(repositories) and
             Enum.all?(repositories, fn {name, url} ->
               name != "" and is_binary(url) and url != ""
             end),
           do: raise("config.json repositories must map repository names to Git remotes")

    token = token!(Path.join(home, "runtime.token"))
    gh = Map.get(config, "gh", "gh")

    unless is_binary(gh) and gh != "",
      do: raise("config.json gh must be the path or name of the gh executable")

    orchestrator =
      case File.lstat(Path.join(home, "orchestrator.token")) do
        {:error, :enoent} -> nil
        _ -> token!(Path.join(home, "orchestrator.token"))
      end

    if orchestrator == token, do: raise("orchestrator.token must differ from runtime.token")
    owner = lock!(home, "service")

    try do
      case AtlasCode.Migration.pending(home) do
        [] ->
          :ok

        pending ->
          raise "#{home} has records from before revision handles (#{Enum.join(Enum.take(pending, 3), ", ")}); stop Code and run mix atlas_code.migrate"
      end
    rescue
      error ->
        release(home, owner)
        reraise error, __STACKTRACE__
    end

    %{
      port: port,
      token: :crypto.hash(:sha256, token),
      orchestrator: orchestrator && :crypto.hash(:sha256, orchestrator),
      repositories: repositories,
      home: home,
      gh: gh,
      owner: owner
    }
  end

  defp token!(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} when Bitwise.band(mode, 0o077) == 0 ->
        token = path |> File.read!() |> String.trim()
        if token == "", do: raise("#{path} is empty")
        token

      _ ->
        raise "#{path} must be an owner-only (0600) regular file"
    end
  end

  @doc false
  # Makes `<home>/service.owner/` this process's: a directory staged with its `owner.json` and
  # renamed into place, which fails while any owner directory is there. Nothing but `release/2`
  # or `unlock/3` removes it, so neither a crash nor a dying process frees a home in use.
  # Returns the random owner ID.
  def lock!(home, kind) do
    owner = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    staging = Path.join(home, "service.owner.#{owner}.tmp")
    File.mkdir!(staging)

    record = %{
      "kind" => kind,
      "node" => to_string(node()),
      "os_pid" => String.to_integer(System.pid()),
      "owner" => owner,
      "started_at" => DateTime.to_iso8601(DateTime.utc_now())
    }

    File.write!(Path.join(staging, "owner.json"), JSON.encode!(record))

    case File.rename(staging, Path.join(home, "service.owner")) do
      :ok ->
        owner

      {:error, reason} ->
        File.rm_rf!(staging)

        case owner_record(home) do
          {:ok, %{"kind" => kind, "os_pid" => pid, "node" => node, "started_at" => at, "owner" => current}} ->
            raise "#{home} is owned by #{kind} pid #{pid} on #{node} since #{at} (owner #{current}); if that process has stopped, run ATLAS_CODE_HOME=#{home} mix atlas_code.unlock --owner #{current}"

          _ ->
            raise "#{home} cannot be owned: #{Path.join(home, "service.owner")} is unreadable or invalid (#{reason})"
        end
    end
  end

  @doc false
  # Ends `owner`'s ownership by renaming the owner directory to its tombstone, which is never
  # removed. A second release of the same owner, whether concurrent or late, finds the
  # tombstone there and moves nothing, even when a newer owner now holds the home.
  def release(home, owner) do
    case owner_record(home) do
      {:ok, %{"owner" => ^owner}} -> retire(home, owner)
      _ -> {:error, :not_owner}
    end
  end

  @doc false
  # Operator recovery of an owner that has stopped without releasing, after a crash, SIGKILL or
  # Ctrl-C. Refused unless `ps` reports the recorded PID absent: a running PID, and any answer
  # other than ps's documented ones, keep the home owned.
  # shortcut: a stale owner whose PID was reused by an unrelated process cannot be recovered
  # here; after checking that no Code or migration uses the home, the operator renames
  # service.owner to service.owner.ended-<owner> by hand. Upgrade to an OS-held lock that the
  # kernel releases with the BEAM itself if stale owners become routine.
  def unlock(home, owner, ps \\ "ps") do
    home = Path.expand(home)

    case owner_record(home) do
      :none ->
        {:ok, :not_owned}

      {:ok, %{"owner" => ^owner, "os_pid" => pid}} when is_integer(pid) and pid > 0 ->
        case running(ps, pid) do
          :absent ->
            with {:ok, tombstone} <- retire(home, owner), do: {:ok, {:recovered, tombstone}}

          :running ->
            {:error, "pid #{pid} of owner #{owner} is still running; stop it, then repeat"}

          :unknown ->
            {:error, "cannot establish that pid #{pid} has stopped; nothing was moved"}
        end

      {:ok, %{"owner" => ^owner}} ->
        {:error, "the owner record of #{owner} has no valid pid; nothing was moved"}

      {:ok, %{"owner" => current}} ->
        {:error, "#{home} is owned by #{current}, not #{owner}; nothing was moved"}

      _ ->
        {:error, "#{Path.join(home, "service.owner")} is unreadable or invalid; nothing was moved"}
    end
  end

  defp owner_record(home) do
    dir = Path.join(home, "service.owner")

    case File.read(Path.join(dir, "owner.json")) do
      {:ok, json} ->
        case JSON.decode(json) do
          {:ok, %{"owner" => owner} = record} when is_binary(owner) -> {:ok, record}
          _ -> :invalid
        end

      {:error, :enoent} ->
        if File.exists?(dir), do: :invalid, else: :none

      {:error, _} ->
        :invalid
    end
  end

  # The rename fails when the tombstone exists, so it happens once per owner.
  defp retire(home, owner) do
    tombstone = Path.join(home, "service.owner.ended-" <> owner)

    case File.rename(Path.join(home, "service.owner"), tombstone) do
      :ok -> {:ok, tombstone}
      {:error, reason} -> {:error, reason}
    end
  end

  # `ps -p PID -o pid=` prints the PID and exits 0 when it runs, and prints nothing and exits 1
  # when it does not. A restricted ps gives that same empty answer for every PID, so absence
  # counts only after the same ps reports this process and PID 1 (another user's) running.
  # Any other answer, stderr included, or ps failing to run, is unknown.
  defp running(ps, pid) do
    own = String.to_integer(System.pid())

    with executable when is_binary(executable) <- ps && System.find_executable(ps),
         :running <- ps(executable, own),
         :running <- ps(executable, 1) do
      if pid == own, do: :running, else: ps(executable, pid)
    else
      _ -> :unknown
    end
  end

  defp ps(executable, pid) do
    case System.cmd(executable, ["-p", Integer.to_string(pid), "-o", "pid="], stderr_to_stdout: true) do
      {output, 0} -> if String.trim(output) == Integer.to_string(pid), do: :running, else: :unknown
      {"", 1} -> :absent
      _ -> :unknown
    end
  rescue
    _ -> :unknown
  end

  @doc false
  # httpd callback: one JSON response per request, never logging headers or the token.
  # With `max_client_body_chunk` the body arrives as `{:first, chunk}`, `{:continue, chunk,
  # state}`… and finally `{:last, chunk, state}`; a body within one chunk is `{:last, body, :undefined}`.
  def unquote(:do)(request) do
    case mod(request, :entity_body) do
      {:first, chunk} -> {:continue, receive_body(request, :undefined, chunk)}
      {:continue, chunk, state} -> {:continue, receive_body(request, state, chunk)}
      {:last, chunk, state} -> respond(request, receive_body(request, state, chunk))
    end
  end

  defp receive_body(request, :undefined, chunk) do
    settings = :httpd_util.lookup(mod(request, :config_db), :atlas_code)

    if role = role(mod(request, :parsed_header), settings) do
      path = request |> mod(:request_uri) |> to_string() |> String.split("?") |> hd()

      limit =
        cond do
          mod(request, :method) == ~c"PUT" and String.starts_with?(path, "/v1/changes/") ->
            @blob_bytes

          path == "/v1/changes" ->
            @change_bytes

          true ->
            @body_bytes
        end

      receive_body(request, {:ok, role, limit, ""}, chunk)
    else
      {:error, error(401, "unauthorized", "Missing or wrong bearer token")}
    end
  end

  defp receive_body(_request, {:ok, _role, limit, body}, chunk)
       when byte_size(body) + byte_size(chunk) > limit,
       do: {:error, error(413, "payload_too_large", "The body exceeds #{limit} bytes")}

  defp receive_body(_request, {:ok, role, limit, body}, chunk), do: {:ok, role, limit, body <> chunk}
  defp receive_body(_request, {:error, _} = rejected, _chunk), do: rejected

  defp respond(request, body) do
    settings = :httpd_util.lookup(mod(request, :config_db), :atlas_code)
    [path | query] = request |> mod(:request_uri) |> to_string() |> String.split("?", parts: 2)

    response =
      case body do
        {:ok, role, _limit, body} ->
          route(mod(request, :method), path, Enum.join(query), body, Map.put(settings, :role, role))

        {:error, response} -> response
      end

    case response do
      {:tar, size, send} ->
        headers = [
          code: 200,
          content_type: ~c"application/x-tar",
          content_length: Integer.to_charlist(size)
        ]

        {:proceed, [response: {:response, headers, {send, [request]}}]}

      {status, body} ->
        json = JSON.encode!(body)

        headers = [
          code: status,
          content_type: ~c"application/json",
          content_length: Integer.to_charlist(byte_size(json))
        ]

        {:proceed, [response: {:response, headers, [json]}]}
    end
  end

  defp role(headers, %{token: runtime, orchestrator: orchestrator}) do
    case List.keyfind(headers, ~c"authorization", 0) do
      {_, ~c"Bearer " ++ token} ->
        digest = :crypto.hash(:sha256, :erlang.list_to_binary(token))

        cond do
          orchestrator && :crypto.hash_equals(orchestrator, digest) -> :orchestrator
          :crypto.hash_equals(runtime, digest) -> :runtime
          true -> nil
        end

      _ ->
        nil
    end
  end

  defp route(~c"GET", "/v1/health", _query, _body, _settings),
    do:
      {200,
       %{"service" => "atlas-code", "version" => to_string(Application.spec(:atlas_code, :vsn))}}

  defp route(~c"POST", "/v1/references/resolve", _query, body, settings) do
    case JSON.decode(body) do
      {:ok, %{"repository" => repository, "reference" => reference} = request}
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
        error(400, "invalid_request", "Body must be {\"repository\": string, \"reference\": string}")
    end
  end

  defp route(~c"POST", "/v1/snapshots", _query, body, settings) do
    with {:ok, %{"repositories" => [_ | _] = list} = request} when map_size(request) == 1 <-
           JSON.decode(body),
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
      _ ->
        error(
          400,
          "invalid_request",
          ~s(Body must be {"repositories": [{"repository", "revision", "path"}, …]})
        )
    end
  end

  defp route(~c"GET", "/v1/snapshots/" <> rest, query, _body, settings) do
    case String.split(rest, "/") do
      [id, "manifest"] ->
        with {:ok, id, manifest} <- manifest(settings.home, id),
             do: {200, Map.put(manifest, "snapshot_id", id)}

      [id, "archive"] ->
        archive(settings, id, URI.decode_query(query)["path"])

      _ ->
        error(404, "not_found", "Unknown path")
    end
  end

  defp route(~c"POST", "/v1/changes", _query, body, settings) do
    with {:ok,
          %{
            "change_id" => id,
            "snapshot_id" => snapshot_id,
            "repository" => repository,
            "base_revision" => base,
            "entries" => [_ | _] = entries
          } = request}
         when map_size(request) == 5 and is_binary(id) and is_binary(snapshot_id) and
                is_binary(repository) and is_binary(base) <- JSON.decode(body) do
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
          create(settings, %{request | "entries" => Enum.sort_by(entries, & &1["path"])})
      end
    else
      _ ->
        error(
          400,
          "invalid_request",
          ~s(Body must be {"change_id", "snapshot_id", "repository", "base_revision", "entries": [{"path", "op", …}, …]})
        )
    end
  end

  defp route(~c"PUT", "/v1/changes/" <> rest, _query, body, settings) do
    case String.split(rest, "/") do
      [id, "blobs", digest] -> locked_change(settings, id, &upload(&1, &2, digest, body))
      _ -> error(404, "not_found", "Unknown path")
    end
  end

  defp route(~c"POST", "/v1/changes/" <> rest, _query, _body, settings) do
    case String.split(rest, "/") do
      [id, "seal"] -> locked_change(settings, id, &seal(settings, &1, &2))
      _ -> error(404, "not_found", "Unknown path")
    end
  end

  defp route(~c"POST", path, _query, body, settings)
       when path in ["/v1/reviews", "/v1/integrations"] do
    cond do
      settings.orchestrator == nil ->
        error(403, "forbidden", "Reviews and integrations are not configured")

      settings.role != :orchestrator ->
        error(403, "forbidden", "Reviews and integrations require the orchestrator token")

      path == "/v1/reviews" ->
        with {:ok, request} <- review_request(body), do: review(settings, request)

      true ->
        with {:ok, request} <- integration_request(body), do: integrate(settings, request)
    end
  end

  defp route(_method, path, _query, _body, _settings) do
    if Map.has_key?(@paths, path),
      do: error(405, "method_not_allowed", "Use #{@paths[path]} for #{path}"),
      else: error(404, "not_found", "Unknown path")
  end

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

  @doc false
  def handle(repository, commit),
    do: "rev_" <> sha256(["atlas-code/revision/1", 0, repository, 0, commit])

  @doc false
  # The mapping is published before any reply carries the handle, so it survives a restart.
  def put_revision(home, repository, commit) do
    handle = handle(repository, commit)

    publish!(
      Path.join([home, "revisions", handle <> ".json"]),
      JSON.encode!(%{"commit" => commit, "repository" => repository})
    )

    handle
  end

  # The commit behind a handle of `repository`; handles of other repositories are refused.
  defp revision(home, repository, handle) do
    case File.read(Path.join([home, "revisions", handle <> ".json"])) do
      {:ok, json} ->
        %{"commit" => commit, "repository" => owner} = JSON.decode!(json)
        unless handle(owner, commit) == handle, do: raise("revisions/#{handle}.json does not match its name")

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
      Enum.reduce_while(repositories, [], fn %{"repository" => repository, "revision" => handle} = item,
                                             acc ->
        with {:ok, commit} <- revision(settings.home, repository, handle),
             {:ok, dir} <- acquire(settings, repository, commit, handle) do
          {:cont, [{dir, %{"repository" => repository, "commit" => commit, "path" => item["path"]}} | acc]}
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

    error(409, "snapshot_superseded", "The snapshot predates revision handles; use its successor", %{
      "snapshot_id" => id,
      "successor" => successor
    })
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

      {:tar, size, fn request -> send_tar(request, dir, members) end}
    end
  end

  # Streams one blob at a time: memory stays at one pipe chunk plus the member headers.
  defp send_tar(request, dir, members) do
    deliver = fn data ->
      :ok = :httpd_socket.deliver(mod(request, :socket_type), mod(request, :socket), data)
    end

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
  defp entry?(
         %{"op" => "write", "kind" => "symlink", "mode" => "120000", "path" => path} = entry
       )
       when map_size(entry) == 7 and is_binary(path) and is_binary(:erlang.map_get("target", entry)),
       do: entry["size"] == byte_size(entry["target"]) and entry["sha256"] == sha256(entry["target"])

  defp entry?(_entry), do: false

  defp locked(key, fun), do: :global.trans({{__MODULE__, key}, self()}, fun, [node()])

  @doc false
  def write_atomic(file, data) do
    temporary = "#{file}.#{System.unique_integer([:positive])}.tmp"
    File.write!(temporary, data)
    File.rename!(temporary, file)
  end

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

      directories = for path <- tree, directory <- ancestors(path), into: MapSet.new(), do: directory

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
        error(409, "base_mismatch", "base_revision is not the repository's revision in the snapshot", %{
          "repository" => repository,
          "base_revision" => base,
          "revision" => revision
        })
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
        error(422, "incomplete_upload", "Upload every blob before sealing", %{"missing" => missing})

      {200, %{"state" => "open"}} ->
        with {:ok, base} <- revision(settings.home, repository, handle),
             {:ok, git_dir} <- acquire(settings, repository, base, handle),
             {:ok, commit} <- locked(git_dir, fn -> commit(git_dir, dir, base, request) end) do
          write_atomic(Path.join(dir, "revision"), put_revision(settings.home, repository, commit))
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
      {deletes, writes} = Enum.split_with(entries, &(&1["op"] == "delete"))
      digests = writes |> Enum.map(& &1["sha256"]) |> Enum.uniq()

      # Chunks of 500 keep each command line far below the OS argument limit.
      oids =
        for chunk <- Enum.chunk_every(digests, 500),
            oid <-
              String.split(
                run.(["hash-object", "-w", "--no-filters", "--" | Enum.map(chunk, &("blobs/" <> &1))]),
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
          | Enum.flat_map(chunk, &["--cacheinfo", "#{&1["mode"]},#{oid[&1["sha256"]]},#{&1["path"]}"])
        ])
      end

      tree = run.(["write-tree"])
      commit = run.(["commit-tree", "--no-gpg-sign", "-p", base, "-m", "Atlas change #{id}", tree])

      case claim(git_dir, "refs/atlas/changes/" <> id, commit) do
        :ok -> {:ok, commit}
        :taken -> error(409, "conflict", "The change is sealed differently in Code's cache", %{"change_id" => id})
      end
    after
      File.rm(index)
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
    case System.cmd("git", ["--git-dir", git_dir, "update-ref", ref, commit, ""], stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      _ ->
        {current, 0} = System.cmd("git", ["--git-dir", git_dir, "rev-parse", "--verify", ref])
        if String.trim(current) == commit, do: :ok, else: :taken
    end
  end

  defp review_request(body) do
    case JSON.decode(body) do
      {:ok,
       %{"review_id" => id, "change_id" => change, "target" => target, "title" => title, "body" => text} =
           request}
      when map_size(request) == 5 and is_binary(id) and is_binary(change) and is_binary(target) and
             is_binary(title) and is_binary(text) ->
        cond do
          not uuid?(id) ->
            error(400, "invalid_request", "review_id must be a lowercase UUID")

          not uuid?(change) ->
            error(400, "invalid_request", "change_id must be a lowercase UUID")

          not branch?(target) ->
            error(400, "invalid_request", "target must be a valid reference name")

          String.trim(title) == "" or String.length(title) > 256 or
              String.contains?(title, ["\n", "\r"]) ->
            error(400, "invalid_request", "title must be one non-empty line of at most 256 characters")

          not String.contains?(text, "Written by an AI agent") ->
            error(400, "invalid_request", ~s(body must carry the attribution "Written by an AI agent"))

          true ->
            {:ok, request}
        end

      _ ->
        error(
          400,
          "invalid_request",
          ~s(Body must be {"review_id", "change_id", "target", "title", "body"})
        )
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
        %{"repository" => repository} = JSON.decode!(json)
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

        if claimed,
          do: location_taken(),
          else:
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

      slug =
        Regex.run(~r{\Ahttps://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+?)(?:\.git)?\z}, url,
          capture: :all_but_first
        )

      if commit?(dir, commit),
        do: {:ok, %{url: url, dir: dir, slug: slug && hd(slug), commit: commit}},
        else:
          error(409, "conflict", "The sealed revision is not in Code's cache for the configured remote", %{
            "revision" => handle
          })
    end
  end

  defp advance(settings, file, record, target, first) do
    with {:ok, record} <- push(file, record, target, first),
         {:ok, record} <- pull_request(settings.gh, file, record, target),
         do: reviewed(save(file, %{record | "phase" => "open"}))
  end

  defp push(_file, %{"phase" => "pushed"} = record, _target, _first), do: {:ok, record}

  defp push(file, %{"location" => location} = record, %{url: url, dir: dir, commit: commit}, first) do
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
            ["--git-dir", dir, "push", "--porcelain", "--force-with-lease=#{ref}:", url, "#{commit}:#{ref}"]

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
              [_ | _] -> failed(file, record)
              _ -> error(503, "provider_unavailable", "git push was refused with exit status #{status}")
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
    do: error(409, "location_taken", "The review location already exists or is claimed; Code never overwrites it")

  # An existing pull request for the location is one an earlier attempt created before its
  # response was lost, so it is adopted rather than duplicated. gh output is never returned.
  defp pull_request(_gh, _file, record, %{slug: nil}), do: {:ok, record}

  # Publications without a pull request were migrated without a target: nothing to open.
  defp pull_request(_gh, _file, %{"request" => %{"target" => nil}} = record, _target), do: {:ok, record}

  defp pull_request(gh, file, %{"request" => request, "location" => location} = record, %{slug: slug}) do
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
        case run.(["pr", "list", "--repo=" <> slug, "--head=" <> location, "--state", "all", "--json", "url"]) do
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
        error(502, "review_incomplete", "The review is pushed but its pull request is not created; repeat the request", %{
          "phase" => "pushed"
        })
  end

  defp create_pull_request(run, file, slug, location, %{"target" => base, "title" => title, "body" => body}) do
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

  defp integration_request(body) do
    case JSON.decode(body) do
      {:ok,
       %{"integration_id" => id, "review_id" => review, "revision" => revision, "target_revision" => target} =
           request}
      when map_size(request) == 4 and is_binary(id) and is_binary(review) ->
        cond do
          not uuid?(id) ->
            error(400, "invalid_request", "integration_id must be a lowercase UUID")

          not uuid?(review) ->
            error(400, "invalid_request", "review_id must be a lowercase UUID")

          not (revision?(revision) and revision?(target)) ->
            error(400, "invalid_request", "revision and target_revision must be rev_<64 lowercase hex characters>")

          true ->
            {:ok, request}
        end

      _ ->
        error(
          400,
          "invalid_request",
          ~s(Body must be {"integration_id", "review_id", "revision", "target_revision"})
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
              with {:ok, context} <- context(settings, record), do: land(file, record, context, false)

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
            error(409, "review_not_open", "Only an open review can be integrated", %{"review_id" => review_id})

          review["request"]["target"] == nil ->
            error(409, "review_has_no_target", "The review has no target; open a new review of the change", %{
              "review_id" => review_id
            })

          review["revision"] != revision ->
            error(409, "revision_mismatch", "revision is not the review's revision", %{
              "review_id" => review_id,
              "revision" => review["revision"]
            })

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
       %{home: settings.home, url: url, dir: cache(settings.home, repository, url), change: change, expected: expected}}
    end
  end

  defp prepare(file, %{"target" => target} = record, %{url: url, dir: dir, expected: expected} = context) do
    case ls_remote(["--git-dir", dir], url, "refs/heads/" <> target) do
      [^expected] ->
        case locked(dir, fn -> fetch(dir, url, expected) end) do
          :ok -> candidate(file, record, context)
          :missing -> moved(file, record, context, ls_remote(["--git-dir", dir], url, "refs/heads/" <> target))
          {:failed, status} -> error(503, "provider_unavailable", "git fetch failed with exit status #{status}")
        end

      current ->
        moved(file, record, context, current)
    end
  end

  defp candidate(file, record, %{dir: dir, change: change, expected: expected} = context) do
    id = record["request"]["integration_id"]

    cond do
      ancestor?(dir, change, expected) ->
        result = %{"phase" => "integrated", "method" => "already_integrated", "result" => record["request"]["target_revision"]}
        outcome(save(file, Map.merge(record, result)))

      ancestor?(dir, expected, change) ->
        land(file, candidate!(file, record, dir, change, "fast_forward"), context, true)

      true ->
        case merge(dir, expected, change, id) do
          {:ok, merged} -> land(file, candidate!(file, record, dir, merged, "merge"), context, true)
          {:conflict, paths} -> outcome(save(file, Map.merge(record, %{"phase" => "conflicted", "paths" => paths})))
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
    args = ["--git-dir", dir, "merge-tree", "--write-tree", "--name-only", "--no-messages", "-z", target, change]

    case System.cmd("git", ["-c", "core.hooksPath=/dev/null" | args]) do
      {output, 0} ->
        [tree | _] = :binary.split(output, <<0>>, [:global, :trim_all])

        {merged, 0} =
          System.cmd(
            "git",
            ["--git-dir", dir, "commit-tree", "--no-gpg-sign", "-p", target, "-p", change, "-m", "Atlas integration #{id}", tree],
            env: identity(dir, target)
          )

        {:ok, String.trim(merged)}

      {output, 1} ->
        [_tree | paths] = :binary.split(output, <<0>>, [:global, :trim_all])
        {:conflict, paths |> Enum.map(&String.replace_invalid/1) |> Enum.uniq() |> Enum.sort()}
    end
  end

  defp ancestor?(dir, ancestor, commit) do
    case System.cmd("git", ["--git-dir", dir, "merge-base", "--is-ancestor", ancestor, commit], stderr_to_stdout: true) do
      {_, 0} -> true
      {_, 1} -> false
    end
  end

  # Pushes the recorded candidate. A first attempt has just seen the target at
  # target_revision; a repeat asks the remote, since an earlier push may have landed.
  defp land(file, %{"target" => target, "candidate" => candidate} = record, %{url: url, dir: dir, expected: expected} = context, first) do
    ref = "refs/heads/" <> target

    case if(first, do: [expected], else: ls_remote(["--git-dir", dir], url, ref)) do
      [^candidate] ->
        landed(file, record, context)

      [^expected] ->
        args =
          @git_config ++
            ["--git-dir", dir, "push", "--porcelain", "--force-with-lease=#{ref}:#{expected}", url, "#{candidate}:#{ref}"]

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
              [^candidate] -> landed(file, record, context)
              [^expected] -> outcome(save(file, %{record | "phase" => "refused"}))
              {:failed, _} -> error(503, "provider_unavailable", "git push was refused with exit status #{status}")
              current -> reconcile(file, record, context, current)
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

  defp landed(file, %{"repository" => repository, "candidate" => candidate} = record, %{home: home}),
    do: outcome(save(file, Map.merge(record, %{"phase" => "integrated", "result" => put_revision(home, repository, candidate)})))

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
      error(409, "target_moved", "The target is not at target_revision; resolve it again and use a new integration_id", %{
        "target" => record["target"],
        "current" => record["current"]
      })

  defp outcome(%{"phase" => "conflicted"} = record),
    do:
      error(409, "integration_conflict", "The review conflicts with the target; the target was not changed", %{
        "target" => record["target"],
        "paths" => record["paths"]
      })

  defp outcome(%{"phase" => "refused"} = record),
    do:
      error(409, "integration_refused", "The remote refused to update the target, for example by branch policy; Code never bypasses it", %{
        "target" => record["target"]
      })

  defp save(file, record) do
    write_atomic(file, JSON.encode!(record))
    record
  end

  @doc false
  # Atomic create-if-absent; an existing file must already hold exactly `data`.
  def publish!(file, data) do
    case File.read(file) do
      {:ok, ^data} ->
        :ok

      {:ok, _other} ->
        raise "#{file} exists with other content"

      {:error, :enoent} ->
        File.mkdir_p!(Path.dirname(file))
        write_atomic(file, data)
    end
  end

  @doc false
  def sha256(data), do: Base.encode16(:crypto.hash(:sha256, data), case: :lower)

  defp error(status, code, message, details \\ %{}),
    do: {status, %{"error" => %{"code" => code, "message" => message, "details" => details}}}
end
