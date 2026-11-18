defmodule AtlasFlow.Results.Store do
  @moduledoc """
  The result store's disk (plan m3 §3.4): content-addressed files under one directory.

  - a blob is `<dir>/<aa>/<sha256>`, where `<aa>` is the first two hex digits;
  - a manifest blob (the change set Flow writes for an `ended`) is
    `<dir>/manifests/<aa>/<sha256>`, apart from the blobs so that a boot can tell them apart;
  - every write goes to a file in `<dir>/tmp`, is `fsync`ed and only then `rename`d into place,
    so a writer that dies halfway leaves no visible blob.

  A name is accepted only as 64 lowercase hex digits: no path ever comes from a caller.
  This module keeps no state; `AtlasFlow.Results` owns the index and the caps.
  """

  @sha ~r/\A[0-9a-f]{64}\z/
  @chunk 65_536

  @doc "Whether `name` is a sha256 in lowercase hex (the only names the store takes)."
  @spec sha?(term()) :: boolean()
  def sha?(name), do: is_binary(name) and Regex.match?(@sha, name)

  @spec sha256(iodata()) :: String.t()
  def sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  def blob_path(dir, sha), do: Path.join([dir, binary_part(sha, 0, 2), sha])
  def manifest_path(dir, sha), do: Path.join([dir, "manifests", binary_part(sha, 0, 2), sha])
  def tmp_dir(dir), do: Path.join(dir, "tmp")
  def tmp_path(dir, name), do: Path.join(tmp_dir(dir), name)

  @doc """
  Streams `content` into `tmp` and renames it to `final` once it is whole and right.

  - Bytes are counted **while** they stream: at the first chunk that takes the count past
    `room`, or when `take.(bytes)` answers `:full` (the store cap, counted live by the
    caller), reading stops and the answer is `:too_large`.
  - Then the count must equal `size` and the digest `sha`; otherwise
    `{:rejected, :digest_mismatch}`.
  - Only then is the file `fsync`ed and renamed. On every other answer the temp file is
    removed, so nothing partial is left.
  """
  @spec write(
          Path.t(),
          Path.t(),
          String.t(),
          non_neg_integer(),
          Enumerable.t(),
          non_neg_integer(),
          (non_neg_integer() -> :ok | :full)
        ) ::
          :stored | :too_large | {:rejected, :digest_mismatch}
  def write(tmp, final, sha, size, content, room, take) do
    File.mkdir_p!(Path.dirname(tmp))
    {:ok, io} = :file.open(tmp, [:write, :raw, :binary, :exclusive])

    read =
      try do
        copy(io, content, room, take)
      rescue
        error ->
          :file.close(io)
          File.rm(tmp)
          reraise error, __STACKTRACE__
      end

    case read do
      :too_large ->
        discard(io, tmp, :too_large)

      {hash, count} ->
        if count == size and Base.encode16(:crypto.hash_final(hash), case: :lower) == sha do
          commit(io, tmp, final)
        else
          discard(io, tmp, {:rejected, :digest_mismatch})
        end
    end
  end

  defp copy(io, content, room, take) do
    Enum.reduce_while(content, {:crypto.hash_init(:sha256), 0}, fn chunk, {hash, count} ->
      bytes = IO.iodata_to_binary(chunk)
      count = count + byte_size(bytes)

      cond do
        count > room ->
          {:halt, :too_large}

        take.(byte_size(bytes)) == :full ->
          {:halt, :too_large}

        true ->
          :ok = :file.write(io, bytes)
          {:cont, {:crypto.hash_update(hash, bytes), count}}
      end
    end)
  end

  defp commit(io, tmp, final) do
    :ok = :file.sync(io)
    :ok = :file.close(io)
    File.mkdir_p!(Path.dirname(final))
    :ok = File.rename(tmp, final)
    :stored
  end

  defp discard(io, tmp, answer) do
    :file.close(io)
    File.rm(tmp)
    answer
  end

  @doc "Writes `bytes` whole: temp file, `fsync`, rename."
  @spec put_bytes(Path.t(), Path.t(), iodata()) :: :ok
  def put_bytes(tmp, final, bytes) do
    File.mkdir_p!(Path.dirname(tmp))
    {:ok, io} = :file.open(tmp, [:write, :raw, :binary, :exclusive])
    :ok = :file.write(io, bytes)
    :stored = commit(io, tmp, final)
    :ok
  end

  @doc "Removes the temp directory's leftovers (at boot, when no write can be running)."
  @spec clean_tmp(Path.t()) :: :ok
  def clean_tmp(dir) do
    File.rm_rf!(tmp_dir(dir))
    File.mkdir_p!(tmp_dir(dir))
    :ok
  end

  @doc "Every blob and every manifest on disk, as `%{sha => size}` each."
  @spec scan(Path.t()) :: %{blobs: %{String.t() => non_neg_integer()}, manifests: map()}
  def scan(dir), do: %{blobs: files(dir), manifests: files(Path.join(dir, "manifests"))}

  defp files(root) do
    for path <- Path.wildcard(Path.join([root, "??", "*"])),
        sha = Path.basename(path),
        sha?(sha) and binary_part(sha, 0, 2) == Path.basename(Path.dirname(path)),
        {:ok, %File.Stat{type: :regular, size: size}} <- [File.stat(path)],
        into: %{},
        do: {sha, size}
  end

  @doc "A file's bytes as a lazy stream of chunks."
  @spec stream(Path.t()) :: Enumerable.t()
  def stream(path), do: File.stream!(path, @chunk)

  @spec delete(Path.t()) :: :ok
  def delete(path) do
    File.rm(path)
    :ok
  end
end
