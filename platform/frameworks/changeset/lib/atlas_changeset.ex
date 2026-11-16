defmodule AtlasChangeset do
  @moduledoc """
  The neutral change set: its shape, its canonical form and its `csf_` fingerprint (D42).

  A change set is plain data:

      %{base: String.t(), roots: [%{root: String.t(), entries: [entry]}]}

  A write entry is `%{path, op: "write", kind: "file" | "symlink", mode: "100644" | "100755" |
  "120000", size: non_neg_integer, sha256: <64 lowercase hex>, target: String.t()}`, where
  `target` is there for a symlink only. A delete entry is `%{path, op: "delete"}`.

  - Keys may be atoms or strings. Values are strings, and `size` an integer.
  - A key whose value is `nil` counts as absent, and a struct's `__struct__` key is ignored,
    so generated structs can be passed as they are.
  - `root` is one top-level folder name; `path` is relative to it.

  The fingerprint of one root is `"csf_" <> sha256(canonical(base, root, entries))` in
  lowercase hex. `priv/fixtures/canonical.json` pins the canonical form with fixed bytes and
  fingerprints; any other implementation can be checked against it.
  """

  alias AtlasChangeset.{Canonical, Validate}

  @type entry :: map()
  @type change_set :: %{
          required(:base | String.t()) => term(),
          required(:roots | String.t()) => term()
        }

  @doc """
  Checks a whole change set. Returns `:ok`, or `{:error, messages}` with one message per
  problem found.
  """
  @spec validate(change_set()) :: :ok | {:error, [String.t()]}
  def validate(change_set) do
    case Validate.change_set(change_set) do
      {:ok, _} -> :ok
      {:error, errors} -> {:error, errors}
    end
  end

  @doc """
  The canonical JSON of one root. The entries may come in any order.

  Raises `ArgumentError` when `base`, `root` or an entry is not valid (see `validate/1`):
  an invalid root has no canonical form.
  """
  @spec canonical(String.t(), String.t(), [entry()]) :: binary()
  def canonical(base, root, entries) do
    case Validate.root(base, root, entries) do
      {:ok, entries} ->
        Canonical.encode(base, root, entries)

      {:error, errors} ->
        raise ArgumentError, "invalid change set root: " <> Enum.join(errors, "; ")
    end
  end

  @doc """
  The fingerprint of one root: `"csf_"` followed by 64 lowercase hex digits.
  Raises like `canonical/3`.
  """
  @spec fingerprint(String.t(), String.t(), [entry()]) :: String.t()
  def fingerprint(base, root, entries) do
    "csf_" <> Base.encode16(:crypto.hash(:sha256, canonical(base, root, entries)), case: :lower)
  end

  @doc """
  The fingerprint of every root of a change set, in the order its roots are given.
  Raises `ArgumentError` when the change set is not valid.
  """
  @spec fingerprints(change_set()) :: [%{root: String.t(), fingerprint: String.t()}]
  def fingerprints(change_set) do
    case Validate.change_set(change_set) do
      {:ok, %{"base" => base, "roots" => roots}} ->
        for %{"root" => root, "entries" => entries} <- roots do
          %{root: root, fingerprint: fingerprint(base, root, entries)}
        end

      {:error, errors} ->
        raise ArgumentError, "invalid change set: " <> Enum.join(errors, "; ")
    end
  end

  @doc """
  Checks a blob against its write entry: its byte count against `size`, then its digest
  against `sha256`.

  The content is an `Enumerable` of binaries (or iodata), enumerated once and never held as a
  whole. It stops as soon as the content is longer than `size`. Raises `ArgumentError` when
  the entry is not a valid write entry.
  """
  @spec verify_blob(entry(), Enumerable.t()) :: :ok | {:error, :size | :sha256}
  def verify_blob(entry, content) do
    entry =
      case Validate.write_entry(entry) do
        {:ok, entry} -> entry
        {:error, errors} -> raise ArgumentError, "invalid entry: " <> Enum.join(errors, "; ")
      end

    size = entry["size"]

    result =
      Enum.reduce_while(content, {:crypto.hash_init(:sha256), 0}, fn chunk, {hash, count} ->
        count = count + IO.iodata_length(chunk)

        if count > size,
          do: {:halt, :too_long},
          else: {:cont, {:crypto.hash_update(hash, chunk), count}}
      end)

    case result do
      :too_long ->
        {:error, :size}

      {_hash, count} when count != size ->
        {:error, :size}

      {hash, _count} ->
        if Base.encode16(:crypto.hash_final(hash), case: :lower) == entry["sha256"],
          do: :ok,
          else: {:error, :sha256}
    end
  end
end
