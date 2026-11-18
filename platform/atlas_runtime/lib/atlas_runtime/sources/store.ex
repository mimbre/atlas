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

  **One listing per import.** `scan/2` lists the source's folder once: it removes the
  `.partial-*` files a killed writer left behind and counts the complete blobs. `put/6` then
  takes that count and answers the new one, so an import of N blobs lists the folder once,
  not N times. The count is exact: it changes only when a blob is renamed into place. A
  folder that cannot be listed, or a blob that cannot be stat'ed, fails the scan (fails
  closed) rather than counting as empty.

  One process writes a source's store at a time: `AtlasRuntime.Sources.Import.base/5` holds
  the source's `AtlasRuntime.Sources.StoreLock` from its scan to its last put. Concurrent
  writers for the same source could each pass the quota check, and a scan removes the
  other's temporary file; a caller of `scan/2` or `put/5` outside an import must hold that
  lock too.
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

  @doc """
  Starts writing source `name`'s store: removes the `.partial-*` files a killed writer left
  behind, and answers `{:ok, used}`, the bytes of its complete blobs, for `put/6`. A store
  that does not exist yet holds 0 bytes; one that cannot be read is `{:error, {:io, reason}}`.
  """
  @spec scan(Path.t(), String.t()) :: {:ok, non_neg_integer()} | {:error, refusal()}
  def scan(home, name) do
    if valid_source?(name), do: count(blobs_dir(home, name)), else: {:error, :invalid}
  end

  defp count(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        Enum.reduce_while(names, {:ok, 0}, fn file, {:ok, sum} ->
          case entry(dir, file) do
            {:ok, size} -> {:cont, {:ok, sum + size}}
            error -> {:halt, error}
          end
        end)

      {:error, :enoent} ->
        {:ok, 0}

      {:error, reason} ->
        {:error, {:io, reason}}
    end
  end

  # A complete blob counts its size; an orphan temporary file is removed; anything else
  # (no blob name, or not a regular file) is never served and not counted.
  defp entry(dir, file) do
    path = Path.join(dir, file)

    cond do
      String.starts_with?(file, ".partial-") ->
        case File.rm(path) do
          :ok -> {:ok, 0}
          {:error, :enoent} -> {:ok, 0}
          {:error, reason} -> {:error, {:io, reason}}
        end

      valid_sha256?(file) ->
        case File.lstat(path) do
          {:ok, %File.Stat{type: :regular, size: size}} -> {:ok, size}
          {:ok, %File.Stat{}} -> {:ok, 0}
          {:error, :enoent} -> {:ok, 0}
          {:error, reason} -> {:error, {:io, reason}}
        end

      true ->
        {:ok, 0}
    end
  end

  @doc """
  Stores `blob` as source `name`'s blob `sha256` within `max_store_bytes`, listing the folder
  once (`scan/2`). An import of many blobs calls `scan/2` once and then `put/6`.
  """
  @spec put(Path.t(), String.t(), String.t(), blob(), pos_integer()) ::
          {:ok, Path.t()} | {:error, refusal()}
  def put(home, name, sha256, blob, max_store_bytes) do
    with {:ok, used} <- scan(home, name),
         {:ok, path, _used} <- put(home, name, sha256, blob, max_store_bytes, used) do
      {:ok, path}
    end
  end

  @doc """
  Stores `blob` as source `name`'s blob `sha256`, within `max_store_bytes`, given `used`, the
  bytes the store holds (from `scan/2`, or the previous `put/6`). It never lists the folder.

  - `{:ok, path, used}` once the blob is complete, `used` grown by its size; or at once, with
    `used` unchanged, when the source already holds it;
  - `{:error, :too_large}` when its declared size would take the store past
    `max_store_bytes`, checked before a byte is read;
  - `{:error, :too_long}` when its stream runs past its declared size: it is aborted as soon
    as that chunk arrives, so at most the size plus one chunk is read;
  - `{:error, :mismatch}` when the bytes are fewer than declared or their sha256 differs;
  - `{:error, :invalid}` for a malformed name, sha256, size or count;
  - `{:error, {:io, reason}}` when the file cannot be written, or the stream raised.

  On every refusal nothing is stored.
  """
  @spec put(Path.t(), String.t(), String.t(), blob(), pos_integer(), non_neg_integer()) ::
          {:ok, Path.t(), non_neg_integer()} | {:error, refusal()}
  def put(home, name, sha256, %{size: size, content: content}, max_store_bytes, used)
      when is_integer(max_store_bytes) and max_store_bytes > 0 and is_integer(used) and
             used >= 0 do
    cond do
      not (valid_source?(name) and valid_sha256?(sha256)) ->
        {:error, :invalid}

      not (is_integer(size) and size >= 0) ->
        {:error, :invalid}

      true ->
        # One lookup: a blob that disappears after it is simply written again.
        case get(home, name, sha256) do
          {:ok, path} ->
            {:ok, path, used}

          :not_found when used + size > max_store_bytes ->
            {:error, :too_large}

          :not_found ->
            with {:ok, path} <- write(home, name, sha256, size, content),
                 do: {:ok, path, used + size}
        end
    end
  end

  def put(_home, _name, _sha256, _blob, _max_store_bytes, _used), do: {:error, :invalid}

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
