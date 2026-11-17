defmodule AtlasRuntimeModel.Base do
  @moduledoc """
  The Runtime's private record of an uploaded base (design §13 S5c, plan B4, B5, B9, B12):
  what a client stored with `put_base`, kept under `$ATLAS_RUNTIME_HOME/bases/`, never
  seen by a caller as it is stored. The innermost layer, like `AtlasRuntimeModel.Work`.

  - `stored_base`: one per (client, base id), `bases/{key}.json`, where `key` is
    `key/2`: the lowercase hex sha256 of `client_id <> <<0>> <> base_id`. A file name
    never holds the client's base id. Its `state` is `live` or `pruned`:
    - `live`: the base's baseline (`baseline_id`, `sha256:<hex>` of its v3 manifest under
      `snapshots/`), its roots with their counts, the totals, when it was first stored
      (`stored_at`) and when it was last put (`put_at`, refreshed by an `existing` put
      and a revive);
    - `pruned`: a tombstone (B12, D28), kept forever. It keeps `client_id`, `base_id` and
      `manifest_digest`, so an identical put revives it and different content is a
      conflict, and gains `pruned_at`. Everything else is gone.
  - `base_root`: a root of the base and its counts.

  `manifest_digest` is required in both states: idempotency (B5) and a revive compare it.

  The one rule across fields that `__schema__/0` cannot declare, which state carries which
  fields, is `check/1`. The base store calls it after every `decode` and before every
  `encode`. Kept by the hand-written store, not here: a record is written before anything
  names it (I2), and `files`/`bytes` are the sums over `roots`.
  """
  use AtlasRuntimeModel.Generator.Schema

  version "0.1.0"

  defmodel :base_root do
    field :root, :string, required: true
    field :files, :integer, required: true
    field :bytes, :integer, required: true
  end

  defrecord :stored_base,
    persist: [form: :json_file, path: "bases/{key}.json", format_version: 1] do
    # key/2 of client_id and base_id.
    field :key, :string, required: true
    # The client that put it; bases are per client (B4).
    field :client_id, :string, required: true
    # The client's name for it (B6).
    field :base_id, :string, required: true
    field :state, {:enum, [:live, :pruned]}, required: true
    # The digest of its canonical manifest (B5); kept by the tombstone (B12).
    field :manifest_digest, :string, required: true
    # Live only.
    field :baseline_id, :string
    field :roots, {:list, :base_root}
    field :files, :integer
    field :bytes, :integer
    field :stored_at, :datetime
    field :put_at, :datetime
    # Pruned only.
    field :pruned_at, :datetime
  end

  @live [:baseline_id, :roots, :files, :bytes, :stored_at, :put_at]
  @pruned [:pruned_at]

  @doc "The fields a `live` record has, and a `pruned` one lacks."
  def live_fields, do: @live

  @doc "The fields a `pruned` record has, and a `live` one lacks."
  def pruned_fields, do: @pruned

  @doc """
  The file key of a client's base: the lowercase hex sha256 of
  `client_id <> <<0>> <> base_id`. Two clients' bases of the same id have different keys.
  """
  @spec key(String.t(), String.t()) :: String.t()
  def key(client_id, base_id) when is_binary(client_id) and is_binary(base_id),
    do: :crypto.hash(:sha256, [client_id, 0, base_id]) |> Base.encode16(case: :lower)

  @doc """
  Whether a `stored_base` (a struct or a map with atom keys, as `new/1` or `decode/1`
  gives it) carries its state's fields and no others, under its own key: `:ok`, or the
  first refusal in the model's error form (`AtlasRuntimeModel.Generator.Codec`):

  - `{:missing_field, "stored_base.<field>"}`: a field of its state without a value;
  - `{:invalid, "stored_base.<field>", why}`: a field of the other state, or a `key` that
    is not `key/2` of its `client_id` and `base_id`.
  """
  @spec check(map()) :: :ok | {:error, term()}
  def check(%{state: state} = record) do
    {have, lack, other} =
      case state do
        :live -> {@live, @pruned, "pruned"}
        :pruned -> {@pruned, @live, "live"}
      end

    missing = Enum.find(have, &is_nil(Map.get(record, &1)))
    extra = Enum.find(lack, &(not is_nil(Map.get(record, &1))))

    cond do
      missing ->
        {:error, {:missing_field, "stored_base.#{missing}"}}

      extra ->
        {:error, {:invalid, "stored_base.#{extra}", "only a #{other} base has it"}}

      record.key != key(record.client_id, record.base_id) ->
        {:error, {:invalid, "stored_base.key", "key/2 of client_id and base_id"}}

      true ->
        :ok
    end
  end
end
