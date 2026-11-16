defmodule AtlasFlow.Runtime.Client do
  @moduledoc """
  What Flow asks of a machinery's Runtime, in Flow's own outcomes (plan 2026-11-17 §3.4,
  §6 F1.1; Runtime design 2026-11-16 §3.2, §8.3, §10). The translation is the client's:
  the Runtime's backend is a remote one, reached over HTTP by `AtlasFlow.Runtime.Client.Http`;
  Flow's activities code (and fake) against this behaviour only.

  Every callback takes the machinery (`AtlasFlow.Runtime.Config`) first. Request fields and
  works pass through as maps: a request is sent as given (atom or string keys), and a work
  comes back as the Runtime's JSON, decoded with string keys (`"work_id"`, `"revision"`,
  `"state"`, `"attempts"`, …). So fields the Runtime adds later (`after_check`,
  `from_work`, `work_product.check`) need no change here.

  Outcomes:

  - `{:accepted, work}` and `{:existing, work}`: `submit` (201 and 200) and `retry` (201);
  - `{:found, work}`: `get_work`, `find_work`;
  - `{:works, works, sequence}`: `list_work`; `{:capacity, capacity}`: `capacity`;
  - `{:cancelling, work}` and `{:ended, work}`: `cancel` (202 and 200);
  - `{:at_capacity, retry_after}`: a 503 of problem type `at-capacity`; `retry_after` in
    seconds, from `Retry-After` (nil only when the Runtime sent none);
  - `{:refused, reason}`: the Runtime refused (`:conflict`, `:invalid`, `:not_permitted`,
    `:policy_forbids`, `:no_permitted_option`, `:resume_unavailable`,
    `:unsupported_workspace`, and `:unauthenticated` for a 401);
  - `{:pruned, work_id, kind}`: 410, the work existed, ended as `kind` and was pruned: never
    submit it again as new work (obligation 4);
  - `:not_found`: 404 of problem type `not-found`, "never seen", the only answer after which
    a submit may follow (obligation 4);
  - `{:unreachable, reason}`: no answer from the Runtime itself: a connection or transport
    error, a 502 or 504, a 503 whose type is not `at-capacity`, or any status or body that
    is not one of the Runtime's declared answers (a proxy's 404, say). Unreachable is not
    lost: nothing may be released or rerouted on it.

  A client makes exactly one request per call. It never retries: retries, and when to wait,
  are Flow's (obligations 1 and 6), so a transport error comes back as `unreachable` and the
  caller sends the same key again when it chooses (obligation 2).
  """

  alias AtlasFlow.Runtime.Config

  @type machinery :: Config.t()
  @type work :: %{optional(String.t()) => term()}
  @type request :: map()
  @type reason :: atom()
  @type unreachable :: {:unreachable, term()}
  @type refused :: {:refused, reason()}
  @type at_capacity :: {:at_capacity, non_neg_integer() | nil}

  @type submit_outcome ::
          {:accepted, work()} | {:existing, work()} | at_capacity() | refused() | unreachable()
  @type read_outcome ::
          {:found, work()}
          | {:pruned, String.t(), String.t()}
          | :not_found
          | refused()
          | unreachable()
  @type list_outcome :: {:works, [work()], non_neg_integer()} | refused() | unreachable()
  @type capacity_outcome :: {:capacity, map()} | refused() | unreachable()
  @type retry_outcome ::
          {:accepted, work()} | at_capacity() | refused() | :not_found | unreachable()
  @type cancel_outcome ::
          {:cancelling, work()} | {:ended, work()} | refused() | :not_found | unreachable()

  @doc """
  Submit `request` as the work of client key `key`, the task's key (obligation 2): sent as
  the `Idempotency-Key`, so the same key always names the same work (I3). A `client_key`
  in `request` is ignored; the key is the only one.
  """
  @callback submit(machinery(), key :: String.t(), request()) :: submit_outcome()

  @doc "Read the work `work_id`."
  @callback get_work(machinery(), work_id :: String.t()) :: read_outcome()

  @doc "Find the work of client key `key`."
  @callback find_work(machinery(), key :: String.t()) :: read_outcome()

  @doc "Flow's works changed after sequence `changed_since` (nil: all), and the sequence now."
  @callback list_work(machinery(), changed_since :: non_neg_integer() | nil) :: list_outcome()

  @doc "The Runtime's capacity: slots, buffer, per-profile availability, `accepting`."
  @callback capacity(machinery()) :: capacity_outcome()

  @doc "A new attempt of `work_id`; `resume` continues an interrupted one."
  @callback retry(machinery(), work_id :: String.t(), resume :: boolean()) :: retry_outcome()

  @doc "Cancel `work_id` (`:graceful` or `:force`), with an optional reason."
  @callback cancel(machinery(), work_id :: String.t(), :graceful | :force, String.t() | nil) ::
              cancel_outcome()
