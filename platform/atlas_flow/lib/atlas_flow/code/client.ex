defmodule AtlasFlow.Code.Client do
  @moduledoc """
  What Flow asks of Code, in Flow's own terms.

  **Bases** (`AtlasFlow.Bases`; decision D41: a Runtime never talks to Code): resolve a
  reference of a repository to a revision, snapshot that revision, read the snapshot's
  manifest and stream one of its blobs. That is all Flow asks: a result goes to Code over
  Git (`refs/atlas/results/<task>`), and Code publishes it as an effect Flow sends over the
  Bus, never as a change Flow uploads.

  A client is `{module, context}`; `module` implements this behaviour and gets `context`
  first. The real one is `AtlasFlow.Code.Client.Boundary`, the only Flow module that names
  Code's facade (Flow plan §3.4). Tests use a fake.

  The real client, `default/0`, has the right `snapshot` only.

  Failures are `{:error, tag}`, where `tag` is the outcome Code answered (`:not_found`,
  `:unknown_reference`, `:provider_unavailable`, `:not_permitted`, …), or `:unavailable`
  when no Code answers at all.
  """

  @type t :: {module(), term()}
  @type tag :: atom()
  @type entry :: %{
          required(:repository) => String.t(),
          required(:path) => String.t(),
          required(:kind) => String.t(),
          required(:mode) => String.t(),
          required(:size) => non_neg_integer(),
          required(:sha256) => String.t(),
          optional(:target) => String.t() | nil
        }
  @type placement :: %{repository: String.t(), revision: String.t(), path: String.t()}

  @callback resolve_reference(
              context :: term(),
              repository :: String.t(),
              reference :: String.t()
            ) ::
              {:ok, revision :: String.t()} | {:error, tag()}
  @callback create_snapshot(context :: term(), [placement()]) ::
              {:ok, snapshot_id :: String.t()} | {:error, tag()}
  @callback get_manifest(context :: term(), snapshot_id :: String.t()) ::
              {:ok, [entry()]} | {:error, tag()}
  @callback get_blob(context :: term(), snapshot_id :: String.t(), sha256 :: String.t()) ::
              {:ok, size :: non_neg_integer(), Enumerable.t()} | {:error, tag()}

  @doc "Bases' client: Code's facade in this BEAM, as caller `flow` with the right `snapshot` only."
  @spec default() :: t()
  def default, do: {AtlasFlow.Code.Client.Boundary, {"flow", [:snapshot]}}

  def resolve_reference({module, context}, repository, reference),
    do: module.resolve_reference(context, repository, reference)

  def create_snapshot({module, context}, placements),
    do: module.create_snapshot(context, placements)

  def get_manifest({module, context}, snapshot_id), do: module.get_manifest(context, snapshot_id)

  def get_blob({module, context}, snapshot_id, sha256),
    do: module.get_blob(context, snapshot_id, sha256)
end
