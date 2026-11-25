defmodule AtlasFlow.WorkSource.Registered do
  @moduledoc """
  The work source credentials registered in Facts (IS-Atlas-116, UC-Atlas-50): those a
  supervisor made through Control when installing a Runtime (`atlas runtime install`),
  next to the core secret's (`AtlasFlow.WorkSource.Credentials.load/0`). So a new Runtime
  is admitted without a core secret or a restart.

  A machinery fact (`Model.Machinery`) whose `credential_sha256` is 64 lowercase hex and
  whose `runs_for` links one person is the credential `%{key => %{holder: person,
  token_sha256: sha}}`: the Runtime's id is the machinery's key, its holder the person.
  Nothing else is read; a fact without either is no credential. Only the hash is ever in
  Facts.

  The credentials are read from Facts at most once per `ttl` (10 s) and kept in a public
  ETS table this process owns; the caller reads them in its own process, so a slow Facts
  never holds up another request. While Facts does not answer, the last credentials
  read stay (a Runtime already admitted is not turned away by a Facts restart); before
  any were read, there are none. Clearing a machinery's `credential_sha256`, or deleting
  it, turns its Runtime away within `ttl`.

  `credentials/1` serves Flow's listener (`AtlasFlow.Backend.Listener`) and `digests/1`
  Code's Git endpoint (`AtlasCode.Git`, through `config :atlas_code, :git`'s `registered`).
  Options of `start_link/1`: `name` (default this module), `ttl` (ms) and `read` (a
  `Talk.read/2`-like function, for tests).
  """
  use GenServer

  alias AtlasFlow.Talk

  @kind "machinery"
  @sha "credential_sha256"
  @holder "runs_for"
  @ttl 10_000
  @sha_pattern ~r/\A[0-9a-f]{64}\z/

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.put(opts, :name, name), name: name)
  end

  @impl true
  def init(opts) do
    table = :ets.new(Keyword.fetch!(opts, :name), [:named_table, :public, read_concurrency: true])

    :ets.insert(
      table,
      {:settings, Keyword.get(opts, :read, &Talk.read/2), Keyword.get(opts, :ttl, @ttl)}
    )

    {:ok, table}
  end

  @doc """
  The registered credentials (`AtlasFlow.WorkSource.Credentials.t()`): read again when
  older than the ttl. `%{}` when the table `name` is not running.
  """
  @spec credentials(atom()) :: AtlasFlow.WorkSource.Credentials.t()
  def credentials(name \\ __MODULE__) do
    [{:settings, read, ttl}] = :ets.lookup(name, :settings)
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(name, :credentials) do
      [{:credentials, at, credentials}] when now - at < ttl ->
        credentials

      held ->
        credentials =
          case fetch(read) do
            {:ok, credentials} -> credentials
            :unavailable -> with([{:credentials, _at, kept}] <- held, do: kept, else: (_ -> %{}))
          end

        :ets.insert(name, {:credentials, now, credentials})
        credentials
    end
  rescue
    ArgumentError -> %{}
  end

  @doc "The registered token digests (raw 32 bytes), for Code's Git endpoint."
  @spec digests(atom()) :: [binary()]
  def digests(name \\ __MODULE__) do
    for {_runtime, %{token_sha256: sha}} <- credentials(name),
        do: Base.decode16!(sha, case: :lower)
  end

  @doc "The credentials the machinery facts `facts` (Facts' wire form) stand for."
  @spec from_facts([map()]) :: AtlasFlow.WorkSource.Credentials.t()
  def from_facts(facts) when is_list(facts) do
    for %{"key" => key} = fact <- facts,
        is_binary(key) and key != "",
        sha = (fact["values"] || %{})[@sha],
        is_binary(sha) and Regex.match?(@sha_pattern, sha),
        [holder] <- [List.wrap((fact["links"] || %{})[@holder])],
        is_binary(holder) and holder != "",
        into: %{},
        do: {key, %{holder: holder, token_sha256: sha}}
  end

  defp fetch(read) do
    case read.(@kind, %{"linked" => %{}, "plain" => true}) do
      %{"facts" => facts} when is_list(facts) -> {:ok, from_facts(facts)}
      _ -> :unavailable
    end
  catch
    _, _ -> :unavailable
  end
end
