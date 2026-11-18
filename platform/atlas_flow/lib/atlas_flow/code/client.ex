defmodule AtlasFlow.Code.Client do
  @moduledoc """
  What Flow asks of Code, in Flow's own terms.

  - **Bases** (`AtlasFlow.Bases`; decision D41: a Runtime never talks to Code): resolve a
    reference of a repository to a revision, snapshot that revision, read the snapshot's
    manifest and stream one of its blobs.
  - **Publish** (`AtlasFlow.Publish`, F3): read the revision a snapshot holds of a
    repository, create a change on it, put the change's blobs, seal it into a revision, open
    it as a (draft) review or move an open review to it, mark a draft ready and read the
    review's status.

  A client is `{module, context}`; `module` implements this behaviour and gets `context`
  first. The real one is `AtlasFlow.Code.Client.Boundary`, the only Flow module that names
  Code's facade (Flow plan §3.4). Tests use a fake.

  Two real clients, each with only the rights its user needs: `default/0` (`[:snapshot]`,
  Bases') and `publishing/0` (`[:change, :review]`, Publish's and Landing's). Bases'
  client cannot open or change a review.

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

  @typedoc """
  One entry of a change, relative to the repository's root: `%{path, op: "delete"}`, or
  `%{path, op: "write", kind, mode, size, sha256}` (with `target` for a symlink).
  """
  @type change_entry :: %{required(:path) => String.t(), required(:op) => String.t()}
  @type change_request :: %{
          change_id: String.t(),
          snapshot_id: String.t(),
          repository: String.t(),
          base_revision: String.t(),
          entries: [change_entry()]
        }
  @typedoc "`state` is `:open` or `:sealed`; `revision` is set once sealed."
  @type change :: %{
          change_id: String.t(),
          state: :open | :sealed,
          missing: [String.t()],
          revision: String.t() | nil
        }
  @type review_request :: %{
          required(:review_id) => String.t(),
          required(:change_id) => String.t(),
          required(:target) => String.t(),
          required(:title) => String.t(),
          required(:body) => String.t(),
          optional(:fingerprint) => String.t(),
          optional(:draft) => boolean()
        }
  @type review :: %{
          review_id: String.t(),
          change_id: String.t(),
          repository: String.t(),
          target: String.t(),
          revision: String.t(),
          state: :open,
          link: String.t() | nil
        }
  @type update_request :: %{
          update_id: String.t(),
          review_id: String.t(),
          change_id: String.t(),
          revision: String.t(),
          fingerprint: String.t()
        }
  @type review_update :: %{
          update_id: String.t(),
          review_id: String.t(),
          change_id: String.t(),
          repository: String.t(),
          previous_revision: String.t(),
          revision: String.t(),
          state: :open,
          link: String.t() | nil
        }
  @type ready :: %{review_id: String.t(), revision: String.t(), link: String.t() | nil}
  @typedoc "What the review's provider holds of it now (Code's `review_report`)."
  @type report :: %{
          review_id: String.t(),
          revision: String.t(),
          state: :open | :merged | :closed,
          draft: boolean(),
          at_revision: boolean(),
          ci: :success | :failure | :pending | :none,
          failing: [String.t()] | nil,
          approvals: [String.t()],
          changes_requested: [String.t()],
          mergeable: boolean() | nil,
          behind_base: boolean() | nil,
          link: String.t() | nil
        }

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
  @callback snapshot_revision(
              context :: term(),
              snapshot_id :: String.t(),
              repository :: String.t()
            ) :: {:ok, revision :: String.t()} | {:error, tag()}
  @callback create_change(context :: term(), change_request()) ::
              {:ok, change()} | {:error, tag()}
  @callback put_change_blob(
              context :: term(),
              change_id :: String.t(),
              sha256 :: String.t(),
              content :: binary()
            ) :: {:ok, change()} | {:error, tag()}
  @callback seal_change(context :: term(), change_id :: String.t()) ::
              {:ok, change()} | {:error, tag()}
  @callback create_review(context :: term(), review_request()) ::
              {:ok, review()} | {:error, tag()}
  @callback update_review(context :: term(), update_request()) ::
              {:ok, review_update()} | {:error, tag()}
  @callback mark_ready(context :: term(), review_id :: String.t()) ::
              {:ok, ready()} | {:error, tag()}
  @callback review_status(context :: term(), review_id :: String.t()) ::
              {:ok, report()} | {:error, tag()}

  @doc "Bases' client: Code's facade in this BEAM, as caller `flow` with the right `snapshot` only."
  @spec default() :: t()
  def default, do: {AtlasFlow.Code.Client.Boundary, {"flow", [:snapshot]}}

  @doc """
  Publish's and Landing's client: Code's facade in this BEAM, as caller `flow` with the
  rights `change` and `review` (F3). Bases' `default/0` keeps `snapshot` only.
  """
  @spec publishing() :: t()
  def publishing, do: {AtlasFlow.Code.Client.Boundary, {"flow", [:change, :review]}}

  def resolve_reference({module, context}, repository, reference),
    do: module.resolve_reference(context, repository, reference)

  def create_snapshot({module, context}, placements),
    do: module.create_snapshot(context, placements)

  def get_manifest({module, context}, snapshot_id), do: module.get_manifest(context, snapshot_id)

  def get_blob({module, context}, snapshot_id, sha256),
    do: module.get_blob(context, snapshot_id, sha256)

  def snapshot_revision({module, context}, snapshot_id, repository),
    do: module.snapshot_revision(context, snapshot_id, repository)

  def create_change({module, context}, request), do: module.create_change(context, request)

  def put_change_blob({module, context}, change_id, sha256, content),
    do: module.put_change_blob(context, change_id, sha256, content)

  def seal_change({module, context}, change_id), do: module.seal_change(context, change_id)
  def create_review({module, context}, request), do: module.create_review(context, request)
  def update_review({module, context}, request), do: module.update_review(context, request)
  def mark_ready({module, context}, review_id), do: module.mark_ready(context, review_id)
  def review_status({module, context}, review_id), do: module.review_status(context, review_id)
end
