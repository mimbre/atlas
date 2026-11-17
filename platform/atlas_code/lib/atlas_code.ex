defmodule AtlasCode do
  @moduledoc """
  Local Code service: `GET /v1/health`, `POST /v1/references/resolve`, `POST /v1/snapshots`,
  `GET /v1/snapshots/{id}/manifest`, `GET /v1/snapshots/{id}/archive?path=…`,
  `POST /v1/changes`, `PUT /v1/changes/{id}/blobs/{sha256}`, `POST /v1/changes/{id}/seal`,
  `POST /v1/reviews`, `POST /v1/review-updates` and `POST /v1/integrations` on 127.0.0.1 over
  OTP `:inets` httpd. Every request, health included, needs `Authorization: Bearer <token>`: the
  runtime token or the orchestrator token. Only the orchestrator token may review, update a
  review or integrate.

  The core runs something else from this app: `AtlasCode.Effects`, Code's receiver of
  Flow's integrate effect, on the Bus. This service never starts it.

  What each route does is `AtlasCode.Service`'s, a function of the started instance's
  settings; this module is the transport, the home's ownership and the instance. Callers in
  the same BEAM use the boundary facade `AtlasCode.Boundary` (contract
  `AtlasCodeBoundary.Code`), which reaches the instance started with `register: true`
  through `settings/0`.

  Clients see repository names, reference names, `sha256:` snapshot IDs, opaque
  `rev_<64 hex>` revision handles and their own UUIDs. Commits, branches, refs, remote URLs and
  Git output stay inside Code; Git is its only backend.

  The home directory holds:
  - `config.json`: `{"port": N, "repositories": {"github.com/owner/repo": <remote>},
    "gh"?: "<gh executable>"}`. A remote is `"<git remote URL or path>"`, or
    `{"url": "<git remote URL or path>", "credentials": "none"}` for a repository Code reads
    anonymously: its resolves and fetches run Git with no credential helper at all (a public
    repository, e.g. on a host without gh). Its pushes are unchanged. The repository keys are
    the only names the API accepts; `gh` defaults to `gh` on PATH.
  - `runtime.token`: the bearer token, an owner-only (0600) regular file.
  - `orchestrator.token` (optional): the reviewing token, same file rules, different from
    `runtime.token`. Without it Code starts and refuses every review and integration.
  - `service.lock`: the OS lock (`AtlasCode.Lock`, an exclusive `flock`) that every owner
    holds for as long as it owns the home; the kernel drops it when the owner's BEAM ends,
    however it ends. Never removed.
  - `service.owner/owner.json`: `{"kind", "owner", "os_pid", "node", "started_at", "lock"}`
    of the service or `mix atlas_code.migrate` that owns the home; while it exists nothing
    else may. Releasing renames it to `service.owner.ended-<owner>`, which is kept. After a
    crash, SIGKILL, OOM or Ctrl-C it stays; an owner written with `"lock": "flock"` is then
    recovered by the next start or migration as soon as it takes `service.lock`, which proves
    that owner gone, without `ps` and whatever PID the new process has. An older owner
    without `"lock"` (a Code from before the OS lock, e.g. still running during an upgrade)
    is honoured as before: the next `start/2` recovers it, through the same check and
    tombstone as `unlock/3`, only when `ps` proves the recorded PID gone; while it runs, or
    `ps` cannot tell, start is refused and `mix atlas_code.unlock --owner <owner>` is the
    manual recovery.
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
    "location", "review_url"?, "ready"?}`, written before any remote effect. Phases: `pushing`, then
    `pushed`, then `open`; or `failed` when the review location already existed. The location is
    `work/review-<id>`, or `work/flow-review-<id>` for a draft (Flow merges those itself, through
    `integrate`). `ready` is `mark_ready`'s journal: `asked` before `gh pr ready`, `marked` after.
    An update moves `revision` and `change_id` to its own and appends its ID to `"updates"`.
    Publications from before revision handles keep their `publications/<id>.json`.
  - `review-updates/<update id>.json`: `{"request", "phase", "review_id", "change_id",
    "previous_revision", "revision", …}`, written before the push. Phases: `pushing`, then
    `updated`; or the terminal `refused` (with `"code"`) when the location moved or the remote
    refused. The pushed commit keeps the private ref `refs/atlas/updates/<update id>`.
  - `integrations/<integration id>.json`: `{"request", "phase", "repository", "target", …}`.
    Phases: `integrating`, then `integrated`; or the terminal `target_moved`, `conflicted` or
    `refused`.
  - `migration.json`: written by `AtlasCode.Migration`; Code starts only when it is complete
    and every older record has its counterpart.
  """
  require Logger
  require Record
  Record.defrecordp(:mod, Record.extract(:mod, from_lib: "inets/include/httpd.hrl"))

  alias AtlasCode.{Boundary, Service}
  alias AtlasCode.Boundary.Outcome
  alias AtlasCodeBoundary.Generator.InvalidInput

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
    "/v1/review-updates" => ~c"POST",
    "/v1/integrations" => ~c"POST"
  }
  # The facade's outcomes as HTTP responses: success answers 200 with the outcome's fields;
  # a refusal answers its status with the outcome's name as the error code.
  @answers [Outcome.Resolved, Outcome.Created, Outcome.Manifest, Outcome.Change]
  # A review's link is its pull request's `review_url` on the wire.
  @reviews [Outcome.Review, Outcome.Updated]
  @problems %{
    Outcome.InvalidRequest => {400, "invalid_request"},
    Outcome.Forbidden => {403, "forbidden"},
    Outcome.UnknownReference => {404, "unknown_reference"},
    Outcome.UnknownRevision => {404, "unknown_revision"},
    Outcome.NotFound => {404, "not_found"},
    Outcome.RepositoryMismatch => {409, "repository_mismatch"},
    Outcome.SnapshotSuperseded => {409, "snapshot_superseded"},
    Outcome.UnsupportedContent => {422, "unsupported_content"},
    Outcome.ProviderUnavailable => {503, "provider_unavailable"},
    Outcome.Conflict => {409, "conflict"},
    Outcome.BaseMismatch => {409, "base_mismatch"},
    Outcome.IncompleteUpload => {422, "incomplete_upload"},
    Outcome.ChangeNotSealed => {409, "change_not_sealed"},
    Outcome.FingerprintMismatch => {409, "fingerprint_mismatch"},
    Outcome.LocationTaken => {409, "location_taken"},
    Outcome.ReviewIncomplete => {502, "review_incomplete"},
    Outcome.ReviewNotOpen => {409, "review_not_open"},
    Outcome.RevisionMismatch => {409, "revision_mismatch"},
    Outcome.UpdateRefused => {409, "update_refused"}
  }

  @doc """
  Starts the HTTP server for `home`; returns its pid and bound port. An owner left by a
  stopped process is recovered first (see `unlock/3`). `ps:` names the ps executable used for
  that check, `"ps"` by default.

  `register: true` also registers the instance under the name `AtlasCode` in this BEAM, so
  that `settings/0` (and with it the facade `AtlasCode.Boundary`) reaches it, until it stops
  or its server goes down. Only one instance can be registered: while another is, start
  stops the new server, gives up its home and raises.
  """
  def start(home, opts \\ []) do
    settings = open!(home, opts)

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
          atlas_code: served(settings)
        )
      rescue
        error ->
          release(settings.home, settings.owner)
          reraise error, __STACKTRACE__
      end

    case started do
      {:ok, pid} ->
        :persistent_term.put({__MODULE__, pid}, {settings.home, settings.owner})
        # The home's OS lock now lives exactly as long as its server.
        :ok = AtlasCode.Lock.watch(lock_of(settings), pid)
        if Keyword.get(opts, :register, false), do: register!(pid, settings)
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
    # A registered instance is unregistered first: the facade stops reaching it before it
    # stops serving.
    case :persistent_term.get({__MODULE__, :instance, pid}, nil) do
      nil ->
        :ok

      instance ->
        AtlasCode.Instance.stop(instance)
        :persistent_term.erase({__MODULE__, :instance, pid})
    end

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

  @doc """
  The settings of the Code instance registered in this BEAM (`start/2` with
  `register: true`): its home (which it owns through `lock!/3`), its allowed repositories,
  its token digests and `gh`, as its HTTP routes use them. Raises when no instance is
  registered, or the registered one has stopped.
  """
  def settings, do: AtlasCode.Instance.settings(__MODULE__)

  # What a route receives and the facade acts on: the settings without what only the server
  # and the home's release need.
  defp served(settings), do: Map.drop(settings, [:port, :owner])

  defp register!(pid, settings) do
    case AtlasCode.Instance.start(__MODULE__, pid, served(settings)) do
      {:ok, instance} ->
        :persistent_term.put({__MODULE__, :instance, pid}, instance)

      {:error, reason} ->
        stop(pid)

        raise "Code cannot register #{settings.home} as #{inspect(__MODULE__)}: #{inspect(reason)}"
    end
  end

  defp lock_of(%{home: home, owner: owner}),
    do: :persistent_term.get({AtlasCode.Lock, home, owner})

  @doc false
  # The largest blob a change may write; also the largest body the server takes.
  def blob_bytes, do: @blob_bytes

  @doc false
  # Validates the home, takes its ownership and refuses records that predate revision
  # handles. Only the digests of the tokens are kept, for constant-time comparisons.
  def open!(home, opts \\ []) do
    home = Path.expand(home)
    config = home |> Path.join("config.json") |> File.read!() |> JSON.decode!()
    port = config["port"]

    unless is_integer(port) and port in 0..65_535,
      do: raise("config.json port must be an integer from 0 to 65535")

    {repositories, anonymous} = repositories!(config["repositories"])

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
    owner = lock!(home, "service", Keyword.get(opts, :ps, "ps"))

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
      anonymous: anonymous,
      home: home,
      gh: gh,
      owner: owner
    }
  end

  # The remote of each repository, and the names read without credentials.
  defp repositories!(repositories) do
    remotes =
      is_map(repositories) &&
        Enum.map(repositories, fn
          {name, url} when name != "" and is_binary(url) and url != "" ->
            {name, url, false}

          {name, %{"url" => url, "credentials" => "none"} = entry}
          when name != "" and is_binary(url) and url != "" and map_size(entry) == 2 ->
            {name, url, true}

          _ ->
            nil
        end)

    unless remotes && Enum.all?(remotes),
      do:
        raise(
          ~s(config.json repositories must map repository names to Git remotes or {"url": remote, "credentials": "none"})
        )

    {Map.new(remotes, fn {name, url, _} -> {name, url} end),
     MapSet.new(for {name, _, true} <- remotes, do: name)}
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
  # Makes `<home>/service.owner/` this process's. First the OS lock `service.lock`
  # (`AtlasCode.Lock`), held until `release/2` or until the process it watches (the caller,
  # then the server `start/2` makes it watch) ends, or this BEAM does. Then a directory staged
  # with its `owner.json` is renamed into place, which fails while any owner directory is
  # there. Nothing but `release/2` or `unlock/3` removes that directory, so neither a crash nor
  # a dying process frees it; the OS lock tells whether its owner is still there:
  # - an owner written with the lock (`"lock": "flock"`) whose lock this process could take
  #   has ended, so it is retired to its tombstone and the rename tried once more;
  # - an older owner, from a Code before the OS lock, is honoured as before: with `ps`
  #   (service start) it is offered to `unlock/3`, and retired only when that ps proves the
  #   recorded PID gone.
  # Returns the random owner ID.
  def lock!(home, kind, ps \\ nil) do
    owner = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    staging = Path.join(home, "service.owner.#{owner}.tmp")
    File.mkdir!(staging)

    record = %{
      "kind" => kind,
      "lock" => "flock",
      "node" => to_string(node()),
      "os_pid" => String.to_integer(System.pid()),
      "owner" => owner,
      "started_at" => DateTime.to_iso8601(DateTime.utc_now())
    }

    File.write!(Path.join(staging, "owner.json"), JSON.encode!(record))

    taken =
      case os_lock(home, 20) do
        {:ok, lock} ->
          case take_owner(home, staging, ps) do
            :ok ->
              :persistent_term.put({AtlasCode.Lock, home, owner}, lock)
              :ok

            {:error, reason} ->
              AtlasCode.Lock.release(lock)
              {:error, reason}
          end

        :busy ->
          {:error, :locked}

        {:error, reason} ->
          File.rm_rf!(staging)

          raise "#{home} cannot be owned: #{AtlasCode.Lock.path(home)} cannot be locked (#{inspect(reason)})"
      end

    case taken do
      :ok ->
        owner

      {:error, reason} ->
        File.rm_rf!(staging)

        case owner_record(home) do
          {:ok,
           %{
             "kind" => kind,
             "os_pid" => pid,
             "node" => node,
             "started_at" => at,
             "owner" => current
           }} ->
            raise "#{home} is owned by #{kind} pid #{pid} on #{node} since #{at} (owner #{current}); if that process has stopped, run ATLAS_CODE_HOME=#{home} mix atlas_code.unlock --owner #{current}"

          _ ->
            raise "#{home} cannot be owned: #{Path.join(home, "service.owner")} is unreadable or invalid (#{reason})"
        end
    end
  end

  # The OS lock, retried for up to `tries` tenths of a second while it is busy but no owner
  # record can be read yet: the holder is between taking it and renaming its owner into place,
  # or has just retired its owner and is about to drop it.
  defp os_lock(home, tries) do
    case AtlasCode.Lock.acquire(home) do
      :busy when tries > 0 ->
        case owner_record(home) do
          {:ok, _} ->
            :busy

          _ ->
            Process.sleep(100)
            os_lock(home, tries - 1)
        end

      result ->
        result
    end
  end

  # With the OS lock held, renames the staged owner into place. When an owner is there:
  # one written with the OS lock has ended (this process holds that lock), so it is retired
  # and the rename tried once more; an older one goes, when `ps` is given, through
  # `unlock/3`, the same check as the operator's, and a recovered (or meanwhile released)
  # owner allows one more rename.
  defp take_owner(home, staging, ps) do
    case File.rename(staging, Path.join(home, "service.owner")) do
      :ok ->
        :ok

      {:error, reason} ->
        case owner_record(home) do
          {:ok, %{"lock" => "flock", "owner" => stale} = record} ->
            with {:ok, tombstone} <- retire(home, stale) do
              Logger.warning(
                "Code recovered #{home} from stopped owner #{stale} (#{record["kind"]} pid #{record["os_pid"]} on #{record["node"]}; its lock was free); tombstone #{tombstone}"
              )

              rename_owner(home, staging)
            end

          _ when is_nil(ps) ->
            {:error, reason}

          _ ->
            pid_owner(home, staging, ps, reason)
        end
    end
  end

  defp rename_owner(home, staging), do: File.rename(staging, Path.join(home, "service.owner"))

  # An owner from before the OS lock: retired only when `ps` proves its PID gone.
  defp pid_owner(home, staging, ps, reason) do
    with {:ok, %{"owner" => stale} = record} <- owner_record(home),
         {:ok, recovered} <- unlock(home, stale, ps) do
      with {:recovered, tombstone} <- recovered do
        Logger.warning(
          "Code recovered #{home} from stopped owner #{stale} (#{record["kind"]} pid #{record["os_pid"]} on #{record["node"]}); tombstone #{tombstone}"
        )
      end

      rename_owner(home, staging)
    else
      _ -> {:error, reason}
    end
  end

  @doc false
  # Ends `owner`'s ownership by renaming the owner directory to its tombstone, which is never
  # removed, and only then drops its OS lock. A second release of the same owner, whether
  # concurrent or late, finds the tombstone there and moves nothing, even when a newer owner
  # now holds the home.
  def release(home, owner) do
    result =
      case owner_record(home) do
        {:ok, %{"owner" => ^owner}} -> retire(home, owner)
        _ -> {:error, :not_owner}
      end

    case :persistent_term.get({AtlasCode.Lock, home, owner}, nil) do
      nil ->
        :ok

      lock ->
        AtlasCode.Lock.release(lock)
        :persistent_term.erase({AtlasCode.Lock, home, owner})
    end

    result
  end

  @doc false
  # Recovery of an owner that has stopped without releasing, after a crash, SIGKILL or Ctrl-C:
  # by the operator, and by every service start before it gives up. An owner written with the
  # OS lock is retired only when this process can take that lock, which its owner holds for as
  # long as it runs. An older owner is retired only when `ps` reports the recorded PID absent:
  # a running PID, and any answer other than ps's documented ones, keep the home owned.
  # shortcut: an older (pre-OS-lock) stale owner whose PID was reused by an unrelated process
  # cannot be recovered here nor by a start, which refuses it as running; after checking that
  # no Code or migration uses the home, the operator renames service.owner to
  # service.owner.ended-<owner> by hand. Owners written since the OS lock never need this.
  def unlock(home, owner, ps \\ "ps") do
    home = Path.expand(home)

    case owner_record(home) do
      :none ->
        {:ok, :not_owned}

      {:ok, %{"owner" => ^owner, "lock" => "flock"} = record} ->
        case AtlasCode.Lock.acquire(home) do
          {:ok, lock} ->
            # Re-read with the lock held: only the owner read above is retired.
            result =
              case owner_record(home) do
                {:ok, %{"owner" => ^owner}} ->
                  with {:ok, tombstone} <- retire(home, owner),
                       do: {:ok, {:recovered, tombstone}}

                :none ->
                  {:ok, :not_owned}

                _ ->
                  {:error, "#{home} is no longer owned by #{owner}; nothing was moved"}
              end

            AtlasCode.Lock.release(lock)
            result

          :busy ->
            {:error,
             "pid #{record["os_pid"]} of owner #{owner} is still running (it holds #{AtlasCode.Lock.path(home)}); stop it, then repeat"}

          {:error, reason} ->
            {:error,
             "cannot lock #{AtlasCode.Lock.path(home)} (#{inspect(reason)}); nothing was moved"}
        end

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
        {:error,
         "#{Path.join(home, "service.owner")} is unreadable or invalid; nothing was moved"}
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
    case System.cmd(executable, ["-p", Integer.to_string(pid), "-o", "pid="],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        if String.trim(output) == Integer.to_string(pid), do: :running, else: :unknown

      {"", 1} ->
        :absent

      _ ->
        :unknown
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
      {:error, Service.error(401, "unauthorized", "Missing or wrong bearer token")}
    end
  end

  defp receive_body(_request, {:ok, _role, limit, body}, chunk)
       when byte_size(body) + byte_size(chunk) > limit,
       do: {:error, Service.error(413, "payload_too_large", "The body exceeds #{limit} bytes")}

  defp receive_body(_request, {:ok, role, limit, body}, chunk),
    do: {:ok, role, limit, body <> chunk}

  defp receive_body(_request, {:error, _} = rejected, _chunk), do: rejected

  defp respond(request, body) do
    settings = :httpd_util.lookup(mod(request, :config_db), :atlas_code)
    [path | query] = request |> mod(:request_uri) |> to_string() |> String.split("?", parts: 2)

    response =
      case body do
        {:ok, role, _limit, body} ->
          route(
            mod(request, :method),
            path,
            Enum.join(query),
            body,
            Map.put(settings, :role, role)
          )

        {:error, response} ->
          response
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

  # The routes: transport only. Each answers with what `AtlasCode.Service` answers for it;
  # every route the contract declares goes through the boundary facade (ADR 0006: backend →
  # boundary): resolve, snapshot, manifest, the changes and the reviews. Health, archive and
  # integrations call the Service directly. get_blob is the facade's only; no route serves it.
  # A route with a JSON body first runs the Service's own checks of it
  # (`Service.check_request/2`), so a body is refused as before the facade.
  defp route(~c"GET", "/v1/health", _query, _body, _settings), do: Service.health()

  defp route(~c"POST", "/v1/references/resolve", _query, body, settings),
    do:
      settings
      |> client()
      |> Boundary.resolve_reference(decode(body))
      |> reply(:resolve_reference)

  defp route(~c"POST", "/v1/snapshots", _query, body, settings),
    do: settings |> client() |> Boundary.create_snapshot(decode(body)) |> reply(:create_snapshot)

  defp route(~c"GET", "/v1/snapshots/" <> rest, query, _body, settings) do
    case String.split(rest, "/") do
      [id, "manifest"] ->
        settings
        |> client()
        |> Boundary.get_manifest(%{snapshot_id: id})
        |> reply(:get_manifest)

      [id, "archive"] ->
        case Service.get_archive(settings, id, URI.decode_query(query)["path"]) do
          {:tar, size, write} -> {:tar, size, fn request -> write.(&deliver(request, &1)) end}
          response -> response
        end

      _ ->
        Service.error(404, "not_found", "Unknown path")
    end
  end

  defp route(~c"POST", "/v1/changes", _query, body, settings),
    do: settings |> through(:create_change, decode(body), &Boundary.create_change/2)

  defp route(~c"PUT", "/v1/changes/" <> rest, _query, body, settings) do
    case String.split(rest, "/") do
      [id, "blobs", digest] ->
        settings
        |> client()
        |> Boundary.put_change_blob(%{change_id: id, sha256: digest, content: body})
        |> reply(:put_change_blob)

      _ ->
        Service.error(404, "not_found", "Unknown path")
    end
  end

  defp route(~c"POST", "/v1/changes/" <> rest, _query, _body, settings) do
    case String.split(rest, "/") do
      [id, "seal"] ->
        settings |> client() |> Boundary.seal_change(%{change_id: id}) |> reply(:seal_change)

      _ ->
        Service.error(404, "not_found", "Unknown path")
    end
  end

  defp route(~c"POST", path, _query, body, settings)
       when path in ["/v1/reviews", "/v1/review-updates", "/v1/integrations"] do
    cond do
      settings.orchestrator == nil ->
        Service.error(403, "forbidden", "Reviews and integrations are not configured")

      settings.role != :orchestrator ->
        Service.error(403, "forbidden", "Reviews and integrations require the orchestrator token")

      path == "/v1/reviews" ->
        through(settings, :create_review, decode(body), &Boundary.create_review/2)

      path == "/v1/review-updates" ->
        through(settings, :update_review, decode(body), &Boundary.update_review/2)

      true ->
        Service.create_integration(settings, decode(body))
    end
  end

  defp route(_method, path, _query, _body, _settings) do
    if Map.has_key?(@paths, path),
      do: Service.error(405, "method_not_allowed", "Use #{@paths[path]} for #{path}"),
      else: Service.error(404, "not_found", "Unknown path")
  end

  # The decoded body; nil for a body that is no JSON, which no request shape matches.
  defp decode(body) do
    case JSON.decode(body) do
      {:ok, request} -> request
      {:error, _} -> nil
    end
  end

  defp deliver(request, data),
    do: :ok = :httpd_socket.deliver(mod(request, :socket_type), mod(request, :socket), data)

  # A JSON body: the Service's own checks of it, then the facade.
  defp through(settings, capability, request, call) do
    with :ok <- Service.check_request(capability, request),
         do: settings |> client() |> call.(request) |> reply(capability)
  end

  # The routes call the facade on behalf of the instance that serves them, with its settings
  # (`AtlasCode.Running`). Both tokens may resolve, snapshot, read snapshots and make
  # changes; only the orchestrator token reviews (the route has checked it before).
  defp client(%{role: :orchestrator} = settings),
    do: {{__MODULE__, settings}, [:snapshot, :change, :review]}

  defp client(settings), do: {{__MODULE__, settings}, [:snapshot, :change]}

  # A facade answer as the HTTP response the Service gave: a declared outcome to its status
  # and body, and an input the contract refuses to the Service's refusal of that shape.
  defp reply(%InvalidInput{}, capability), do: Service.malformed(capability)

  defp reply(%module{} = outcome, _capability) when module in @answers,
    do: {200, module.dump(outcome)}

  defp reply(%module{} = outcome, _capability) when module in @reviews do
    {link, body} = Map.pop(module.dump(outcome), "link")
    {200, if(link, do: Map.put(body, "review_url", link), else: body)}
  end

  # A moved review location's details name where it is now, as null when it is gone.
  defp reply(%Outcome.LocationMoved{} = outcome, _capability) do
    {message, details} = Map.pop!(Outcome.LocationMoved.dump(outcome), "message")
    Service.error(409, "location_moved", message, Map.put_new(details, "current", nil))
  end

  # A superseded snapshot's details name its successor, as null when Code knows none.
  defp reply(%Outcome.SnapshotSuperseded{} = outcome, _capability) do
    {message, details} = Map.pop!(Outcome.SnapshotSuperseded.dump(outcome), "message")
    Service.error(409, "snapshot_superseded", message, Map.put_new(details, "successor", nil))
  end

  defp reply(%module{} = outcome, _capability) do
    {status, code} = Map.fetch!(@problems, module)
    {message, details} = Map.pop!(module.dump(outcome), "message")
    Service.error(status, code, message, details)
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

  @doc false
  def write_atomic(file, data) do
    temporary = "#{file}.#{System.unique_integer([:positive])}.tmp"
    File.write!(temporary, data)
    File.rename!(temporary, file)
  end

  # A repository fingerprint names a change's content apart from its ID: "fpr_" and the SHA-256
  # of the canonical JSON of its request without change_id, entries sorted by path. Runtime
  # computes the same bytes at submit (platform/atlas_runtime/host/snapshot/testdata/fingerprints.json).
  @doc false
  def fingerprint(request) do
    canonical =
      request
      |> Map.delete("change_id")
      |> Map.update!("entries", &Enum.sort_by(&1, fn entry -> entry["path"] end))
      |> JSON.encode!()

    "fpr_" <> sha256(canonical)
  end

  @doc false
  # The owner/repository of a GitHub remote, HTTPS or SSH, for gh; nil for any other remote,
  # which therefore gets no pull request.
  def github_slug(url) do
    case Regex.run(
           ~r{\A(?:https://github\.com/|git@github\.com:|ssh://git@github\.com/)([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+?)(?:\.git)?\z},
           url,
           capture: :all_but_first
         ) do
      [slug] -> slug
      nil -> nil
    end
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
end
