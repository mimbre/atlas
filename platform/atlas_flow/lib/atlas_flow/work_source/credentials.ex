defmodule AtlasFlow.WorkSource.Credentials do
  @moduledoc """
  The per-Runtime credentials of the work source (decision 2026-11-17 §3 protection 3,
  §5.6 "Credentials"; plan m3 §3.6): `%{runtime_id => %{holder, token_sha256}}`, from a
  core secret. The holder is the supervisor key whose work that Runtime may take; it comes
  from here only, never from a request.

  The secret is JSON, `{"<runtime_id>": {"holder": "<supervisor key>", "token_sha256":
  "<64 lowercase hex>"}}`, held in the environment variable `config :atlas_flow,
  :work_source, credentials_env:` names. No token is kept: only its sha256.

  `lookup/2` hashes the bearer token and compares it with every entry in constant time
  (`:crypto.hash_equals/2`, and no early exit), so the time it takes does not tell how
  much of a token matched or which Runtime it was.
  """

  @sha ~r/\A[0-9a-f]{64}\z/

  @type t :: %{String.t() => %{holder: String.t(), token_sha256: String.t()}}
  @type client :: {runtime_id :: String.t(), holder :: String.t()}

  @doc "Parses the secret's JSON: `{:ok, credentials}` or `{:error, :invalid}`."
  @spec parse(String.t()) :: {:ok, t()} | {:error, :invalid}
  def parse(json) when is_binary(json) do
    with {:ok, %{} = map} <- JSON.decode(json),
         entries when is_list(entries) <- Enum.map(map, &entry/1),
         false <- Enum.member?(entries, :error) do
      {:ok, Map.new(entries)}
    else
      _ -> {:error, :invalid}
    end
  end

  def parse(_), do: {:error, :invalid}

  defp entry({runtime_id, %{"holder" => holder, "token_sha256" => sha}})
       when is_binary(runtime_id) and runtime_id != "" and is_binary(holder) and holder != "" and
              is_binary(sha) do
    if Regex.match?(@sha, sha),
      do: {runtime_id, %{holder: holder, token_sha256: sha}},
      else: :error
  end

  defp entry(_), do: :error

  @doc """
  The credentials of the configured environment variable: `{:ok, credentials}`, or
  `{:error, :unset | :invalid}`.
  """
  @spec load() :: {:ok, t()} | {:error, :unset | :invalid}
  def load do
    with name when is_binary(name) <-
           Keyword.get(Application.get_env(:atlas_flow, :work_source, []), :credentials_env),
         json when is_binary(json) <- System.get_env(name) do
      parse(json)
    else
      _ -> {:error, :unset}
    end
  end

  @doc """
  The client a bearer token stands for: `{:ok, {runtime_id, holder}}`, or
  `:unauthenticated` for an unknown, empty or missing token.
  """
  @spec lookup(t(), term()) :: {:ok, client()} | :unauthenticated
  def lookup(credentials, token) when is_map(credentials) and is_binary(token) and token != "" do
    hash = :crypto.hash(:sha256, token)

    found =
      Enum.reduce(credentials, nil, fn {runtime_id, %{token_sha256: sha} = entry}, found ->
        same = :crypto.hash_equals(hash, decode(sha))
        if same and found == nil, do: {runtime_id, entry.holder}, else: found
      end)

    if found, do: {:ok, found}, else: :unauthenticated
  end

  def lookup(_credentials, _token), do: :unauthenticated

  @doc "The sha256 of a token, as the secret holds it (64 lowercase hex)."
  @spec token_sha256(String.t()) :: String.t()
  def token_sha256(token), do: Base.encode16(:crypto.hash(:sha256, token), case: :lower)

  defp decode(sha), do: Base.decode16!(sha, case: :lower)
end
