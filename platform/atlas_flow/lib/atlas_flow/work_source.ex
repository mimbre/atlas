defmodule AtlasFlow.WorkSource do
  @moduledoc """
  Flow as the Runtime's work source (decision 2026-11-17 §5.1–§5.3; plan m3 §3.1): the
  source's capabilities in the terms of the Runtime's `work_source` contract (M1). A
  Runtime is the caller; `client` is `{runtime_id, holder}`, from its credential
  (`authenticate/2`), never from the request. Inputs are the contract's models (atom or
  string keys); outcomes are tagged:

  | Capability   | Outcomes                                                           |
  |--------------|--------------------------------------------------------------------|
  | `poll/2`     | `{:polled, %{leases, cancel, lease_lost, timing, configuration?}}`, `{:rejected, :invalid}` |
  | `report/2`   | `{:recorded, %{missing}}`, `:lease_lost`, `{:rejected, :conflict \\| :invalid}`, `:unavailable` |
  | `get_blob/2` | `{:blob, %{sha256, size, content}}`, `:not_found`, `{:rejected, :invalid}` |

  `poll` goes to `AtlasFlow.Dispatch`, the only granter; `report` to `AtlasFlow.Delivery`.
  `get_blob` streams, in the caller's process, a blob of the lease's base that Delivery
  scoped, from Code through `AtlasFlow.Bases`. A result never comes back as blobs: it
  travels over Git (`refs/atlas/results/<task>`), so there is no `put_blob` (IS-Atlas-100).

  `get_blob` has no `lease_lost`: a fenced lease, another Runtime's lease and a name the
  lease's input does not name all answer `not_found` (rev 4, R1).

  `:unavailable` is no outcome of the contract: Facts did not answer (`AtlasFlow.Delivery`).
  The router answers it 503, which a Runtime takes as unreachable and sends again.

  `opts`: `dispatch`, `delivery` and `bases` (their servers; the defaults are the named
  processes).
  """

  alias AtlasFlow.{Bases, Delivery, Dispatch}
  alias AtlasFlow.WorkSource.{Credentials, Translate}

  @type client :: Credentials.client()

  @doc "The client a bearer token stands for: `{:ok, client}` or `:unauthenticated`."
  def authenticate(credentials, token), do: Credentials.lookup(credentials, token)

  @doc """
  `poll`: renew holdings, grant leases within the offer, name cancels and lost leases; and
  the Runtime's configuration (IS-Atlas-27, `AtlasFlow.WorkSource.Configuration`), recorded
  first and served in the answer while the Runtime runs another version.
  """
  def poll(client, input, opts \\ []) do
    configuration = Delivery.configuration(client, input, Keyword.get(opts, :delivery, Delivery))

    case {Dispatch.poll(client, input, Keyword.get(opts, :dispatch, Dispatch)), configuration} do
      {{:polled, polled}, {:serve, document}} ->
        {:polled, Map.put(polled, :configuration, document)}

      {answer, _} ->
        answer
    end
  end

  @doc "`report`: a state change of a lease."
  def report(client, input, opts \\ []),
    do: Delivery.report(client, input, Keyword.get(opts, :delivery, Delivery))

  @doc "`get_blob`: a blob the current lease's input names, to its own Runtime."
  def get_blob(client, input, opts \\ []) do
    delivery = Keyword.get(opts, :delivery, Delivery)

    case Translate.normal(input) do
      %{"lease_id" => lease_id, "sha256" => sha} when is_binary(lease_id) and is_binary(sha) ->
        case Delivery.blob_scope(client, lease_id, sha, delivery) do
          {:base, snapshot_id} when is_binary(snapshot_id) ->
            blob(sha, Bases.blob(sha, snapshot_id, Keyword.get(opts, :bases, Bases)))

          _ ->
            :not_found
        end

      _ ->
        {:rejected, :invalid}
    end
  end

  defp blob(sha, {:ok, size, content}), do: {:blob, %{sha256: sha, size: size, content: content}}
  defp blob(_sha, _not_found_or_unavailable), do: :not_found
end
