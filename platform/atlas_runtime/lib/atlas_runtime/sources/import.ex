defmodule AtlasRuntime.Sources.Import do
  @moduledoc """
  Imports a leased work's input from the source that offered it (decision §3 "Inputs (F6)",
  §5.1, §6.6 M2; M2 plan W5): its `base{base_id, manifest}` and its optional frozen
  `change_set{manifest, fingerprints}`.

  **Per-source blobs.** Every blob comes from this source: from its own store
  (`AtlasRuntime.Sources.Store`) when it supplied the blob earlier, otherwise downloaded
  through `fetch` (the source's `get_blob` for this lease). A blob another source supplied is
  never used.

  **Caps, while streaming.** Before any content blob is fetched, the input's entries and
  declared bytes are checked against `max_base_entries` and `max_base_bytes`; every blob is
  then counted as it streams and aborted as soon as it runs past its declared size, so no
  more than a cap plus one chunk is ever read. The manifest blobs are capped by the helper's
  own line limits (the base line 64 MiB, a change set 256 MiB). The source's
  `max_store_bytes` bounds its store.

  **Validation.** The base is checked by the S5c P6 validator, the helper's
  `workspace base-import` (entries, roots, paths, symlinks, modes, case folding and every
  blob's sha256 again). It stages the base under `<home>/bases/.staging-*` (entries.json
  and blobs/), publishes the read-only baseline under `<home>/snapshots/`, and the staging
  folder is removed. Its rule refusals are passed on as they are. A change set is checked
  with `AtlasChangeset`; its base must be the imported baseline, and each root's `csf_`
  fingerprint must be the one the work's request names.

  The answer is `{:ok, imported}` with the `baseline_id` to materialize from and, for a
  change set, the file and blob folder `snapshot compose` takes; or `{:refused, reason,
  rule}` with a `work_source` refusal reason (`:invalid`, `:too_large`) and the broken rule:
  the validator's own rule id as it reports it, or one of this module's: `no_base`,
  `input_ref`, `served_other`, `blob_size`, `blob_mismatch`, `blob_malformed`,
  `manifest_too_large`, `stream_too_long`, `max_store_bytes`, `max_base_entries`,
  `max_base_bytes`, `change_set_invalid`, `change_set_fingerprint`, `change_set_base`; or
  `{:error, detail}` when it is not the input's fault (the store or the helper failed, or the
  source did not serve a blob). Neither names a Runtime path.
  """

  alias AtlasRuntime.Sources.Store

  # The helper's limits: a base's line 1 (B7) and a change set file (snapshot compose).
  @max_base_line 64 * 1024 * 1024
  @max_change_set 256 * 1024 * 1024
  @default_timeout_ms 120_000

  @typedoc """
  Fetches one blob of the lease by sha256: `{:ok, %{size, content}}`, the content an
  Enumerable of binaries, or anything else when the source does not serve it.
  """
  @type fetch :: (String.t() -> {:ok, Store.blob()} | term())

  @type imported :: %{
          required(:baseline_id) => String.t(),
          required(:change_set) => nil | %{file: Path.t(), blobs: Path.t()}
        }

  @doc """
  Imports `lease`'s input (`lease.work.input`) from `source` (its policy entry: `"name"`
  and `"max_store_bytes"`) into the Runtime home `home`, fetching what the source's store
  lacks with `fetch`.

  `options`: `max_base_bytes` and `max_base_entries` (the caps on the input, base and change
  set together; without one, only the store quota and the helper's limits apply),
  `timeout_ms` for the helper (120 s).
  """
  @spec base(Path.t(), map(), map(), fetch(), keyword()) ::
          {:ok, imported()}
          | {:refused, :invalid | :too_large, rule :: String.t()}
          | {:error, String.t()}
  def base(home, source, lease, fetch, options \\ []) when is_function(fetch, 1) do
    with {:ok, source} <- source(source),
         {:ok, base, change_set} <- input(lease),
         {:ok, base_file} <-
           obtain(home, source, base.manifest, fetch, {:at_most, @max_base_line}),
         base_files = base_files(base_file),
         {:ok, change_set} <- change_set(home, source, change_set, fetch),
         :ok <- caps(base_files, change_set, options),
         :ok <- obtain_all(home, source, base_files.files, fetch),
         {:ok, baseline_id} <- import_base(home, source, base_file, base_files, options),
         {:ok, change_set} <- compose_input(home, source, change_set, baseline_id, fetch) do
      {:ok, %{baseline_id: baseline_id, change_set: change_set}}
    end
  end

  ## Inputs

  defp source(%{"name" => name, "max_store_bytes" => max} = source)
       when is_integer(max) and max > 0 do
    if Store.valid_source?(name),
      do: {:ok, %{name: name, max_store_bytes: max}},
      else: {:error, "invalid source #{inspect(source["name"])}"}
  end

  defp source(_source), do: {:error, "a source needs a name and max_store_bytes"}

  defp input(%{work: %{input: %{base: %{manifest: manifest}} = input}}) do
    change_set =
      case Map.get(input, :change_set) do
        nil -> nil
        %{manifest: m, fingerprints: f} when is_list(f) -> %{manifest: m, fingerprints: f}
        _ -> :invalid
      end

    cond do
      not Store.valid_sha256?(manifest) ->
        {:refused, :invalid, "input_ref"}

      change_set == :invalid or (change_set && not Store.valid_sha256?(change_set.manifest)) ->
        {:refused, :invalid, "input_ref"}

      true ->
        {:ok, %{manifest: manifest}, change_set}
    end
  end

  defp input(_lease), do: {:refused, :invalid, "no_base"}

  ## Blobs, from this source only

  # The path of this source's blob sha256: from its store, or downloaded and stored. want
  # is the size its entry declares, or {:at_most, cap} for a manifest.
  defp obtain(home, source, sha256, fetch, want) do
    case Store.get(home, source.name, sha256) do
      {:ok, path} ->
        {:ok, path}

      :not_found ->
        case fetch.(sha256) do
          {:ok, %{size: size, content: _} = blob} when is_integer(size) ->
            store(home, source, sha256, blob, want)

          _other ->
            {:error, "the source did not serve blob #{sha256}"}
        end
    end
  end

  defp store(home, source, sha256, blob, want) do
    cond do
      Map.get(blob, :sha256, sha256) != sha256 ->
        {:refused, :invalid, "served_other"}

      too_large?(blob.size, want) ->
        {:refused, :too_large, "manifest_too_large"}

      is_integer(want) and blob.size != want ->
        {:refused, :invalid, "blob_size"}

      true ->
        case Store.put(home, source.name, sha256, blob, source.max_store_bytes) do
          {:ok, path} -> {:ok, path}
          {:error, :too_large} -> {:refused, :too_large, "max_store_bytes"}
          {:error, :too_long} -> {:refused, :too_large, "stream_too_long"}
          {:error, :mismatch} -> {:refused, :invalid, "blob_mismatch"}
          {:error, :invalid} -> {:refused, :invalid, "blob_malformed"}
          {:error, {:io, _}} -> {:error, "cannot store blob #{sha256}"}
        end
    end
  end

  defp too_large?(size, {:at_most, cap}), do: size > cap
  defp too_large?(_size, _want), do: false

  # Every file blob, each with the size its entry declares.
  defp obtain_all(home, source, files, fetch) do
    Enum.reduce_while(files, :ok, fn {sha256, size}, :ok ->
      case obtain(home, source, sha256, fetch, size) do
        {:ok, _path} -> {:cont, :ok}
        other -> {:halt, other}
      end
    end)
  end

  ## Caps

  defp caps(base_files, change_set, options) do
    {entries, bytes} =
      case change_set do
        nil -> {base_files.entries, base_files.bytes}
        cs -> {base_files.entries + cs.entries, base_files.bytes + cs.bytes}
      end

    cond do
      exceeds?(entries, options[:max_base_entries]) ->
        {:refused, :too_large, "max_base_entries"}

      exceeds?(bytes, options[:max_base_bytes]) ->
        {:refused, :too_large, "max_base_bytes"}

      true ->
        :ok
    end
  end

  defp exceeds?(_count, nil), do: false
  defp exceeds?(count, cap) when is_integer(cap), do: count > cap

  ## The base, through the P6 validator

  # The file blobs a base line names, by sha256 with their declared size, and its entry
  # count. What does not fit the shape is left to the validator, which refuses it.
  defp base_files(path) do
    with {:ok, raw} <- File.read(path),
         {:ok, %{"roots" => roots}} when is_list(roots) <- JSON.decode(raw) do
      entries = for %{"entries" => entries} when is_list(entries) <- roots, e <- entries, do: e
      summary(entries)
    else
      _ -> %{entries: 0, bytes: 0, files: %{}}
    end
  end

  # The entry count, the bytes of every file entry (the tree's size, repeated contents
  # counted each time) and the distinct file blobs to fetch.
  defp summary(entries) do
    files = file_blobs(entries)

    bytes =
      for %{"op" => "write", "kind" => "file", "size" => size} when is_integer(size) <- entries,
          reduce: 0,
          do: (sum -> sum + max(size, 0))

    %{entries: length(entries), bytes: bytes, files: files}
  end

  defp file_blobs(entries) do
    for %{"op" => "write", "kind" => "file", "sha256" => sha, "size" => size} <- entries,
        Store.valid_sha256?(sha),
        is_integer(size) and size >= 0,
        into: %{},
        do: {sha, size}
  end

  defp import_base(home, source, base_file, base_files, options) do
    bases = Path.join(home, "bases")

    with :ok <- mkdir(bases) do
      staging = Path.join(bases, ".staging-#{System.unique_integer([:positive])}")

      try do
        with :ok <- mkdir(staging),
             :ok <- mkdir(Path.join(staging, "blobs")),
             :ok <- link(base_file, Path.join(staging, "entries.json")),
             :ok <- link_blobs(home, source, Map.keys(base_files.files), staging) do
          helper(home, staging, Keyword.get(options, :timeout_ms, @default_timeout_ms))
        end
      after
        File.rm_rf(staging)
      end
    end
  end

  defp link_blobs(home, source, shas, staging) do
    Enum.reduce_while(shas, :ok, fn sha, :ok ->
      {:ok, path} = Store.get(home, source.name, sha)

      case link(path, Path.join([staging, "blobs", sha])) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  # A hard link where the file system allows one, else a copy.
  defp link(from, to) do
    case File.ln(from, to) do
      :ok ->
        :ok

      {:error, _} ->
        case File.cp(from, to) do
          :ok -> :ok
          {:error, _} -> {:error, "cannot stage the base"}
        end
    end
  end

  defp helper(home, staging, timeout) do
    executable = System.fetch_env!("ATLAS_RUNTIME_EXECUTABLE")

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        args: ["workspace", "base-import", "--home", home, "--staging", staging],
        env: [{~c"ATLAS_RUNTIME_HOME", String.to_charlist(home)}]
      ])

    # A helper that has already exited has no os_pid any more; its exit status still comes.
    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, os_pid} -> os_pid
        nil -> nil
      end

    collect(port, os_pid, System.monotonic_time(:millisecond) + timeout, [])
  end

  # stdout carries only the result and stderr only the refusal (its code and, for an invalid
  # base, its rule), so the merged output holds either.
  defp collect(port, os_pid, deadline, output) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        collect(port, os_pid, deadline, [output | data])

      {^port, {:exit_status, status}} ->
        answer(status, IO.iodata_to_binary(output))
    after
      remaining ->
        if os_pid,
          do:
            System.cmd("/bin/kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)

        Port.close(port)
        {:error, "base-import timed out"}
    end
  end

  defp answer(0, text) do
    case JSON.decode(text) do
      {:ok, %{"baseline_id" => "sha256:" <> _ = id}} -> {:ok, id}
      _ -> {:error, "base-import printed no result"}
    end
  end

  defp answer(_status, text) do
    case JSON.decode(text) do
      {:ok, %{"code" => "invalid", "rule" => rule}} when is_binary(rule) ->
        {:refused, :invalid, rule}

      {:ok, %{"code" => code}} when is_binary(code) ->
        {:error, "base-import failed: #{code}"}

      _ ->
        {:error, "base-import failed"}
    end
  end

  ## The change set

  # Its manifest, checked before any of its content blobs is fetched: the change set's
  # shape (AtlasChangeset) and each root's csf_ fingerprint against the request.
  defp change_set(_home, _source, nil, _fetch), do: {:ok, nil}

  defp change_set(home, source, ref, fetch) do
    with {:ok, file} <- obtain(home, source, ref.manifest, fetch, {:at_most, @max_change_set}),
         {:ok, set} <- decode_change_set(file),
         :ok <- fingerprints(set, ref.fingerprints) do
      entries = for %{"entries" => entries} <- set["roots"], e <- entries, do: e
      {:ok, Map.merge(summary(entries), %{file: file, set: set})}
    end
  end

  defp decode_change_set(file) do
    with {:ok, raw} <- File.read(file),
         {:ok, %{"base" => _, "roots" => _} = set} <- JSON.decode(raw),
         :ok <- AtlasChangeset.validate(set) do
      {:ok, set}
    else
      _ -> {:refused, :invalid, "change_set_invalid"}
    end
  end

  defp fingerprints(set, expected) do
    computed =
      set
      |> AtlasChangeset.fingerprints()
      |> Enum.map(&{&1.root, &1.fingerprint})
      |> Enum.sort()

    wanted =
      expected
      |> Enum.map(fn ref -> {field(ref, :root), field(ref, :fingerprint)} end)
      |> Enum.sort()

    if computed == wanted,
      do: :ok,
      else: {:refused, :invalid, "change_set_fingerprint"}
  end

  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  # The change set must be on top of exactly the imported base; then its file blobs.
  defp compose_input(_home, _source, nil, _baseline_id, _fetch), do: {:ok, nil}

  defp compose_input(home, source, change_set, baseline_id, fetch) do
    if change_set.set["base"] == baseline_id do
      with :ok <- obtain_all(home, source, change_set.files, fetch) do
        {:ok, %{file: change_set.file, blobs: Store.blobs_dir(home, source.name)}}
      end
    else
      {:refused, :invalid, "change_set_base"}
    end
  end

  defp mkdir(path) do
    case File.mkdir(path) do
      :ok ->
        case File.chmod(path, 0o700) do
          :ok -> :ok
          {:error, _} -> {:error, "cannot stage the base"}
        end

      {:error, :eexist} ->
        :ok

      {:error, _} ->
        {:error, "cannot stage the base"}
    end
  end
end
