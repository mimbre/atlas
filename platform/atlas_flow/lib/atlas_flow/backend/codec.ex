defmodule AtlasFlow.Backend.Codec do
  @moduledoc """
  The bodies of Flow's work source backend (plan m3 §3.6): JSON in, JSON out, in the
  shapes of the Runtime's `work_source` contract (its JSON description,
  `work_source.json`), and errors as `application/problem+json` (RFC 9457).

  - A request body is one JSON object holding only the fields the route takes from it
    (`body_fields/1`); the path's parameters are added to it. Anything else is not an
    input (`:error`), and the router answers its `invalid` error. The values themselves
    are checked by `AtlasFlow.WorkSource`, which answers `rejected(invalid)`.
  - An outcome is `{name, fields}`: `fields` the outcome's model as JSON terms (string
    keys, enum values and atoms as text, ISO-8601 datetimes, absent values left out), or
    nil for an outcome without a model. `polled` is cut to exactly its model's fields.
  - A problem body is `type`, `title` and `status`, then the outcome's fields. The title
    is the status's reason phrase: no text of an answer repeats what a request sent.
  """

  alias AtlasFlow.WorkSource.Translate

  @poll_fields ~w(runtime_id incarnation build policy_version offer holdings configuration_refused upgrade)
  @report_fields ~w(revision report)

  @doc "The fields a capability's request body holds; nil for a route without a JSON body."
  def body_fields(:poll), do: @poll_fields
  def body_fields(:report), do: @report_fields
  def body_fields(_capability), do: nil

  @doc """
  The input of `capability` from its JSON request body and the path's `params`:
  `{:ok, map}` (string keys), or `:error` when the body is not one JSON object of the
  route's body fields.
  """
  @spec input(atom(), binary(), map()) :: {:ok, map()} | :error
  def input(capability, body, params) when is_binary(body) and is_map(params) do
    fields = body_fields(capability)

    with true <- is_list(fields),
         {:ok, %{} = json} <- JSON.decode(body),
         [] <- Map.keys(json) -- fields do
      {:ok, Map.merge(json, params)}
    else
      _ -> :error
    end
  end

  @doc """
  An answer of `AtlasFlow.WorkSource` as `{outcome, fields}`. `:unavailable` (Facts did not
  answer a report) as it is: the router answers it 503. `:error` for
  anything that is no outcome of `capability`.
  """
  @spec outcome(atom(), term()) :: {atom(), map() | nil} | :unavailable | :error
  def outcome(:poll, {:polled, polled}) when is_map(polled), do: {:polled, polled(polled)}
  def outcome(:report, {:recorded, recorded}), do: {:recorded, recorded(recorded)}
  def outcome(:get_blob, {:blob, blob}), do: {:blob, blob}
  def outcome(:report, :unavailable), do: :unavailable
  def outcome(capability, {:rejected, reason}), do: rejected(capability, reason)

  def outcome(capability, name) when is_atom(name) do
    if name in nil_outcomes(capability), do: {name, nil}, else: :error
  end

  def outcome(_capability, _answer), do: :error

  defp nil_outcomes(:report), do: [:lease_lost]
  defp nil_outcomes(:get_blob), do: [:not_found]
  defp nil_outcomes(_), do: []

  @reasons [:invalid, :conflict]

  defp rejected(capability, reason) when capability in [:poll, :report, :get_blob] do
    {reason, detail} =
      case reason do
        %{} = map -> {map[:reason] || map["reason"], map[:detail] || map["detail"]}
        reason -> {reason, nil}
      end

    reason =
      if is_binary(reason), do: Enum.find(@reasons, &(Atom.to_string(&1) == reason)), else: reason

    if reason in @reasons,
      do: {:rejected, Translate.normal(%{reason: reason, detail: detail})},
      else: :error
  end

  defp rejected(_capability, _reason), do: :error

  defp polled(polled) do
    get = fn key -> Map.get(polled, key, Map.get(polled, Atom.to_string(key))) end

    polled = %{
      "leases" => Enum.map(get.(:leases) || [], &lease/1),
      "cancel" => get.(:cancel) || [],
      "lease_lost" => get.(:lease_lost) || [],
      "timing" => Translate.normal(get.(:timing))
    }

    polled =
      case get.(:configuration) do
        document when is_binary(document) -> Map.put(polled, "configuration", document)
        _ -> polled
      end

    case get.(:upgrade) do
      %{} = order ->
        Map.put(polled, "upgrade", Map.take(Translate.normal(order), ~w(id build action)))

      _ ->
        polled
    end
  end

  defp lease(lease) do
    lease = Translate.normal(lease)
    Map.take(lease, ~w(lease_id expires_at work))
  end

  defp recorded(recorded) do
    recorded = Translate.normal(recorded)
    %{"missing" => recorded["missing"] || []}
  end

  @doc "A problem body: `type`, `title` and `status`, then `fields`."
  @spec problem(pos_integer(), String.t(), map() | nil) :: map()
  def problem(status, type, fields \\ nil) do
    Map.merge(fields || %{}, %{
      "type" => type,
      "title" => Plug.Conn.Status.reason_phrase(status),
      "status" => status
    })
  end

  @doc "JSON text of a body."
  def encode(body), do: JSON.encode!(body)
end
