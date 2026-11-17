defmodule AtlasRuntimeModel.FrozenResult do
  @moduledoc """
  The Runtime's private record of a frozen result (design §3.9, D41): the change set of a
  completed attempt against its base, kept under `$ATLAS_RUNTIME_HOME/frozen/`, never seen
  by a caller as it is stored. The innermost layer, like `AtlasRuntimeModel.Work`.

  - `frozen_result`: one per frozen attempt, `frozen/{frozen_id}.json`, where `frozen_id`
    is `<work_id>.<attempt>`. Its roots are the base's repository paths, each with its
    fingerprint (`csf_…`) and its entries; a root with no changes has `entries: []`. A
    pruned result is a tombstone: `pruned: true`, each root keeps `root` and
    `fingerprint`, and its entries are dropped (`entries: []`).
  - `change_entry`: a write (`kind`, `mode`, `size`, `sha256`, and `target` for a symlink)
    or a delete (`path` and `op` only). The blobs are files, `frozen/blobs/<sha256>`.

  Rules kept by the hand-written code (`AtlasChangeset` and the frozen store), not
  declared here:
  - `frozen_id` is `<work_id>.<attempt>` of the same record;
  - which fields a write or a delete carries, and that `mode` matches `kind`;
  - a frozen result is written before the work record that names it (I2);
  - `base_owner` and `baseline_id` are the work record's, as they were at freeze.
  """
  use AtlasRuntimeModel.Generator.Schema

  version "0.1.0"

  defmodel :change_entry do
    # Relative to the root.
    field :path, :string, required: true
    field :op, {:enum, [:write, :delete]}, required: true
    field :kind, {:enum, [:file, :symlink]}
    # Git's file mode: "100644", "100755" or "120000".
    field :mode, :string
    field :size, :integer
    # 64 lowercase hex; the blob is frozen/blobs/<sha256>.
    field :sha256, :string
    # A symlink's target.
    field :target, :string
  end

  defmodel :frozen_root do
    field :root, :string, required: true
    field :fingerprint, :string, required: true
    field :entries, {:list, :change_entry}, required: true
  end

  defrecord :frozen_result,
    persist: [form: :json_file, path: "frozen/{frozen_id}.json", format_version: 1] do
    # <work_id>.<attempt>
    field :frozen_id, :string, required: true
    field :work_id, :string, required: true
    field :attempt, :integer, required: true
    # The base's snapshot id.
    field :base, :string, required: true
    field :frozen_at, :datetime, required: true
    # A tombstone: the entries are dropped, the fingerprints kept (retention).
    field :pruned, :boolean, required: true
    field :roots, {:list, :frozen_root}, required: true
    # Private (S5c, N4): copied from the work record at freeze, so base retention and a
    # from_work still find the base once the record is pruned. Absent on an S5a-era
    # result.
    field :base_owner, :string
    field :baseline_id, :string
  end
end
