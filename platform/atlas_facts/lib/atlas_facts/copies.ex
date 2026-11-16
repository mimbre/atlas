defmodule AtlasFacts.Copies do
  @moduledoc """
  When a connector last read each fact it copies, on disk in Facts' data folder.

  Not a fact: reading the same values again changes nothing in rela (only differences
  are stored), but a page still shows how fresh its copy is. One entry per fact:
  `%{"source" => "GitHub", "read_at" => iso8601 | nil, "failed_at" => iso8601 | nil,
  "failure" => text | nil}`; a failure newer than the last read says why reading failed.

  The connector opens the table; anyone in Facts may look in it.
  """

  @table __MODULE__

  def open(dir) do
    File.mkdir_p!(dir)
    file = dir |> Path.join("copies.dets") |> String.to_charlist()
    {:ok, @table} = :dets.open_file(@table, file: file, type: :set)
    :ok
  end

  def close, do: :dets.close(@table)

  @doc "The entry of `key` of `kind`, or nil (also when no connector runs)."
  def get(kind, key) do
    case :dets.lookup(@table, {kind, key}) do
      [{_, entry}] -> entry
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc "Read just now, at `at`."
  def read(kind, key, source, at),
    do: put(kind, key, source, %{"read_at" => at, "failed_at" => nil, "failure" => nil})

  @doc "Reading failed at `at`, for `reason`; the last good read stays."
  def failed(kind, key, source, at, reason),
    do: put(kind, key, source, %{"failed_at" => at, "failure" => reason})

  defp put(kind, key, source, changes) do
    entry = get(kind, key) || %{"read_at" => nil}
    entry = entry |> Map.merge(changes) |> Map.put("source", source)
    :ok = :dets.insert(@table, {{kind, key}, entry})
    :ok = :dets.sync(@table)
  end
end
