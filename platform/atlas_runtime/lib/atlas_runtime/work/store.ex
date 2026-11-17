defmodule AtlasRuntime.Work.Store do
  @moduledoc """
  The work core's durable state under `$ATLAS_RUNTIME_HOME/work/` (design §6), written
  only through the private model's `encode`/`decode` (`AtlasRuntime.Model.Work`):

  - `work/<work_id>.json`: one `work_record` per work;
  - `work/index.json`: every `key_index_entry`, (client, client key) → `work_id`, kept as a
    tombstone once its record is pruned (I7). A pruned work without a client key keeps a
    tombstone too: an entry whose `client_key` is its own `work_id`, held in the index under
    `{:pruned, work_id}` so that no client key looks it up;
  - `work/sequence`: the change sequence, as decimal text.

  Every file is written to a temporary file and renamed into place, so a reader sees the
  old or the new content, never a part. A record is written before the index entry that
  names it, and an entry is marked pruned before its record is deleted, so a crash between
  two writes leaves the index repairable from the records (`load/1` repairs it). The
  sequence on boot is the larger of the file and every record's, so a crash between a
  record and the sequence file never reuses a sequence.

  `load/1` refuses, never migrates: a record or index of another `format_version`, or one
  that does not decode, is `{:error, why}`.
  """

  require Logger
  alias AtlasRuntime.Model.Work.{KeyIndexEntry, WorkRecord}

  @type loaded :: %{
          works: %{String.t() => WorkRecord.t()},
          index: %{
            ({String.t(), String.t()} | {:pruned, String.t()}) => KeyIndexEntry.t()
          },
          sequence: non_neg_integer()
        }

  @doc "Reads every record, the index and the sequence: `{:ok, loaded}` or `{:error, why}`."
  @spec load(Path.t()) :: {:ok, loaded()} | {:error, String.t()}
  def load(dir) do
    root = Path.join(dir, "work")

    with :ok <- clean_temporary(root),
         {:ok, works} <- load_records(dir, root),
         {:ok, index} <- load_index(dir),
         {:ok, sequence} <- load_sequence(dir) do
      index = repair(index, works)

      sequence =
        Enum.reduce(Map.values(works), sequence, fn record, max -> max(record.sequence, max) end)

      {:ok, %{works: works, index: index, sequence: sequence}}
    end
  end

  @doc "Writes one work record."
  def put_work!(dir, %WorkRecord{} = record),
    do: write!(Path.join(dir, WorkRecord.path(record)), WorkRecord.encode(record))

  @doc "Reads one work record again (the start gate's re-read), or nil."
  def read_work(dir, work_id) do
    with {:ok, map} <- read_json(Path.join(dir, WorkRecord.path(%{work_id: work_id}))),
         {:ok, record} <- WorkRecord.decode(map) do
      record
    else
      _ -> nil
    end
  end

  @doc "Deletes one work record (after its index entry was marked pruned)."
  def delete_work!(dir, work_id) do
    case File.rm(Path.join(dir, WorkRecord.path(%{work_id: work_id}))) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> raise File.Error, reason: reason, action: "delete work record"
    end
  end

  @doc """
  The key tombstone of a pruned work in `index` (I7), or nil: its client decides who may
  still be told `pruned` (and, while its frozen result is retained, read that result).
  """
  def tombstone(index, work_id),
    do: Enum.find(Map.values(index), &(&1.work_id == work_id and &1.pruned))

  @doc "Writes the whole index."
  def put_index!(dir, index) do
    entries = index |> Map.values() |> Enum.sort_by(&{&1.client, &1.client_key})
    write!(Path.join(dir, KeyIndexEntry.path()), KeyIndexEntry.encode_file(entries))
  end

  @doc "Writes the change sequence."
  def put_sequence!(dir, sequence) when is_integer(sequence) and sequence >= 0,
    do: write_text!(sequence_path(dir), Integer.to_string(sequence))

  defp sequence_path(dir), do: Path.join([dir, "work", "sequence"])

  defp write!(path, data), do: write_text!(path, JSON.encode!(data))

  defp write_text!(path, text) do
    File.mkdir_p!(Path.dirname(path))
    temporary = path <> ".tmp"
    File.write!(temporary, text)
    File.rename!(temporary, path)
  end

  # A temporary file is a write that never got renamed: the file it would replace (or its
  # absence) is what was last written.
  defp clean_temporary(root) do
    for path <- Path.wildcard(Path.join(root, "*.tmp")), do: File.rm(path)
    :ok
  end

  defp load_records(dir, root) do
    index = Path.basename(KeyIndexEntry.path())

    root
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.reject(&(Path.basename(&1) == index))
    |> Enum.sort()
    |> Enum.reduce_while({:ok, %{}}, fn path, {:ok, works} ->
      case read_json(path) do
        {:ok, map} ->
          case WorkRecord.decode(map) do
            {:ok, record} ->
              if Path.join(dir, WorkRecord.path(record)) == path,
                do: {:cont, {:ok, Map.put(works, record.work_id, record)}},
                else: {:halt, {:error, "#{relative(dir, path)}: names work #{record.work_id}"}}

            {:error, error} ->
              {:halt, {:error, "#{relative(dir, path)}: #{inspect(error)}"}}
          end

        {:error, why} ->
          {:halt, {:error, "#{relative(dir, path)}: #{why}"}}
      end
    end)
  end

  defp load_index(dir) do
    path = Path.join(dir, KeyIndexEntry.path())

    if File.exists?(path) do
      with {:ok, map} <- read_json(path),
           {:ok, entries} <- KeyIndexEntry.decode_file(map) do
        index = Map.new(entries, &{index_key(&1), &1})

        if map_size(index) == length(entries),
          do: {:ok, index},
          else: {:error, "#{KeyIndexEntry.path()}: a client key is listed twice"}
      else
        {:error, why} when is_binary(why) -> {:error, "#{KeyIndexEntry.path()}: #{why}"}
        {:error, error} -> {:error, "#{KeyIndexEntry.path()}: #{inspect(error)}"}
      end
    else
      {:ok, %{}}
    end
  end

  defp index_key(%KeyIndexEntry{pruned: true, client_key: id, work_id: id}), do: {:pruned, id}
  defp index_key(entry), do: {entry.client, entry.client_key}

  defp load_sequence(dir) do
    case File.read(sequence_path(dir)) do
      {:ok, text} ->
        case Integer.parse(String.trim(text)) do
          {sequence, ""} when sequence >= 0 -> {:ok, sequence}
          _ -> {:error, "work/sequence: not a sequence: #{inspect(text)}"}
        end

      {:error, :enoent} ->
        {:ok, 0}

      {:error, reason} ->
        {:error, "work/sequence: #{:file.format_error(reason)}"}
    end
  end

  # A record written before its index entry: the entry is added back. An entry whose record
  # is gone without being pruned is kept and reported; it still answers for its key.
  defp repair(index, works) do
    index =
      Enum.reduce(Map.values(works), index, fn record, index ->
        key = {record.client, record.client_key}

        if record.client_key && not Map.has_key?(index, key),
          do:
            Map.put(
              index,
              key,
              KeyIndexEntry.new!(
                client: record.client,
                client_key: record.client_key,
                work_id: record.work_id,
                pruned: false
              )
            ),
          else: index
      end)

    for {_key, entry} <- index,
        not entry.pruned,
        not Map.has_key?(works, entry.work_id),
        do: Logger.warning("runtime work: index entry for #{entry.work_id} has no record")

    index
  end

  defp read_json(path) do
    case File.read(path) do
      {:ok, bytes} ->
        case JSON.decode(bytes) do
          {:ok, map} when is_map(map) -> {:ok, map}
          {:ok, _} -> {:error, "not a JSON object"}
          {:error, _} -> {:error, "not valid JSON"}
        end

      {:error, reason} ->
        {:error, :file.format_error(reason) |> to_string()}
    end
  end

  defp relative(dir, path), do: Path.relative_to(path, dir)
end
