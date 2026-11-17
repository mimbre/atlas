defmodule AtlasRuntime.Work.FrozenStore do
  @moduledoc """
  The frozen results under `$ATLAS_RUNTIME_HOME/frozen/` (design §3.9; s5a-plan B9, I-K5),
  written only through the private model's `encode`/`decode`
  (`AtlasRuntime.Model.FrozenResult`):

  - `frozen/<work_id>.<attempt>.json`: one `frozen_result` per frozen attempt;
  - `frozen/blobs/<sha256>`: the content of every written file, 0444 and content-addressed.
    Only the helper writes them (`snapshot changes --blobs`); an existing blob is kept.

  A record is written to a temporary file and renamed into place, so a reader sees all of
  it or nothing. It is written before the work record that names it (I2). Besides the write
  side and the boot clean-up of records whose attempt never completed (`orphans/2`), it
  reads a record (`read/3`), streams a blob (`blob/2`), and keeps retention (`prune/3`,
  s5a-plan B12):

  - a frozen result is **retained** while its own work record exists, or while an existing
    work record's pinned `source` or any attempt's `work_product.based_on` names it;
  - once neither holds and its work was pruned (a key tombstone names the work), it becomes a
    **tombstone**: `pruned: true`, each root keeps `root` and `fingerprint`, the entries are
    dropped. A tombstone is never removed, so `pruned` can be told from `not_found`;
  - then every blob that no retained frozen result names in a file write entry is deleted.
    Blobs are content-addressed, so a blob two results share stays while either is retained.

  Baselines (`<home>/snapshots/`) are not pruned here (S5a). The work core calls `prune/3`
  inside its own process, where freezing also runs, so a freeze's fresh blobs (written by the
  helper before the record) are never swept between the helper and the record.
  """

  require Logger

  alias AtlasRuntime.Model.FrozenResult.FrozenResult

  @doc "The frozen store's root, `<home>/frozen`."
  def root(dir), do: Path.join(dir, "frozen")

  @doc "The blob folder, `<home>/frozen/blobs`."
  def blobs(dir), do: Path.join(root(dir), "blobs")

  @doc "The path of one blob."
  def blob_path(dir, sha256), do: Path.join(blobs(dir), sha256)

  @doc "The path of the record of attempt `n` of `work_id`."
  def path(dir, work_id, n), do: Path.join(dir, FrozenResult.path(%{frozen_id: id(work_id, n)}))

  @doc "A frozen result's id, `<work_id>.<attempt>`."
  def id(work_id, n), do: "#{work_id}.#{n}"

  @doc "Creates `<home>/frozen` and its blob folder (0700) if they are missing."
  def ensure!(dir) do
    for folder <- [root(dir), blobs(dir)] do
      case File.mkdir(folder) do
        :ok -> File.chmod!(folder, 0o700)
        {:error, :eexist} -> :ok
        {:error, why} -> raise File.Error, reason: why, action: "create", path: folder
      end
    end

    :ok
  end

  @doc "Writes one frozen result, atomically (temporary file, then rename)."
  def put!(dir, %FrozenResult{} = frozen) do
    ensure!(dir)
    path = Path.join(dir, FrozenResult.path(frozen))
    temporary = path <> ".tmp"
    File.write!(temporary, JSON.encode!(FrozenResult.encode(frozen)))
    File.chmod!(temporary, 0o600)
    File.rename!(temporary, path)
    :ok
  end

  @doc "Reads the record of attempt `n` of `work_id` as written, or nil."
  def get(dir, work_id, n) do
    with {:ok, bytes} <- File.read(path(dir, work_id, n)),
         {:ok, map} <- JSON.decode(bytes),
         {:ok, frozen} <- FrozenResult.decode(map) do
      frozen
    else
      _ -> nil
    end
  end

  @doc """
  The record of attempt `n` of `work_id`: `{:ok, frozen}` (retained or a tombstone; see
  `pruned`), or `:not_found` when there is none (never frozen, or not readable).
  """
  def read(dir, work_id, n) when is_binary(work_id) and is_integer(n) do
    case get(dir, work_id, n) do
      %FrozenResult{} = frozen -> {:ok, frozen}
      nil -> :not_found
    end
  end

  @doc """
  The attempt numbers of `work_id` that have a frozen record (retained or tombstone), in
  ascending order. Used once the work record is gone, when only the store remains.
  """
  def attempts(dir, work_id) when is_binary(work_id) do
    numbers =
      for path <- Path.wildcard(Path.join(root(dir), "*.json")),
          {^work_id, n} <- [parse(Path.basename(path, ".json"))],
          do: n

    Enum.sort(numbers)
  end

  @doc """
  The content of one blob as a lazy `Enumerable` of chunks of at most 64 KiB
  (`File.stream!/2`): the file is opened only when the caller enumerates it, and never held
  whole in memory. `nil` when the store has no such blob.
  """
  def blob(dir, sha256) do
    path = blob_path(dir, sha256)
    if sha256?(sha256) and File.regular?(path), do: File.stream!(path, 65_536)
  end

  @doc """
  Retention (B12): turns every frozen result that is no longer retained into a tombstone,
  then deletes every blob no retained result names. `works` are the existing work records
  (work_id => record), `index` the key index with its tombstones (I7). A result whose work
  record is missing **without** a key tombstone is kept (the store is repaired, never
  guessed at). Returns the `{work_id, attempt}` of every result it turned into a tombstone.
  """
  def prune(dir, works, index) do
    if File.dir?(root(dir)) do
      referenced = references(works)
      pruned_works = for {_key, %{pruned: true, work_id: id}} <- index, into: MapSet.new(), do: id

      {records, unreadable} = records(dir)

      {retained, tombstoned} =
        Enum.reduce(records, {[], []}, fn frozen, {retained, tombstoned} ->
          cond do
            frozen.pruned ->
              {retained, tombstoned}

            Map.has_key?(works, frozen.work_id) or
              MapSet.member?(referenced, {frozen.work_id, frozen.attempt}) or
                not MapSet.member?(pruned_works, frozen.work_id) ->
              {[frozen | retained], tombstoned}

            true ->
              put!(dir, tombstone(frozen))
              {retained, [{frozen.work_id, frozen.attempt} | tombstoned]}
          end
        end)

      # A record it cannot read may name any blob: then no blob is deleted.
      if unreadable == 0, do: sweep_blobs(dir, retained)
      Enum.reverse(tombstoned)
    else
      []
    end
  end

  @doc "A frozen result as its tombstone: `pruned`, every root's fingerprint, no entries."
  def tombstone(%FrozenResult{} = frozen),
    do: %{frozen | pruned: true, roots: Enum.map(frozen.roots, &%{&1 | entries: []})}

  # The frozen results the existing works name: a from_work's pinned source, and any
  # attempt's based_on.
  defp references(works) do
    for {_id, record} <- works,
        {work_id, n} <-
          [source(record) | Enum.map(record.attempts, &based_on/1)],
        is_binary(work_id),
        into: MapSet.new(),
        do: {work_id, n}
  end

  defp source(%{source: %{work_id: id, attempt: n}}), do: {id, n}
  defp source(_record), do: {nil, nil}

  defp based_on(%{result: %{work_product: %{based_on: %{work_id: id, attempt: n}}}}),
    do: {id, n}

  defp based_on(_attempt), do: {nil, nil}

  # Every record in the store, and how many it could not read; one that does not decode is
  # logged and left alone.
  defp records(dir) do
    dir
    |> root()
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.reduce({[], 0}, fn path, {records, unreadable} ->
      {work_id, n} = parse(Path.basename(path, ".json"))

      case work_id && get(dir, work_id, n) do
        %FrozenResult{} = frozen ->
          {[frozen | records], unreadable}

        _ ->
          Logger.error("runtime work: frozen record #{path} is unreadable; retention leaves it")
          {records, unreadable + 1}
      end
    end)
  end

  # Deletes every blob (a 64-hex file name) that no retained result names in a file write
  # entry. A helper's own temporary folders (`.changes-*`) are not blobs and are left.
  defp sweep_blobs(dir, retained) do
    keep =
      for frozen <- retained,
          root <- frozen.roots,
          %{op: :write, kind: :file, sha256: sha} <- root.entries,
          into: MapSet.new(),
          do: sha

    names =
      case File.ls(blobs(dir)) do
        {:ok, names} -> names
        {:error, _} -> []
      end

    for name <- names,
        sha256?(name),
        not MapSet.member?(keep, name),
        do: File.rm(blob_path(dir, name))

    :ok
  end

  defp sha256?(text), do: is_binary(text) and text =~ ~r/\A[0-9a-f]{64}\z/

  @doc """
  Deletes, at boot, every frozen record whose attempt was never committed `completed`
  (B9): a crash after the record was written and before the work record named it. Such a
  record was never public. A record is kept when its attempt is `completed` or `checking`
  (B21), and when its work record is gone (retention decides about it, B12). Temporary
  files are removed. Returns the `{work_id, attempt}` of every record deleted.
  """
  def orphans(dir, works) do
    root = root(dir)
    for path <- Path.wildcard(Path.join(root, "*.json.tmp")), do: File.rm(path)

    for path <- Path.wildcard(Path.join(root, "*.json")),
        {work_id, n} <- [parse(Path.basename(path, ".json"))],
        record = works[work_id],
        record != nil,
        not public?(record, n),
        reduce: [] do
      deleted ->
        File.rm!(path)
        [{work_id, n} | deleted]
    end
  end

  defp public?(record, n) do
    case Enum.find(record.attempts, &(&1.attempt == n)) do
      %{state: :completed} -> true
      %{checking: true} -> true
      _ -> false
    end
  end

  defp parse(id) do
    with [work_id, n] <- String.split(id, ".", parts: 2),
         {n, ""} <- Integer.parse(n) do
      {work_id, n}
    else
      _ -> {nil, nil}
    end
  end
end
