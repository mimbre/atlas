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

  The Service names a review's URL `review_url`; the contract calls it `link`.

  An answer the contract does not declare (another error code, a field it lacks) raises:
  the contract and the Service have drifted apart.
  """
  use AtlasCode.Boundary.Implementation

  alias AtlasCode.Boundary.{
    CreateChangeInput,
    CreateReviewInput,
    CreateSnapshotInput,
    GetBlobInput,
    GetManifestInput,
    Outcome,
    PutChangeBlobInput,
    ResolveReferenceInput,
    SealChangeInput,
    UpdateReviewInput
  }

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

  @impl true
  def get_manifest(client, %GetManifestInput{snapshot_id: id}) do
    client
    |> settings()
    |> Service.get_manifest(id)
    |> outcome(Outcome.Manifest, %{
      "invalid_request" => Outcome.InvalidRequest,
      "not_found" => Outcome.NotFound,
      "snapshot_superseded" => Outcome.SnapshotSuperseded
    })
  end

  # The blob's content stays the Service's lazy stream: the facade passes it on unread.
  @impl true
  def get_blob(client, %GetBlobInput{snapshot_id: id, sha256: digest}) do
    client
    |> settings()
    |> Service.get_blob(id, digest)
    |> outcome(Outcome.Blob, %{
      "invalid_request" => Outcome.InvalidRequest,
      "not_found" => Outcome.NotFound,
      "snapshot_superseded" => Outcome.SnapshotSuperseded,
      "forbidden" => Outcome.Forbidden,
      "unknown_revision" => Outcome.UnknownRevision,
      "repository_mismatch" => Outcome.RepositoryMismatch,
      "provider_unavailable" => Outcome.ProviderUnavailable
    })
  end

  @impl true
  def create_change(client, %CreateChangeInput{} = input) do
    client
    |> settings()
    |> Service.create_change(CreateChangeInput.dump(input))
    |> outcome(Outcome.Change, %{
      "invalid_request" => Outcome.InvalidRequest,
      "forbidden" => Outcome.Forbidden,
      "not_found" => Outcome.NotFound,
      "snapshot_superseded" => Outcome.SnapshotSuperseded,
      "base_mismatch" => Outcome.BaseMismatch,
      "conflict" => Outcome.Conflict,
      "unsupported_content" => Outcome.UnsupportedContent
    })
  end

  @impl true
  def put_change_blob(client, %PutChangeBlobInput{change_id: id, sha256: digest, content: bytes}) do
    client
    |> settings()
    |> Service.put_change_blob(id, digest, bytes)
    |> outcome(Outcome.Change, %{
      "invalid_request" => Outcome.InvalidRequest,
      "not_found" => Outcome.NotFound
    })
  end

  @impl true
  def seal_change(client, %SealChangeInput{change_id: id}) do
    client
    |> settings()
    |> Service.seal_change(id)
    |> outcome(Outcome.Change, %{
      "invalid_request" => Outcome.InvalidRequest,
      "not_found" => Outcome.NotFound,
      "incomplete_upload" => Outcome.IncompleteUpload,
      "forbidden" => Outcome.Forbidden,
      "unknown_revision" => Outcome.UnknownRevision,
      "repository_mismatch" => Outcome.RepositoryMismatch,
      "provider_unavailable" => Outcome.ProviderUnavailable,
      "conflict" => Outcome.Conflict
    })
  end

  @impl true
  def create_review(client, %CreateReviewInput{} = input) do
    client
    |> settings()
    |> Service.create_review(CreateReviewInput.dump(input))
    |> link()
    |> outcome(Outcome.Review, %{
      "invalid_request" => Outcome.InvalidRequest,
      "not_found" => Outcome.NotFound,
      "change_not_sealed" => Outcome.ChangeNotSealed,
      "fingerprint_mismatch" => Outcome.FingerprintMismatch,
      "forbidden" => Outcome.Forbidden,
      "unknown_revision" => Outcome.UnknownRevision,
      "repository_mismatch" => Outcome.RepositoryMismatch,
      "conflict" => Outcome.Conflict,
      "location_taken" => Outcome.LocationTaken,
      "provider_unavailable" => Outcome.ProviderUnavailable,
      "review_incomplete" => Outcome.ReviewIncomplete
    })
  end

  @impl true
  def update_review(client, %UpdateReviewInput{} = input) do
    client
    |> settings()
    |> Service.update_review(UpdateReviewInput.dump(input))
    |> link()
    |> outcome(Outcome.Updated, %{
      "invalid_request" => Outcome.InvalidRequest,
      "not_found" => Outcome.NotFound,
      "review_not_open" => Outcome.ReviewNotOpen,
      "change_not_sealed" => Outcome.ChangeNotSealed,
      "repository_mismatch" => Outcome.RepositoryMismatch,
      "revision_mismatch" => Outcome.RevisionMismatch,
      "fingerprint_mismatch" => Outcome.FingerprintMismatch,
      "forbidden" => Outcome.Forbidden,
      "unknown_revision" => Outcome.UnknownRevision,
      "conflict" => Outcome.Conflict,
      "provider_unavailable" => Outcome.ProviderUnavailable,
      "location_moved" => Outcome.LocationMoved,
      "update_refused" => Outcome.UpdateRefused
    })
  end

  # `AtlasCode`'s routes only (see the moduledoc).
  defp settings({{AtlasCode, settings}, _rights}) when is_map(settings), do: settings
  defp settings(_client), do: AtlasCode.settings()

  defp link({200, %{"review_url" => url} = body}),
    do: {200, body |> Map.delete("review_url") |> Map.put("link", url)}

  defp link(answer), do: answer

  defp outcome({200, body}, success, _refusals), do: success.new!(body)

  defp outcome(
         {_status, %{"error" => %{"code" => code, "message" => message, "details" => details}}},
         _success,
         refusals
       ),
       do: Map.fetch!(refusals, code).new!(Map.put(details, "message", message))
end
