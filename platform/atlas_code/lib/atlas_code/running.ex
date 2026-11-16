defmodule AtlasCode.Running do
  @moduledoc """
  The implementation behind the facade `AtlasCode.Boundary`: each capability calls
  `AtlasCode.Service` with the settings of a running Code and turns its answer into the
  contract's outcome.

  Which Code: the one registered in this BEAM (`AtlasCode.settings/0`), for every caller
  but one. Code's own HTTP routes call on behalf of the instance that serves them, whose
  settings they hold: their client id is `{AtlasCode, settings}`.

  That client id form is for `AtlasCode`'s routes only; no other caller may use it. It
  carries configuration in a client id, which no other client of the facade does. It exists
  because many unregistered instances serve at once in one BEAM (atlas_code_test) and a
  route must reach its own. It grants nothing new: the rights are still the client's own,
  and any caller can already pass any settings to `AtlasCode.Service`. Retire it once each
  home has a registered instance of its own (decision 1, Code in the core): then a route
  names its instance, not its settings.

  An answer the contract does not declare (another error code, a field it lacks) raises:
  the contract and the Service have drifted apart.
  """
  use AtlasCode.Boundary.Implementation

  alias AtlasCode.Boundary.{CreateSnapshotInput, Outcome, ResolveReferenceInput}
  alias AtlasCode.Service

  @impl true
  def resolve_reference(client, %ResolveReferenceInput{} = input) do
    client
    |> settings()
    |> Service.resolve_reference(ResolveReferenceInput.dump(input))
    |> outcome(Outcome.Resolved, %{
      "invalid_request" => Outcome.InvalidRequest,
      "forbidden" => Outcome.Forbidden,
      "unknown_reference" => Outcome.UnknownReference,
      "provider_unavailable" => Outcome.ProviderUnavailable
    })
  end

  @impl true
  def create_snapshot(client, %CreateSnapshotInput{} = input) do
    client
    |> settings()
    |> Service.create_snapshot(CreateSnapshotInput.dump(input))
    |> outcome(Outcome.Created, %{
      "invalid_request" => Outcome.InvalidRequest,
      "forbidden" => Outcome.Forbidden,
      "unknown_revision" => Outcome.UnknownRevision,
      "repository_mismatch" => Outcome.RepositoryMismatch,
      "not_found" => Outcome.NotFound,
      "unsupported_content" => Outcome.UnsupportedContent,
      "provider_unavailable" => Outcome.ProviderUnavailable
    })
  end

  # `AtlasCode`'s routes only (see the moduledoc).
  defp settings({{AtlasCode, settings}, _rights}) when is_map(settings), do: settings
  defp settings(_client), do: AtlasCode.settings()

  defp outcome({200, body}, success, _refusals), do: success.new!(body)

  defp outcome(
         {_status, %{"error" => %{"code" => code, "message" => message, "details" => details}}},
         _success,
         refusals
       ),
       do: Map.fetch!(refusals, code).new!(Map.put(details, "message", message))
end
