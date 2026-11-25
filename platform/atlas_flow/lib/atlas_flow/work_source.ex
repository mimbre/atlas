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
  | `put_blob/2` | `:stored`, `:lease_lost`, `:too_large`, `:not_referenced`, `{:rejected, :digest_mismatch \\| :invalid}`, `:unavailable` |

  `poll` goes to `AtlasFlow.Dispatch`, the only granter; `report` and the result upload to
  `AtlasFlow.Delivery`. A blob's bytes stream in the caller's process: `get_blob` streams
  what Delivery scoped (from Code through `AtlasFlow.Bases`, or from `AtlasFlow.Results`);
  `put_blob` streams into the result store after Delivery's checks (fence, then reference,
  then room), and Delivery fences again once the bytes are read and before they are kept.

  A change-set input's manifest is served from the result store as its stored canonical
  bytes, like any blob it names (F2).

  `get_blob` has no `lease_lost`: a fenced lease, another Runtime's lease and a name the
  lease's input does not name all answer `not_found` (rev 4, R1).

  `:unavailable` is no outcome of the contract: Facts did not answer (`AtlasFlow.Delivery`).
  The router answers it 503, which a Runtime takes as unreachable and sends again.

  `opts`: `dispatch`, `delivery`, `results` and `bases` (their servers; the defaults are
  the named processes).
  """

  alias AtlasFlow.{Bases, Delivery, Dispatch, Results}
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

          :result ->
            result_blob(sha, Keyword.get(opts, :results, Results))

          _ ->
            :not_found
        end

      _ ->
        {:rejected, :invalid}
    end
  end

  defp blob(sha, {:ok, size, content}), do: {:blob, %{sha256: sha, size: size, content: content}}
  defp blob(_sha, _not_found_or_unavailable), do: :not_found

  # A change-set input names its manifest and the blobs its write entries name (F2). The
  # store keeps a manifest as the canonical bytes of its change set, so those bytes are
  # served again, and only when they still hash to the name asked for.
  defp result_blob(sha, results) do
    with :not_found <- Results.blob(sha, results),
         {:ok, change_set} <- Results.manifest_by_sha(sha, results),
         bytes = Results.canonical(change_set),
         true <- sha256(bytes) == sha do
      blob(sha, {:ok, byte_size(bytes), [bytes]})
    else
      {:ok, _size, _content} = held -> blob(sha, held)
      _ -> :not_found
    end
  end

  defp sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  @doc """
  `put_blob`: one blob of the lease's recorded `ended` manifest. Checked before a byte is
  read (fence, reference, room), counted while it streams, fenced again before it is kept.
  """
  def put_blob(client, input, opts \\ []) do
    delivery = Keyword.get(opts, :delivery, Delivery)
    results = Keyword.get(opts, :results, Results)

    with {:ok, lease_id, sha, size, content} <- put_input(input),
         {:ok, room} <- Delivery.put_check(client, lease_id, sha, delivery) do
      fence = make_ref()

      outcome =
        Results.put(sha, size, fenced(content, client, lease_id, delivery, fence), room, results)

      outcome =
        case Process.delete(fence) do
          nil -> outcome
          lost_or_unavailable -> lost_or_unavailable
        end

      Delivery.put_done(client, lease_id, outcome, delivery)
      outcome
    end
  end

  defp put_input(input) do
    case input do
      %{lease_id: lease_id, sha256: sha, size: size, content: content} ->
        put_input(%{
          "lease_id" => lease_id,
          "sha256" => sha,
          "size" => size,
          "content" => content
        })

      %{"lease_id" => lease_id, "sha256" => sha, "size" => size, "content" => content}
      when is_binary(lease_id) and is_binary(sha) and is_integer(size) and size >= 0 ->
        {:ok, lease_id, sha, size, content}

      _ ->
        {:rejected, :invalid}
    end
  end

  # After the last byte, before the store keeps them: the fence again. A lease lost (or a
  # Facts that does not answer) while the bytes streamed adds one byte past them, so the
  # store keeps nothing.
  defp fenced(content, client, lease_id, delivery, fence) do
    tail =
      Stream.flat_map([:refence], fn :refence ->
        case Delivery.refence(client, lease_id, delivery) do
          :ok ->
            []

          lost_or_unavailable ->
            Process.put(fence, lost_or_unavailable)
            [<<0>>]
        end
      end)

    Stream.concat(content, tail)
  end
end
