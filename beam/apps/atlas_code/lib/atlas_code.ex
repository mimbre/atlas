defmodule AtlasCode do
  @moduledoc """
  Local Code service: `GET /v1/health`, `POST /v1/revisions/resolve`, `POST /v1/snapshots`,
  `GET /v1/snapshots/{id}/manifest` and `GET /v1/snapshots/{id}/archive?path=…` on
  127.0.0.1 over OTP `:inets` httpd. Every request, health included, needs
  `Authorization: Bearer <runtime token>`.

  The home directory holds:
  - `config.json`: `{"port": N, "repositories": {"github.com/owner/repo": "<git remote URL or path>"}}`.
    The keys are the only repository names the API accepts.
  - `runtime.token`: the bearer token, an owner-only (0600) regular file.
  - `cache/<sha256 of name and remote>.git`: Code's private bare clone per repository.
  - `snapshots/<hex>.json`: the canonical manifest whose SHA-256 is the snapshot ID.
  """
  require Record
  Record.defrecordp(:mod, Record.extract(:mod, from_lib: "inets/include/httpd.hrl"))

  @body_bytes 16 * 1024
  @paths %{
    "/v1/health" => ~c"GET",
    "/v1/revisions/resolve" => ~c"POST",
    "/v1/snapshots" => ~c"POST"
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

    {:ok, pid} =
      :inets.start(:httpd,
        port: port,
        bind_address: {127, 0, 0, 1},
        server_name: ~c"atlas-code",
        server_root: String.to_charlist(home),
        document_root: String.to_charlist(home),
        modules: [__MODULE__],
        max_body_size: @body_bytes,
        # Only the token's digest is kept, for a constant-time comparison.
        atlas_code: %{token: :crypto.hash(:sha256, token), repositories: repositories, home: home}
      )

    {:ok, pid, :httpd.info(pid)[:port]}
  end

  def stop(pid), do: :inets.stop(:httpd, pid)

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
  # httpd callback: one JSON response per request, never logging headers or the token.
  def unquote(:do)(request) do
    settings = :httpd_util.lookup(mod(request, :config_db), :atlas_code)
    [path | query] = request |> mod(:request_uri) |> to_string() |> String.split("?", parts: 2)

    response =
      if authorized?(mod(request, :parsed_header), settings.token) do
        body = :erlang.list_to_binary(mod(request, :entity_body))
        route(mod(request, :method), path, Enum.join(query), body, settings)
      else
        error(401, "unauthorized", "Missing or wrong bearer token")
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

  defp authorized?(headers, digest) do
    case List.keyfind(headers, ~c"authorization", 0) do
      {_, ~c"Bearer " ++ token} ->
        :crypto.hash_equals(digest, :crypto.hash(:sha256, :erlang.list_to_binary(token)))

      _ ->
        false
    end
  end

  defp route(~c"GET", "/v1/health", _query, _body, _settings),
    do:
      {200,
       %{"service" => "atlas-code", "version" => to_string(Application.spec(:atlas_code, :vsn))}}

  defp route(~c"POST", "/v1/revisions/resolve", _query, body, %{repositories: repositories}) do
    case JSON.decode(body) do
      {:ok, %{"repository" => repository, "ref" => ref} = request}
      when map_size(request) == 2 and is_binary(repository) and is_binary(ref) ->
        cond do
          not Map.has_key?(repositories, repository) ->
            error(403, "forbidden", "Repository is not allowed", %{"repository" => repository})

          not branch?(ref) ->
            error(400, "invalid_request", "ref must be a valid branch name")

          true ->
            resolve(repository, Map.fetch!(repositories, repository), ref)
        end

      _ ->
        error(400, "invalid_request", "Body must be {\"repository\": string, \"ref\": string}")
    end
  end

  defp route(~c"POST", "/v1/snapshots", _query, body, settings) do
    with {:ok, %{"repositories" => [_ | _] = list} = request} when map_size(request) == 1 <-
           JSON.decode(body),
         true <-
           Enum.all?(list, fn item ->
             match?(
               %{"repository" => r, "commit" => c, "path" => p}
               when is_binary(r) and is_binary(c) and is_binary(p),
               item
             ) and
               map_size(item) == 3
           end) do
      cond do
        bad = Enum.find(list, &(not sha?(&1["commit"]))) ->
          error(400, "invalid_request", "commit must be 40 or 64 lowercase hex characters", %{
            "commit" => bad["commit"]
          })

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
          ~s(Body must be {"repositories": [{"repository", "commit", "path"}, …]})
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

  defp resolve(repository, url, ref) do
    name = "refs/heads/" <> ref

    # Git output is never returned: it may echo the remote URL or credential prompts.
    case System.cmd("git", @git_config ++ ["ls-remote", "--exit-code", url, name],
           env: [{"GIT_TERMINAL_PROMPT", "0"}],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        matches =
          for line <- String.split(output, "\n"),
              [commit, ^name] <- [String.split(line, "\t")],
              sha?(commit),
              do: commit

        case matches do
          [commit] ->
            {200, %{"repository" => repository, "ref" => ref, "commit" => commit}}

          [] ->
            error(404, "unknown_ref", "Branch not found", %{
              "repository" => repository,
              "ref" => ref
            })

          _ ->
            error(503, "provider_unavailable", "Git returned an ambiguous reference")
        end

      {_, 2} ->
        error(404, "unknown_ref", "Branch not found", %{"repository" => repository, "ref" => ref})

      {_, status} ->
        error(503, "provider_unavailable", "git ls-remote failed with exit status #{status}")
    end
  end

  defp snapshot(repositories, settings) do
    repositories = Enum.map(repositories, &Map.take(&1, ["commit", "path", "repository"]))

    acquired =
      Enum.reduce_while(repositories, [], fn repository, acc ->
        case acquire(settings, repository) do
          {:ok, dir} -> {:cont, [{repository, dir} | acc]}
          response -> {:halt, response}
        end
      end)

    with [_ | _] <- acquired do
      results = Enum.flat_map(acquired, fn {repository, dir} -> entries(dir, repository) end)

      case for({:refused, entry} <- results, do: entry) do
        [] ->
          # Elixir encodes maps of up to 32 keys in sorted key order, so this JSON is canonical.
          manifest =
            JSON.encode!(%{
              "entries" =>
                results |> Enum.map(fn {:ok, entry} -> entry end) |> Enum.sort_by(& &1["path"]),
              "repositories" => repositories
            })

          hex = sha256(manifest)
          file = Path.join([settings.home, "snapshots", hex <> ".json"])

          unless File.exists?(file) do
            File.mkdir_p!(Path.dirname(file))
            temporary = "#{file}.#{System.unique_integer([:positive])}.tmp"
            File.write!(temporary, manifest)
            File.rename!(temporary, file)
          end

          {200, %{"snapshot_id" => "sha256:" <> hex, "repositories" => repositories}}

        refused ->
          error(422, "unsupported_content", "The repository content cannot be snapshotted", %{
            "entries" => refused
          })
      end
    end
  end

  defp acquire(%{home: home, repositories: allowed}, %{
         "repository" => repository,
         "commit" => commit
       }) do
    case allowed do
      %{^repository => url} ->
        dir = Path.join([home, "cache", sha256([repository, 0, url]) <> ".git"])

        case :global.trans({{__MODULE__, dir}, self()}, fn -> fetch(dir, url, commit) end, [
               node()
             ]) do
          :ok ->
            {:ok, dir}

          :missing ->
            error(404, "not_found", "Commit not found", %{
              "repository" => repository,
              "commit" => commit
            })

          {:failed, status} ->
            error(503, "provider_unavailable", "git fetch failed with exit status #{status}")
        end

      _ ->
        error(403, "forbidden", "Repository is not allowed", %{"repository" => repository})
    end
  end

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
          {:ok, manifest} ->
            {:ok, id, JSON.decode!(manifest)}

          {:error, :enoent} ->
            error(404, "not_found", "Snapshot not found", %{"snapshot_id" => id})
        end

      _ ->
        error(400, "invalid_request", "snapshot id must be sha256:<64 lowercase hex characters>")
    end
  end

  # Archive members are named relative to the repository root, not prefixed by its snapshot path.
  defp archive(settings, id, path) do
    with {:ok, _id, manifest} <- manifest(settings.home, id),
         %{} = repository <-
           Enum.find(manifest["repositories"], &(&1["path"] == path)) ||
             error(404, "not_found", "Path is not in the snapshot", %{"path" => path}),
         {:ok, dir} <- acquire(settings, repository) do
      oids =
        Map.new(tree(dir, repository["commit"]), fn {_mode, oid, _size, file} -> {file, oid} end)

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

  defp sha256(data), do: Base.encode16(:crypto.hash(:sha256, data), case: :lower)

  defp error(status, code, message, details \\ %{}),
    do: {status, %{"error" => %{"code" => code, "message" => message, "details" => details}}}
end
