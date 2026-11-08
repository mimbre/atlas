defmodule AtlasRuntime.Workspaces.Code do
  @moduledoc """
  Client for the local Code service. A managed start asks Code for the exact base commit
  before anything is cloned or launched; there is no local fallback.

  Configuration is `code.json` in the Runtime state directory, because the CLI strips
  `ATLAS_*` variables from the daemon: `{"url": "http://127.0.0.1:PORT", "token_file": "/abs/path"}`.
  """

  @sha ~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/

  @doc "The commit Code resolves for `ref` of a normalized `https://github.com/owner/repo.git` URL."
  def resolve!(dir, url, ref) do
    repository = url |> String.replace_prefix("https://", "") |> String.replace_suffix(".git", "")
    {base, token} = config!(dir)
    body = JSON.encode!(%{"repository" => repository, "ref" => ref})
    headers = [{~c"authorization", String.to_charlist("Bearer " <> token)}]
    request = {String.to_charlist(base <> "/v1/revisions/resolve"), headers, ~c"application/json", body}

    # Plain loopback HTTP: an explicit empty ssl option keeps httpc from loading :public_key defaults.
    case :httpc.request(:post, request, [timeout: 15_000, connect_timeout: 2_000, autoredirect: false, ssl: []],
           body_format: :binary) do
      {:ok, {{_, 200, _}, _, reply}} ->
        case JSON.decode(reply) do
          {:ok, %{"repository" => ^repository, "ref" => ^ref, "commit" => commit}} when is_binary(commit) ->
            if Regex.match?(@sha, commit), do: commit, else: unavailable!("invalid commit in reply")
          _ -> unavailable!("invalid reply")
        end

      {:ok, {{_, status, _}, _, reply}} ->
        case JSON.decode(reply) do
          {:ok, %{"error" => %{"code" => code, "message" => message}}} when is_binary(code) and is_binary(message) ->
            raise "Code refused #{ref} of #{repository}: #{status} #{code}: #{message}"
          _ -> unavailable!("HTTP #{status}")
        end

      {:error, reason} ->
        unavailable!(inspect(reason))
    end
  end

  defp config!(dir) do
    path = Path.join(dir, "code.json")

    bytes =
      case File.read(path) do
        {:ok, bytes} -> bytes
        {:error, :enoent} -> unavailable!("not configured; write #{path}")
        {:error, reason} -> unavailable!("cannot read #{path}: #{:file.format_error(reason)}")
      end

    with {:ok, %{"url" => url, "token_file" => file}} when is_binary(url) and is_binary(file) <- JSON.decode(bytes),
         # The bearer token only ever goes to loopback.
         true <- Regex.match?(~r/\Ahttp:\/\/127\.0\.0\.1:[1-9][0-9]{0,4}\z/, url),
         true <- Path.type(file) == :absolute do
      case File.read(file) do
        {:ok, token} ->
          token = String.trim(token)
          if token == "", do: unavailable!("empty token file #{file}")
          {url, token}

        {:error, reason} ->
          unavailable!("cannot read token file #{file}: #{:file.format_error(reason)}")
      end
    else
      _ -> unavailable!("#{path} must be {\"url\": \"http://127.0.0.1:PORT\", \"token_file\": \"/absolute/path\"}")
    end
  end

  defp unavailable!(why), do: raise("Code service unavailable: #{why}")
end
