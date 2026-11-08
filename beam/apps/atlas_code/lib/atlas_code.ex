defmodule AtlasCode do
  @moduledoc """
  Local Code service, step 2: `GET /v1/health` and `POST /v1/revisions/resolve` on
  127.0.0.1 over OTP `:inets` httpd. Every request, health included, needs
  `Authorization: Bearer <runtime token>`.

  The home directory holds:
  - `config.json`: `{"port": N, "repositories": {"github.com/owner/repo": "<git remote URL or path>"}}`.
    The keys are the only repository names the API accepts.
  - `runtime.token`: the bearer token, an owner-only (0600) regular file.
  """
  require Record
  Record.defrecordp(:mod, Record.extract(:mod, from_lib: "inets/include/httpd.hrl"))

  @body_bytes 16 * 1024
  @paths %{"/v1/health" => ~c"GET", "/v1/revisions/resolve" => ~c"POST"}

  @doc "Starts the HTTP server for `home`; returns its pid and bound port."
  def start(home) do
    home = Path.expand(home)
    config = home |> Path.join("config.json") |> File.read!() |> JSON.decode!()
    port = config["port"]
    repositories = config["repositories"]

    unless is_integer(port) and port in 0..65_535,
      do: raise("config.json port must be an integer from 0 to 65535")

    unless is_map(repositories) and
             Enum.all?(repositories, fn {name, url} -> name != "" and is_binary(url) and url != "" end),
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
        atlas_code: %{token: :crypto.hash(:sha256, token), repositories: repositories}
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
    path = request |> mod(:request_uri) |> to_string() |> String.split("?", parts: 2) |> hd()

    {status, body} =
      if authorized?(mod(request, :parsed_header), settings.token) do
        route(mod(request, :method), path, mod(request, :entity_body), settings.repositories)
      else
        error(401, "unauthorized", "Missing or wrong bearer token")
      end

    json = JSON.encode!(body)
    headers = [code: status, content_type: ~c"application/json", content_length: Integer.to_charlist(byte_size(json))]
    {:proceed, [response: {:response, headers, [json]}]}
  end

  defp authorized?(headers, digest) do
    case List.keyfind(headers, ~c"authorization", 0) do
      {_, ~c"Bearer " ++ token} -> :crypto.hash_equals(digest, :crypto.hash(:sha256, :erlang.list_to_binary(token)))
      _ -> false
    end
  end

  defp route(~c"GET", "/v1/health", _body, _repositories),
    do: {200, %{"service" => "atlas-code", "version" => to_string(Application.spec(:atlas_code, :vsn))}}

  defp route(~c"POST", "/v1/revisions/resolve", body, repositories) do
    case JSON.decode(:erlang.list_to_binary(body)) do
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

  defp route(_method, path, _body, _repositories) do
    if Map.has_key?(@paths, path),
      do: error(405, "method_not_allowed", "Use #{@paths[path]} for #{path}"),
      else: error(404, "not_found", "Unknown path")
  end

  defp branch?(ref) do
    String.valid?(ref) and not String.contains?(ref, <<0>>) and
      match?({output, 0} when output == ref <> "\n",
        System.cmd("git", ["check-ref-format", "--branch", ref], stderr_to_stdout: true))
  end

  defp resolve(repository, url, ref) do
    name = "refs/heads/" <> ref

    args =
      ["-c", "credential.helper=", "-c", "credential.helper=!gh auth git-credential", "-c", "core.hooksPath=/dev/null"] ++
        ["ls-remote", "--exit-code", url, name]

    # Git output is never returned: it may echo the remote URL or credential prompts.
    case System.cmd("git", args, env: [{"GIT_TERMINAL_PROMPT", "0"}], stderr_to_stdout: true) do
      {output, 0} ->
        matches =
          for line <- String.split(output, "\n"),
              [commit, ^name] <- [String.split(line, "\t")],
              Regex.match?(~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/, commit),
              do: commit

        case matches do
          [commit] -> {200, %{"repository" => repository, "ref" => ref, "commit" => commit}}
          [] -> error(404, "unknown_ref", "Branch not found", %{"repository" => repository, "ref" => ref})
          _ -> error(503, "provider_unavailable", "Git returned an ambiguous reference")
        end

      {_, 2} ->
        error(404, "unknown_ref", "Branch not found", %{"repository" => repository, "ref" => ref})

      {_, status} ->
        error(503, "provider_unavailable", "git ls-remote failed with exit status #{status}")
    end
  end

  defp error(status, code, message, details \\ %{}),
    do: {status, %{"error" => %{"code" => code, "message" => message, "details" => details}}}
end