end

defmodule AtlasFlow.Runtime.Client.Http do
  @moduledoc """
  `AtlasFlow.Runtime.Client` over the Runtime's `rest` backend (Runtime design §8), with
  `req`: `Authorization: Bearer` with the machinery's token, JSON bodies, and the machinery's
  HTTP CONNECT proxy when it has one. Its status and problem-type table is the design's
  §8.3; anything outside it is `unreachable`.

  `events/2` opens the event stream (`GET /v1/events`, §8.4) for `AtlasFlow.Runtime.Link`.
  """
  @behaviour AtlasFlow.Runtime.Client

  alias AtlasFlow.Runtime.Config

  @connect_timeout 5_000
  @receive_timeout 15_000

  # The Runtime's problem types (§8.3) and what they mean to Flow. Remote input never
  # becomes an atom other than these.
  @refusals %{
    "idempotency-conflict" => :conflict,
    "invalid" => :invalid,
    "not-permitted" => :not_permitted,
    "policy-forbids" => :policy_forbids,
    "no-permitted-option" => :no_permitted_option,
    "resume-unavailable" => :resume_unavailable,
    "unsupported-workspace" => :unsupported_workspace,
    "unauthenticated" => :unauthenticated,
    "origin-refused" => :origin_refused,
    "no-route" => :no_route
  }

  @impl true
  def submit(machinery, key, request) when is_binary(key) and key != "" and is_map(request) do
    body = Map.drop(request, [:client_key, "client_key"])

    machinery
    |> call(:post, "/v1/work", body: body, headers: [{"idempotency-key", key}])
    |> outcome(%{201 => :accepted, 200 => :existing})
  end

  @impl true
  def get_work(machinery, work_id),
    do: machinery |> call(:get, "/v1/work/" <> segment(work_id), []) |> outcome(%{200 => :found})

  @impl true
  def find_work(machinery, key) when is_binary(key),
    do: machinery |> call(:get, "/v1/work", params: [key: key]) |> outcome(%{200 => :found})

  @impl true
  def list_work(machinery, changed_since) do
    params = if changed_since, do: [changed_since: changed_since], else: []

    case call(machinery, :get, "/v1/work", params: params) do
      {:ok, 200, _headers, %{"works" => works, "sequence" => sequence}}
      when is_list(works) and is_integer(sequence) ->
        {:works, works, sequence}

      answer ->
        outcome(answer, %{})
    end
  end

  @impl true
  def capacity(machinery) do
    case call(machinery, :get, "/v1/capacity", []) do
      {:ok, 200, _headers, %{"slots" => _} = capacity} -> {:capacity, capacity}
      answer -> outcome(answer, %{})
    end
  end

  @impl true
  def retry(machinery, work_id, resume) when is_boolean(resume),
    do:
      machinery
      |> call(:post, "/v1/work/" <> segment(work_id) <> "/attempts", body: %{resume: resume})
      |> outcome(%{201 => :accepted})

  @impl true
  def cancel(machinery, work_id, mode, reason) when mode in [:graceful, :force] do
    body = if reason, do: %{mode: mode, reason: reason}, else: %{mode: mode}

    machinery
    |> call(:post, "/v1/work/" <> segment(work_id) <> "/cancel", body: body)
    |> outcome(%{202 => :cancelling, 200 => :ended})
  end

  @doc """
  Opens the event stream, resuming after `last_event_id` (nil: from now). The response's
  body arrives as messages to the calling process (`Req.parse_message/2`); `{:ok, response}`
  once the Runtime answered 200 with `text/event-stream`, otherwise the outcome it gave.
  """
  @spec events(Config.t(), non_neg_integer() | nil) ::
          {:ok, Req.Response.t()} | {:refused, atom()} | {:unreachable, term()}
  def events(machinery, last_event_id) do
    headers =
      [{"accept", "text/event-stream"}] ++
        if(last_event_id, do: [{"last-event-id", Integer.to_string(last_event_id)}], else: [])

    request =
      machinery
      |> new(:get, "/v1/events", headers: headers)
      |> Req.merge(into: :self, receive_timeout: :infinity)

    case Req.request(request) do
      {:ok, %Req.Response{status: 200} = response} ->
        if event_stream?(response) do
          {:ok, response}
        else
          close(response)
          {:unreachable, {:status, 200}}
        end

      {:ok, %Req.Response{status: status} = response} ->
        close(response)
        # The body is not read: the status alone says whose answer it is.
        if status == 401,
          do: {:refused, :unauthenticated},
          else: {:unreachable, {:status, status}}

      {:error, exception} ->
        {:unreachable, exception}
    end
  end

  @doc "Closes an event stream `events/2` opened; nothing for any other response."
  @spec close(Req.Response.t()) :: :ok
  def close(%Req.Response{body: %Req.Response.Async{}} = response) do
    Req.cancel_async_response(response)
    :ok
  end

  def close(%Req.Response{}), do: :ok

  @doc "The `req` request for `path` on `machinery` (also for tests of the options)."
  @spec new(Config.t(), atom(), String.t(), keyword()) :: Req.Request.t()
  def new(%Config{} = machinery, method, path, options \\ []) do
    {headers, options} = Keyword.pop(options, :headers, [])
    {body, options} = Keyword.pop(options, :body)

    Req.new(
      [
        method: method,
        base_url: machinery.url,
        url: path,
        headers: auth(machinery) ++ [{"accept", "application/json"}] ++ content(body) ++ headers,
        body: body && JSON.encode!(body),
        # Retries and their timing are Flow's (obligations 1, 2 and 6): one request per call.
        retry: false,
        redirect: false,
        decode_body: false,
        compressed: false,
        receive_timeout: @receive_timeout,
        connect_options: connect_options(machinery)
      ] ++ options
    )
  end

  defp call(machinery, method, path, options) do
    case Req.request(new(machinery, method, path, options)) do
      {:ok, %Req.Response{status: status, headers: headers, body: body}} ->
        {:ok, status, headers, decode(body)}

      {:error, exception} ->
        {:unreachable, exception}
    end
  end

  defp outcome({:unreachable, _} = unreachable, _successes), do: unreachable

  defp outcome({:ok, status, headers, body}, successes) do
    case {Map.fetch(successes, status), body} do
      {{:ok, tag}, %{"work_id" => _} = work} -> {tag, work}
      _ -> problem(status, headers, body)
    end
  end

  # A Runtime answer is a problem+json body with one of its types; anything else (a proxy's
  # page, a 502 or 504 from the reachability path, an empty body) is not the Runtime's.
  defp problem(503, headers, %{"type" => "at-capacity"} = body),
    do: {:at_capacity, retry_after(headers, body)}

  defp problem(410, _headers, %{"type" => "pruned", "work_id" => id, "kind" => kind}),
    do: {:pruned, id, kind}

  defp problem(404, _headers, %{"type" => "not-found"}), do: :not_found

  defp problem(status, _headers, %{"type" => type}) when status in 400..499 do
    case Map.fetch(@refusals, type) do
      {:ok, reason} -> {:refused, reason}
      :error -> {:unreachable, {:status, status}}
    end
  end

  defp problem(status, _headers, _body), do: {:unreachable, {:status, status}}

  defp retry_after(headers, body) do
    with [value | _] <- Map.get(headers, "retry-after", []),
         {seconds, ""} when seconds >= 0 <- Integer.parse(value) do
      seconds
    else
      _ ->
        case body do
          %{"retry_after" => seconds} when is_integer(seconds) and seconds >= 0 -> seconds
          _ -> nil
        end
    end
  end

  defp decode(""), do: nil

  defp decode(body) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, value} -> value
      {:error, _} -> nil
    end
  end

  defp decode(_), do: nil

  defp event_stream?(response) do
    response
    |> Req.Response.get_header("content-type")
    |> Enum.any?(&String.starts_with?(&1, "text/event-stream"))
  end

  defp auth(machinery) do
    case Config.token(machinery) do
      nil -> []
      token -> [{"authorization", "Bearer " <> token}]
    end
  end

  defp content(nil), do: []
  defp content(_body), do: [{"content-type", "application/json"}]

  defp connect_options(%Config{proxy: nil}), do: [timeout: @connect_timeout]

  defp connect_options(%Config{proxy: {scheme, host, port}}),
    do: [timeout: @connect_timeout, proxy: {scheme, host, port, []}]

  defp segment(id) when is_binary(id), do: URI.encode(id, &URI.char_unreserved?/1)
end
