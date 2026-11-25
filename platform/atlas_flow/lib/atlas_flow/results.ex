defmodule AtlasFlow.Results do
  @moduledoc """
  The capped, content-addressed result store (plan m3 §3.4; decision §6.2), and F3a's read
  API. It holds only the blobs a recorded `ended` manifest references, and those manifests;
  no turn output and no base blobs.

  **Caps.** The store cap (default 200 MB) counts every blob and manifest file held, plus
  the bytes of every write still streaming. The result cap (default 20 MB) is the caller's
  sum over one lease, passed in as `room/2`'s `lease_bytes_so_far`. `put/5` checks the
  declared size against the room before it reads a byte, and counts again while the bytes
  stream: at the first byte past the room, or past the store cap, it stops with
  `:too_large` and leaves nothing partial.

  **Pins.** One pin per task. `pin/3` replaces the task's previous pin, and the replaced
  manifest is unpinned at that moment; pinning the manifest the task already has pinned
  changes nothing. `unpin/3` is a cast, so a caller never waits on the store's I/O. A blob is
  kept while some manifest still kept references it.

  **Retention.** A daily sweep deletes a manifest 14 days after it was unpinned, together
  with every blob that no remaining manifest references. A blob no manifest references at
  all is deleted 14 days after it was stored (or after the last rebuild).

  **Index.** The index is a cache, rebuilt from the disk at boot and by `rebuild/2`. The pins
  come from the caller (from Facts): `pins:` is a function the server calls before it serves
  anything, so a pin or unpin sent while it boots queues behind the rebuild. Unpin times are
  not kept on disk, so every manifest the rebuild does not pin counts as unpinned at rebuild
  time: a restart can delay a deletion, never bring one forward.

  **Off.** With no directory (`config :atlas_flow, :results, dir:` unset) every `put` and
  `put_manifest` answers `:too_large`, and every read `:not_found`. The same holds when no
  store is running.

  Options of `start_link/1` (each defaults to `config :atlas_flow, :results`): `dir:`,
  `store_cap:`, `result_cap:` (bytes), `retention_ms:` (14 days), `sweep_ms:` (1 day),
  `clock:` (an `AtlasFlow.Runs.Clock`), `pins:` (a function returning
  `[{task_key, manifest_sha}]`) and `name:` (default `AtlasFlow.Results`; `nil` for none).
  """
  use GenServer

  require Logger

  alias AtlasBus.Envelope
  alias AtlasFlow.Results.Store
  alias AtlasFlow.Runs.Clock

  @day 86_400_000
  @defaults [
    dir: nil,
    store_cap: 200_000_000,
    result_cap: 20_000_000,
    retention_ms: 14 * @day,
    sweep_ms: @day,
    clock: nil,
    pins: nil
  ]

  @type sha :: String.t()

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  def child_spec(opts), do: %{super(opts) | id: Keyword.get(opts, :name, __MODULE__)}

  # -- Writes ---------------------------------------------------------------------------

  @doc "The bytes a lease may still store: the lesser of the result cap and the store cap's room."
  @spec room(non_neg_integer(), GenServer.server()) :: non_neg_integer()
  def room(lease_bytes_so_far, server \\ __MODULE__),
    do: call(server, {:room, lease_bytes_so_far}, 0)

  @doc """
  Stores one blob, read from `content` (an `Enumerable` of binaries) in the caller's
  process. A blob already held is `:stored` at once, with no second copy.
  """
  @spec put(sha(), non_neg_integer(), Enumerable.t(), non_neg_integer(), GenServer.server()) ::
          :stored | :too_large | {:rejected, :digest_mismatch}
  def put(sha, size, content, room, server \\ __MODULE__) do
    if Store.sha?(sha) and is_integer(size) and size >= 0 do
      case call(server, {:begin, sha, size, room}, :too_large) do
        {:write, ref, %{tmp: tmp, final: final, total: total, cap: cap, own: own}} ->
          take = fn bytes ->
            :counters.add(own, 1, bytes)
            if :atomics.add_get(total, 1, bytes) > cap, do: :full, else: :ok
          end

          GenServer.call(
            server,
            {:finish, ref, Store.write(tmp, final, sha, size, content, room, take)}
          )

        answer ->
          answer
      end
    else
      {:rejected, :digest_mismatch}
    end
  end

  @doc """
  Stores a change set as its manifest blob and answers its sha256. The bytes are the change
  set's canonical JSON (keys sorted, `nil` values left out), so the same change set always
  has the same sha. `:too_large` when there is no room (or no store).
  """
  @spec put_manifest(map(), GenServer.server()) :: {:ok, sha()} | :too_large
  def put_manifest(change_set, server \\ __MODULE__) do
    bytes = canonical(change_set)
    sha = Store.sha256(bytes)
    call(server, {:manifest, sha, bytes, references(JSON.decode!(bytes))}, :too_large)
  end

  @doc """
  Pins `manifest_sha` for `task_key`, replacing the task's previous pin (whose retention
  clock starts now). A no-op when the task already pins that manifest.
  """
  @spec pin(String.t(), sha(), GenServer.server()) :: :ok | :not_found
  def pin(task_key, manifest_sha, server \\ __MODULE__),
    do: call(server, {:pin, task_key, manifest_sha}, :not_found)

  @doc "Unpins the task's manifest as of `at`; its retention clock starts then. A cast."
  @spec unpin(String.t(), DateTime.t(), GenServer.server()) :: :ok
  def unpin(task_key, %DateTime{} = at, server \\ __MODULE__),
    do: GenServer.cast(server, {:unpin, task_key, at})

  @doc """
  Rebuilds the index from the disk and `pins` (`[{task_key, manifest_sha}]`, derived by the
  caller from Facts). Every manifest on disk not in `pins` counts as unpinned now.
  """
  @spec rebuild([{String.t(), sha()}], GenServer.server()) :: :ok
  def rebuild(pins, server \\ __MODULE__), do: call(server, {:rebuild, pins}, :ok)

  # -- Reads (F3a) ----------------------------------------------------------------------

  @doc "The change set the task has pinned."
  @spec manifest(String.t(), GenServer.server()) :: {:ok, map()} | :not_found
  def manifest(task_key, server \\ __MODULE__),
    do: server |> call({:manifest_of, task_key}, :not_found) |> decode()

  @doc "The change set stored under `sha`, pinned or not."
  @spec manifest_by_sha(sha(), GenServer.server()) :: {:ok, map()} | :not_found
  def manifest_by_sha(sha, server \\ __MODULE__),
    do: server |> call({:manifest_path, sha}, :not_found) |> decode()

  @doc "A stored blob: its size and a lazy stream of its bytes."
  @spec blob(sha(), GenServer.server()) :: {:ok, non_neg_integer(), Enumerable.t()} | :not_found
  def blob(sha, server \\ __MODULE__) do
    case call(server, {:blob, sha}, :not_found) do
      {:ok, size, path} -> {:ok, size, Store.stream(path)}
      :not_found -> :not_found
    end
  end

  defp decode({:ok, path}) do
    case File.read(path) do
      {:ok, bytes} -> {:ok, JSON.decode!(bytes)}
      {:error, _} -> :not_found
    end
  end

  defp decode(:not_found), do: :not_found

  defp call(server, message, otherwise) do
    GenServer.call(server, message, :infinity)
  catch
    :exit, {:noproc, _} -> otherwise
    :exit, {{:shutdown, _}, _} -> otherwise
  end

  # -- Server ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    opts =
      Keyword.merge(
        @defaults,
        Keyword.merge(Application.get_env(:atlas_flow, :results, []), opts)
      )

    state = %{
      dir: opts[:dir],
      clock: opts[:clock],
      store_cap: opts[:store_cap],
      result_cap: opts[:result_cap],
      retention_ms: opts[:retention_ms],
      sweep_ms: opts[:sweep_ms],
      total: :atomics.new(1, signed: true),
      blobs: %{},
      manifests: %{},
      pins: %{},
      unpinned: %{},
      writes: %{}
    }

    {:ok, state, {:continue, {:boot, opts[:pins] || fn -> [] end}}}
  end

  @impl true
  def handle_continue({:boot, _pins}, %{dir: nil} = state), do: {:noreply, state}

  def handle_continue({:boot, pins}, state) do
    Store.clean_tmp(state.dir)
    schedule(state)
    {:noreply, index(state, pins.())}
  end

  @impl true
  def handle_call({:room, so_far}, _from, state),
    do: {:reply, room_for(state, so_far), state}

  def handle_call({:begin, _sha, _size, _room}, _from, %{dir: nil} = state),
    do: {:reply, :too_large, state}

  def handle_call({:begin, sha, size, room}, {pid, _}, state) do
    cond do
      Map.has_key?(state.blobs, sha) and state.blobs[sha].size == size ->
        {:reply, :stored, state}

      Map.has_key?(state.blobs, sha) ->
        {:reply, {:rejected, :digest_mismatch}, state}

      size > min(room, free(state)) ->
        {:reply, :too_large, state}

      true ->
        ref = make_ref()

        write = %{
          pid: pid,
          monitor: Process.monitor(pid),
          own: :counters.new(1, []),
          tmp: Store.tmp_path(state.dir, tmp_name()),
          sha: sha,
          size: size
        }

        reply = %{
          tmp: write.tmp,
          final: Store.blob_path(state.dir, sha),
          total: state.total,
          cap: state.store_cap,
          own: write.own
        }

        {:reply, {:write, ref, reply}, put_in(state.writes[ref], write)}
    end
  end

  # A write this server never began (it restarted while the bytes streamed): the answer
  # stands, and a renamed blob is indexed by the next rebuild.
  def handle_call({:finish, ref, answer}, _from, state) when not is_map_key(state.writes, ref),
    do: {:reply, answer, state}

  def handle_call({:finish, ref, answer}, _from, state) do
    {write, state} = pop_in(state.writes[ref])
    Process.demonitor(write.monitor, [:flush])
    :atomics.sub(state.total, 1, :counters.get(write.own, 1))

    state =
      if answer == :stored and not Map.has_key?(state.blobs, write.sha),
        do: add_blob(state, write.sha, write.size),
        else: state

    {:reply, answer, state}
  end

  def handle_call({:manifest, _sha, _bytes, _refs}, _from, %{dir: nil} = state),
    do: {:reply, :too_large, state}

  def handle_call({:manifest, sha, bytes, refs}, _from, state) do
    cond do
      Map.has_key?(state.manifests, sha) ->
        {:reply, {:ok, sha}, state}

      byte_size(bytes) > free(state) ->
        {:reply, :too_large, state}

      true ->
        Store.put_bytes(
          Store.tmp_path(state.dir, tmp_name()),
          Store.manifest_path(state.dir, sha),
          bytes
        )

        :atomics.add(state.total, 1, byte_size(bytes))
        state = put_in(state.manifests[sha], %{size: byte_size(bytes), refs: refs})
        {:reply, {:ok, sha}, put_in(state.unpinned[sha], now(state))}
    end
  end

  def handle_call({:pin, task_key, sha}, _from, state) do
    cond do
      not Map.has_key?(state.manifests, sha) -> {:reply, :not_found, state}
      state.pins[task_key] == sha -> {:reply, :ok, state}
      true -> {:reply, :ok, replace_pin(state, task_key, sha)}
    end
  end

  def handle_call({:rebuild, _pins}, _from, %{dir: nil} = state), do: {:reply, :ok, state}
  def handle_call({:rebuild, pins}, _from, state), do: {:reply, :ok, index(state, pins)}

  def handle_call({:manifest_of, task_key}, _from, state) do
    case state.pins do
      %{^task_key => sha} -> {:reply, {:ok, Store.manifest_path(state.dir, sha)}, state}
      _ -> {:reply, :not_found, state}
    end
  end

  def handle_call({:manifest_path, sha}, _from, state) do
    if Map.has_key?(state.manifests, sha),
      do: {:reply, {:ok, Store.manifest_path(state.dir, sha)}, state},
      else: {:reply, :not_found, state}
  end

  def handle_call({:blob, sha}, _from, state) do
    case state.blobs do
      %{^sha => %{size: size}} -> {:reply, {:ok, size, Store.blob_path(state.dir, sha)}, state}
      _ -> {:reply, :not_found, state}
    end
  end

  @impl true
  def handle_cast({:unpin, task_key, at}, state) do
    case Map.pop(state.pins, task_key) do
      {nil, _} -> {:noreply, state}
      {sha, pins} -> {:noreply, release(%{state | pins: pins}, sha, at)}
    end
  end

  @impl true
  def handle_info(:sweep, state) do
    schedule(state)
    {:noreply, sweep(state, now(state))}
  end

  # A writer that died before it finished: its temp file and its counted bytes go.
  def handle_info({:DOWN, monitor, :process, _, _}, state) do
    case Enum.find(state.writes, fn {_, write} -> write.monitor == monitor end) do
      {ref, write} ->
        :atomics.sub(state.total, 1, :counters.get(write.own, 1))
        File.rm(write.tmp)
        {:noreply, %{state | writes: Map.delete(state.writes, ref)}}

      nil ->
        {:noreply, state}
    end
  end

  # A Bus answer no read waits for any more: the boot's read of the pins
  # (`AtlasFlow.WorkSource.Leases.pins/0`, run in this process) gave up on Facts before
  # Facts answered (a slow Facts at a deploy). The pins came from the read that did answer,
  # or none: this late one is ignored.
  def handle_info({:atlas_bus, %Envelope{} = envelope, _content}, state) do
    Logger.info(
      "flow results ignored a late Bus #{envelope.class} of kind #{envelope.kind} " <>
        "from #{envelope.sender} (#{envelope.id})"
    )

    {:noreply, state}
  end

  def handle_info(message, state) do
    Logger.info("flow results ignored an unexpected message: #{inspect(message, limit: 5)}")
    {:noreply, state}
  end

  # -- Index, pins, sweep ---------------------------------------------------------------

  defp room_for(%{dir: nil}, _so_far), do: 0

  defp room_for(state, so_far),
    do: max(0, min(state.result_cap - so_far, free(state)))

  defp free(state), do: max(0, state.store_cap - :atomics.get(state.total, 1))

  defp add_blob(state, sha, size) do
    :atomics.add(state.total, 1, size)
    put_in(state.blobs[sha], %{size: size, since: now(state)})
  end

  defp replace_pin(state, task_key, sha) do
    previous = state.pins[task_key]

    state = %{
      state
      | pins: Map.put(state.pins, task_key, sha),
        unpinned: Map.delete(state.unpinned, sha)
    }

    if previous, do: release(state, previous, now(state)), else: state
  end

  # A manifest's clock starts once no task pins it any more.
  defp release(state, sha, at) do
    if sha in Map.values(state.pins) or not Map.has_key?(state.manifests, sha),
      do: state,
      else: %{state | unpinned: Map.put_new(state.unpinned, sha, at)}
  end

  defp index(state, pins) do
    now = now(state)
    %{blobs: blobs, manifests: on_disk} = Store.scan(state.dir)

    manifests =
      Map.new(on_disk, fn {sha, size} -> {sha, %{size: size, refs: read_refs(state.dir, sha)}} end)

    pins =
      for {task_key, sha} <- pins, Map.has_key?(manifests, sha), into: %{}, do: {task_key, sha}

    pinned = MapSet.new(Map.values(pins))
    writing = state.writes |> Map.values() |> Enum.map(&:counters.get(&1.own, 1)) |> Enum.sum()
    held = Enum.sum(Map.values(blobs)) + Enum.sum(Map.values(on_disk))
    :atomics.put(state.total, 1, held + writing)

    %{
      state
      | blobs: Map.new(blobs, fn {sha, size} -> {sha, %{size: size, since: now}} end),
        manifests: manifests,
        pins: pins,
        unpinned: for({sha, _} <- manifests, sha not in pinned, into: %{}, do: {sha, now})
    }
  end

  defp read_refs(dir, sha) do
    with {:ok, bytes} <- File.read(Store.manifest_path(dir, sha)),
         {:ok, change_set} <- JSON.decode(bytes) do
      references(change_set)
    else
      _ -> MapSet.new()
    end
  end

  defp sweep(state, now) do
    expired =
      for {sha, at} <- state.unpinned,
          DateTime.diff(now, at, :millisecond) >= state.retention_ms,
          do: sha

    freed =
      expired |> Enum.map(&state.manifests[&1].refs) |> Enum.reduce(MapSet.new(), &MapSet.union/2)

    for sha <- expired do
      Store.delete(Store.manifest_path(state.dir, sha))
      :atomics.sub(state.total, 1, state.manifests[sha].size)
    end

    state = %{
      state
      | manifests: Map.drop(state.manifests, expired),
        unpinned: Map.drop(state.unpinned, expired)
    }

    kept =
      state.manifests
      |> Map.values()
      |> Enum.map(& &1.refs)
      |> Enum.reduce(MapSet.new(), &MapSet.union/2)

    gone =
      for {sha, blob} <- state.blobs,
          not MapSet.member?(kept, sha),
          MapSet.member?(freed, sha) or
            DateTime.diff(now, blob.since, :millisecond) >= state.retention_ms,
          do: sha

    for sha <- gone do
      Store.delete(Store.blob_path(state.dir, sha))
      :atomics.sub(state.total, 1, state.blobs[sha].size)
    end

    %{state | blobs: Map.drop(state.blobs, gone)}
  end

  defp schedule(state), do: Clock.schedule(state.clock, self(), :sweep, state.sweep_ms)
  defp now(state), do: Clock.now(state.clock)
  defp tmp_name, do: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

  # -- Manifest encoding ----------------------------------------------------------------

  # The blobs a change set references: the sha256 of each write entry.
  defp references(change_set) do
    for %{"entries" => entries} <- List.wrap(change_set["roots"]),
        %{"op" => "write", "sha256" => sha} <- List.wrap(entries),
        Store.sha?(sha),
        into: MapSet.new(),
        do: sha
  end

  @doc false
  # Canonical JSON: string keys in sorted order, `nil` values and struct tags left out.
  def canonical(term), do: term |> normal() |> encode() |> IO.iodata_to_binary()

  defp normal(%{__struct__: _} = struct), do: struct |> Map.from_struct() |> normal()

  defp normal(map) when is_map(map),
    do: for({k, v} <- map, v != nil, into: %{}, do: {to_string(k), normal(v)})

  defp normal(list) when is_list(list), do: Enum.map(list, &normal/1)

  defp normal(atom) when is_atom(atom) and atom not in [nil, true, false],
    do: Atom.to_string(atom)

  defp normal(other), do: other

  defp encode(map) when is_map(map) do
    pairs =
      map
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {k, v} -> [JSON.encode!(k), ?:, encode(v)] end)

    [?{, Enum.intersperse(pairs, ?,), ?}]
  end

  defp encode(list) when is_list(list),
    do: [?[, Enum.intersperse(Enum.map(list, &encode/1), ?,), ?]]

  defp encode(value), do: JSON.encode!(value)
end
