defmodule AtlasRuntime.Sources.Local.Store do
  @moduledoc """
  The built-in local work source's queue under `$ATLAS_RUNTIME_HOME/local-source/`
  (decision §5.4, M2 plan W7/C5). It holds persistence only, as `AtlasRuntime.Work.Store`
  does for the executor: no process and no wiring. It is written only through the private
  model's `encode`/`decode` (`AtlasRuntime.Model.LocalSource`):

  - `local-source/queue/<work_id>.json`: one `queued_work` per work;
  - `local-source/index.json`: every `queue_key_entry`, (client, client key) → `work_id`,
    kept as a tombstone once its queued work is pruned (I3, I7). A pruned work without a
    client key keeps a tombstone too: an entry without a `client_key`, held under
    `{:pruned, work_id}` so that no client key looks it up.

  Every file is written to a temporary file and renamed into place, so a reader sees the
  old or the new content, never a part. A queued work is written before the index entry
  that names it, and an entry is marked pruned before its queued work is deleted, so a
  crash between two writes leaves the index repairable from the queue (`load/1` repairs
  it). `load/1` refuses, never migrates: a file of another `format_version`, or one that
  does not decode, is `{:error, why}`.

  The order (`ordered/1`, `queued/1`) is the adder's priority, a lower number first, then
  FIFO by the add `position`.
  """

  require Logger
  alias AtlasRuntime.Model.LocalSource.{QueueKeyEntry, QueuedWork}

  @folder "local-source"

  @type index_key :: {String.t(), String.t()} | {:pruned, String.t()}
  @type loaded :: %{
          entries: %{String.t() => QueuedWork.t()},
          index: %{index_key() => QueueKeyEntry.t()}
        }

  @doc "The store's folder under the Runtime home."
  def folder(home), do: Path.join(home, @folder)

  @doc "Reads every queued work and the index: `{:ok, loaded}` or `{:error, why}`."
  @spec load(Path.t()) :: {:ok, loaded()} | {:error, String.t()}
  def load(home) do
    with :ok <- clean_temporary(home),
         {:ok, entries} <- load_entries(home),
         {:ok, index} <- load_index(home) do
      {:ok, %{entries: entries, index: repair(index, entries)}}
    end
  end

  @doc "An empty store, as `load/1` gives it for a home without `local-source/`."
  @spec empty() :: loaded()
  def empty, do: %{entries: %{}, index: %{}}

  @doc """
  What (client, client key) names: `{:ok, queued_work}`, `{:pruned, tombstone}` (I7), or
  `:not_found`, which always means never seen.
  """
  def find(%{entries: entries, index: index}, client, client_key) do
    case Map.fetch(index, {client, client_key}) do
      {:ok, %QueueKeyEntry{pruned: true} = tombstone} -> {:pruned, tombstone}
      {:ok, entry} -> found(entries, entry)
      :error -> :not_found
    end
  end

  defp found(entries, entry) do
    case Map.fetch(entries, entry.work_id) do
      {:ok, work} -> {:ok, work}
      :error -> {:pruned, entry}
    end
  end

  @doc """
  Adds a queued work (state `queued`), persisted before it answers (I2), its `position`
  after every one in `loaded`:

  - `{:added, work, loaded}`;
  - `{:existing, work}`: the same client and client key with the same request (I3);
  - `{:conflict, work_id}`: the same client and client key with another request, or a key
    whose work was pruned (its request is gone, so it can never be told the same).
  """
  def add!(home, loaded, attrs) do
    attrs = Map.new(attrs)
    client = Map.fetch!(attrs, :client)
    key = Map.get(attrs, :client_key)

    case key && find(loaded, client, key) do
      {:ok, work} ->
        if same_request?(work, attrs), do: {:existing, work}, else: {:conflict, work.work_id}

      {:pruned, tombstone} ->
        {:conflict, tombstone.work_id}

      _ ->
        work =
          QueuedWork.new!(
            Map.merge(attrs, %{position: next_position(loaded), state: :queued})
            |> Map.drop([:lease_id, :result])
          )

        {:added, work, put!(home, loaded, work)}
    end
  end

  defp same_request?(work, attrs) do
    case QueuedWork.new(Map.merge(Map.from_struct(work), Map.take(attrs, [:request]))) do
      {:ok, other} -> other.request == work.request
      {:error, _} -> false
    end
  end

  defp next_position(%{entries: entries}),
    do: entries |> Map.values() |> Enum.map(& &1.position) |> Enum.max(fn -> 0 end) |> Kernel.+(1)

  @doc """
  Writes one queued work (a change of state, lease or result) and, for a keyed work new to
  the index, its index entry after it. Returns the new `loaded`. A new work is added only
  through `add!/3`, which keeps a pruned key's tombstone (I7).
  """
  def put!(home, loaded, %QueuedWork{} = work) do
    write!(home, QueuedWork.path(work), QueuedWork.encode(work))
    loaded = %{loaded | entries: Map.put(loaded.entries, work.work_id, work)}

    with key when key != nil <- work.client_key && {work.client, work.client_key},
         entry = key_entry(work),
         false <- loaded.index[key] == entry do
      index = Map.put(loaded.index, key, entry)
      put_index!(home, index)
      %{loaded | index: index}
    else
      _ -> loaded
    end
  end

  defp key_entry(work),
    do:
      QueueKeyEntry.new!(
        client: work.client,
        client_key: work.client_key,
        work_id: work.work_id,
        final_kind: final(work),
        pruned: false
      )

  defp final(%QueuedWork{state: :ended, result: %{kind: kind}}), do: kind
  defp final(_work), do: nil

  @doc """
  Queues an ended work again for its next attempt (Main's round 2, a local retry): state
  `queued`, no lease, no result and no pending retry, `attempt` one more than its last,
  `resume` as asked, and a `position` after every one in `loaded`, so it waits behind what
  was added before.
  Returns `{work, loaded}`.
  """
  def requeue!(home, loaded, %QueuedWork{state: :ended} = work, resume?) do
    queued =
      QueuedWork.new!(%{
        work
        | state: :queued,
          lease_id: nil,
          result: nil,
          retry: nil,
          attempt: (work.attempt || 1) + 1,
          resume: if(resume?, do: true),
          position: next_position(loaded)
      })

    {queued, put!(home, loaded, queued)}
  end

  @doc """
  Prunes an ended work: its index entry becomes a tombstone (I7), written before the
  queued work is deleted. A work without a client key gets a tombstone under its own
  `work_id`. Raises for a work that has not ended.
  """
  def prune!(home, loaded, work_id) do
    %QueuedWork{state: :ended, result: %{kind: kind}} = work = Map.fetch!(loaded.entries, work_id)

    key = if work.client_key, do: {work.client, work.client_key}, else: {:pruned, work_id}

    tombstone =
      QueueKeyEntry.new!(
        client: work.client,
        client_key: work.client_key,
        work_id: work_id,
        final_kind: kind,
        pruned: true
      )

    index = Map.put(loaded.index, key, tombstone)
    put_index!(home, index)
    delete!(home, work_id)
    %{entries: Map.delete(loaded.entries, work_id), index: index}
  end

  @doc "The key tombstone of a pruned work (I7), or nil."
  def tombstone(%{index: index}, work_id),
    do: Enum.find(Map.values(index), &(&1.work_id == work_id and &1.pruned))

  @doc "Every queued work in order: priority (a lower number first), then FIFO."
  def ordered(%{entries: entries}),
    do: Enum.sort_by(Map.values(entries), &{&1.priority, &1.position})

  @doc "The works still waiting for a lease, in order."
  def queued(loaded), do: Enum.filter(ordered(loaded), &(&1.state == :queued))

  @doc "Writes the whole index."
  def put_index!(home, index) do
    entries = index |> Map.values() |> Enum.sort_by(&{&1.client, &1.client_key, &1.work_id})
    write!(home, QueueKeyEntry.path(), QueueKeyEntry.encode_file(entries))
  end

  defp delete!(home, work_id) do
    case File.rm(Path.join(home, QueuedWork.path(%{work_id: work_id}))) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> raise File.Error, reason: reason, action: "delete queued work"
    end
  end

  # The store is the source's own: its folders are owner-only whatever the umask, and I8
  # denies them to every worker sandbox too.
  defp write!(home, relative, data) do
    path = Path.join(home, relative)

    for folder <- [folder(home), Path.dirname(path)] do
      File.mkdir_p!(folder)
      File.chmod!(folder, 0o700)
    end

    temporary = path <> ".tmp"
    File.write!(temporary, JSON.encode!(data))
    File.rename!(temporary, path)
  end

  # A temporary file is a write that never got renamed: the file it would replace (or its
  # absence) is what was last written.
  defp clean_temporary(home) do
    for folder <- [folder(home), queue_folder(home)],
        path <- Path.wildcard(Path.join(folder, "*.tmp")),
        do: File.rm(path)

    :ok
  end

  defp load_entries(home) do
    home
    |> queue_folder()
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.reduce_while({:ok, %{}}, fn path, {:ok, entries} ->
      with {:ok, map} <- read_json(path),
           {:ok, work} <- decode(QueuedWork, map),
           :ok <- named(home, path, work) do
        {:cont, {:ok, Map.put(entries, work.work_id, work)}}
      else
        {:error, why} -> {:halt, {:error, "#{relative(home, path)}: #{why}"}}
      end
    end)
  end

  # The folder of every queued work's file, from the model's own path.
  defp queue_folder(home) do
    any_work = QueuedWork.path(%{work_id: "_"})
    home |> Path.join(any_work) |> Path.dirname()
  end

  defp named(home, path, work) do
    if Path.join(home, QueuedWork.path(work)) == path,
      do: :ok,
      else: {:error, "names work #{work.work_id}"}
  end

  defp load_index(home) do
    path = Path.join(home, QueueKeyEntry.path())

    if File.exists?(path) do
      with {:ok, map} <- read_json(path),
           {:ok, entries} <- decode_file(map),
           :ok <- keyed_unless_pruned(entries) do
        index = Map.new(entries, &{index_key(&1), &1})

        if map_size(index) == length(entries),
          do: {:ok, index},
          else: {:error, "#{QueueKeyEntry.path()}: a client key is listed twice"}
      else
        {:error, why} -> {:error, "#{QueueKeyEntry.path()}: #{why}"}
      end
    else
      {:ok, %{}}
    end
  end

  defp decode(module, map) do
    case module.decode(map) do
      {:ok, record} -> {:ok, record}
      {:error, error} -> {:error, inspect(error)}
    end
  end

  defp decode_file(map) do
    case QueueKeyEntry.decode_file(map) do
      {:ok, entries} -> {:ok, entries}
      {:error, error} -> {:error, inspect(error)}
    end
  end

  # Only a keyless work's tombstone has no client key; a live entry without one names nothing.
  defp keyed_unless_pruned(entries) do
    case Enum.find(entries, &(&1.client_key == nil and not &1.pruned)) do
      nil -> :ok
      entry -> {:error, "a live entry for #{entry.work_id} has no client key"}
    end
  end

  defp index_key(%QueueKeyEntry{pruned: true, client_key: nil, work_id: id}), do: {:pruned, id}
  defp index_key(entry), do: {entry.client, entry.client_key}

  # A queued work written before its index entry: the entry is added back. An entry whose
  # work is gone without being pruned is kept and reported; it still answers for its key.
  defp repair(index, entries) do
    index =
      Enum.reduce(Map.values(entries), index, fn work, index ->
        key = {work.client, work.client_key}

        if work.client_key && not Map.has_key?(index, key),
          do: Map.put(index, key, key_entry(work)),
          else: index
      end)

    for {_key, entry} <- index,
        not entry.pruned,
        not Map.has_key?(entries, entry.work_id),
        do: Logger.warning("runtime local source: index entry for #{entry.work_id} has no work")

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

  defp relative(home, path), do: Path.relative_to(path, home)
end
