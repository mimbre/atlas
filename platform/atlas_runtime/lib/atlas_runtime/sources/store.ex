defmodule AtlasRuntime.Sources.Store do
  @moduledoc """
  The per-source blob store (decision §3 "Inputs (F6)", §5.5 `max_store_bytes`; M2 plan W5).

  **Layout.** `<home>/sources/<name>/blobs/<sha256>`, each blob read-only (0444). A blob is
  streamed into a temporary file in the same folder (`.partial-*`) and renamed to its sha256
  only after its size and sha256 match. On any refusal the temporary file is removed, so
  nothing partial is left.

  **Per source.** `has?/3` and `get/3` see only that source's own blobs. A blob another
  source supplied is never used for this source: there is no deduplication across sources
  in M2, so visibility, and the "missing" answer, are per source.

  **Quota.** `max_store_bytes` bounds the bytes of one source's blobs. A blob that would take
  the store past it is refused `too_large` before a byte is written, and the count is kept
  while streaming, so a stream that runs past its declared size is aborted at once.

  One process writes a source's store at a time (the source's puller); concurrent `put/4`s
  for the same source could each pass the quota check.
  """

  # The same rule as the policy's source names: one plain path segment.
  @source ~r/\A[a-z][a-z0-9_-]{0,63}\z/
  @sha256 ~r/\A[0-9a-f]{64}\z/

  @typedoc "A blob as a source serves it: its declared size and its bytes as an Enumerable."
  @type blob :: %{required(:size) => non_neg_integer(), required(:content) => Enumerable.t()}
  @type refusal :: :too_large | :too_long | :mismatch | :invalid | {:io, term()}

  @doc "Whether `name` is a valid source name (one path segment)."
  @spec valid_source?(term()) :: boolean()
  def valid_source?(name), do: is_binary(name) and Regex.match?(@source, name)

  @doc "Whether `sha256` is 64 lowercase hex digits."
  @spec valid_sha256?(term()) :: boolean()
  def valid_sha256?(sha256), do: is_binary(sha256) and Regex.match?(@sha256, sha256)

  @doc "The blob folder of source `name`: `<home>/sources/<name>/blobs`."
  @spec blobs_dir(Path.t(), String.t()) :: Path.t()
  def blobs_dir(home, name) do
    true = valid_source?(name)
    Path.join([home, "sources", name, "blobs"])
  end

  @doc "Whether source `name` holds the blob `sha256`. Never looks at another source."
  @spec has?(Path.t(), String.t(), String.t()) :: boolean()
  def has?(home, name, sha256), do: match?({:ok, _}, get(home, name, sha256))

  @doc "The path of source `name`'s blob `sha256`: `{:ok, path}` or `:not_found`."
  @spec get(Path.t(), String.t(), String.t()) :: {:ok, Path.t()} | :not_found
  def get(home, name, sha256) do
    with true <- valid_source?(name) and valid_sha256?(sha256),
         path = Path.join(blobs_dir(home, name), sha256),
         {:ok, %File.Stat{type: :regular}} <- File.lstat(path) do
      {:ok, path}
    else
      _ -> :not_found
    end
  end

  @doc "The bytes of source `name`'s complete blobs (temporary files are not counted)."
  @spec used_bytes(Path.t(), String.t()) :: non_neg_integer()
  def used_bytes(home, name) do
    dir = blobs_dir(home, name)

    case File.ls(dir) do
      {:ok, names} ->
        for file <- names, valid_sha256?(file), reduce: 0 do
          sum ->
            case File.lstat(Path.join(dir, file)) do
              {:ok, %File.Stat{type: :regular, size: size}} -> sum + size
              _ -> sum
            end
        end

      {:error, _} ->
        0
    end
  end

  @doc """
  Stores `blob` as source `name`'s blob `sha256`, within `max_store_bytes`.

  - `{:ok, path}` once the blob is complete, or at once when the source already holds it;
  - `{:error, :too_large}` when its declared size would take the store past
    `max_store_bytes`, checked before a byte is read;
  - `{:error, :too_long}` when its stream runs past its declared size: it is aborted as soon
    as that chunk arrives, so at most the size plus one chunk is read;
  - `{:error, :mismatch}` when the bytes are fewer than declared or their sha256 differs;
  - `{:error, :invalid}` for a malformed name, sha256 or size;
  - `{:error, {:io, reason}}` when the file cannot be written, or the stream raised.

  On every refusal nothing is stored.
  """
  @spec put(Path.t(), String.t(), String.t(), blob(), pos_integer()) ::
          {:ok, Path.t()} | {:error, refusal()}
  def put(home, name, sha256, %{size: size, content: content}, max_store_bytes)
      when is_integer(max_store_bytes) and max_store_bytes > 0 do
    cond do
      not (valid_source?(name) and valid_sha256?(sha256)) ->
        {:error, :invalid}

      not (is_integer(size) and size >= 0) ->
        {:error, :invalid}

      has?(home, name, sha256) ->
        get(home, name, sha256)

      used_bytes(home, name) + size > max_store_bytes ->
        {:error, :too_large}

      true ->
        write(home, name, sha256, size, content)
    end
  end

  def put(_home, _name, _sha256, _blob, _max_store_bytes), do: {:error, :invalid}

  defp write(home, name, sha256, size, content) do
    dir = blobs_dir(home, name)

    with :ok <- mkdir(Path.join(home, "sources")),
         :ok <- mkdir(Path.dirname(dir)),
         :ok <- mkdir(dir) do
      partial = Path.join(dir, ".partial-#{System.unique_integer([:positive])}")

      try do
        with {:ok, io} <- open(partial),
             result = stream(io, content, size),
             :ok <- close(io, result),
             :ok <- check(result, sha256),
             :ok <- io(File.chmod(partial, 0o444)),
             :ok <- io(File.rename(partial, Path.join(dir, sha256))) do
          {:ok, Path.join(dir, sha256)}
        end
      rescue
        error -> {:error, {:io, Exception.message(error)}}
      catch
        kind, reason -> {:error, {:io, {kind, reason}}}
      after
        File.rm(partial)
      end
    end
  end

  # Copies the stream into io, counting: past the declared size it stops at once.
  defp stream(io, content, size) do
    Enum.reduce_while(content, {:crypto.hash_init(:sha256), 0}, fn chunk, {hash, count} ->
      count = count + IO.iodata_length(chunk)

      if count > size do
        {:halt, {:error, :too_long}}
      else
        case IO.binwrite(io, chunk) do
          :ok -> {:cont, {:crypto.hash_update(hash, chunk), count}}
          {:error, reason} -> {:halt, {:error, {:io, reason}}}
        end
      end
    end)
    |> case do
      {:error, _} = error -> error
      {_hash, count} when count != size -> {:error, :mismatch}
      {hash, _count} -> {:ok, Base.encode16(:crypto.hash_final(hash), case: :lower)}
    end
  end

  defp check({:ok, sha256}, sha256), do: :ok
  defp check({:ok, _other}, _sha256), do: {:error, :mismatch}
  defp check({:error, _} = error, _sha256), do: error

  defp open(path) do
    case File.open(path, [:write, :exclusive, :binary, :raw]) do
      {:ok, io} -> {:ok, io}
      {:error, reason} -> {:error, {:io, reason}}
    end
  end

  defp close(io, result) do
    case {File.close(io), result} do
      {:ok, _} -> :ok
      {{:error, reason}, {:ok, _}} -> {:error, {:io, reason}}
      {_, _} -> :ok
    end
  end

  defp mkdir(path) do
    case File.mkdir(path) do
      :ok -> io(File.chmod(path, 0o700))
      {:error, :eexist} -> :ok
      {:error, reason} -> {:error, {:io, reason}}
    end
  end

  defp io(:ok), do: :ok
  defp io({:error, reason}), do: {:error, {:io, reason}}
end
