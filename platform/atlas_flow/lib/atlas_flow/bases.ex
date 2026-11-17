defmodule AtlasFlow.Bases do
  @moduledoc """
  Bases for Runtimes, served from Code (work acquisition decision §6.3, "F1.5 replaced";
  D41: a Runtime never talks to Code).

  A base is what a Runtime builds a workspace from: `%{base_id, manifest, snapshot_id}`.
  Flow resolves a repository's reference to a revision, snapshots that revision in Code and
  derives the base from Code's manifest:

  - `base_id` is `"code-"` followed by the 64 hex digits of the snapshot ID. One revision
    has one snapshot, so it has one base, and a base is reused for as long as it lives.
  - `manifest` is the sha256 (64 lowercase hex) of the base's manifest blob: the Runtime's
    base line (S5c P6 B3, what W5's base import stages as `entries.json` for
    `workspace base-import`), one line ending in a newline. It is the canonical JSON (keys
    sorted, no whitespace) of `{"format":"atlas-base","roots":[{"entries":[<write
    entry>…],"root":<root>}],"version":1}`, the entries in the change-set write shape
    (`AtlasChangeset`), paths relative to the root and sorted by path. The root is the
    repository's last name, and the snapshot places the repository at it.

  Its blobs are read through from Code, never copied: `blob/3` streams them.

  **No caller waits on Code.** Bases is a process with an ETS table. `cached/3` reads only
  the table and answers `{:ok, base}`, `:missing` or `:unavailable`; with Bases not running
  (no table) it answers `:unavailable`. `request/4` returns at once: Bases resolves in a
  task of its own and sends each `notify` (`{pid, message}`) once the base is cached. Requests
  for one reference share one resolution. When Code fails or takes longer than 15 s the
  reference is `:unavailable`; Bases tries again after 30 s and keeps the notifies waiting.

  **Pinned by snapshot (M3 A4).** A lease keeps the Code snapshot its base was made from
  (`base_snapshot`, beside `base_id` on its intent and task fact). Code snapshots are
  immutable by id, while a reference moves. So after a restart (an empty table), Bases
  restores a held lease's base with `restore/4`: from that snapshot id alone
  (`get_manifest`), never by resolving the reference again, and only when the manifest
  it derives is the lease's. The lease is then served the same base, byte for byte, also
  once the branch moved on.

  One manifest can come from more than one snapshot (a new revision with the same tree).
  Bases keeps, per manifest, every snapshot it derived that manifest from, and serves the
  manifest blob to each of them, never to another snapshot. `held?/3` asks whether a
  lease's own snapshot is among them.

  The work source starts it (M3 A2), before the Engine (A4).
  """
  use GenServer

  require Logger

  alias AtlasFlow.Code.Client
  alias AtlasFlow.Runs.Clock

  @timeout 15_000
  @retry 30_000

  @type base :: %{base_id: String.t(), manifest: String.t(), snapshot_id: String.t()}

  ## Interface

  @doc """
  Starts Bases. Options: `name` (default `AtlasFlow.Bases`, also its table's name),
  `client` (an `AtlasFlow.Code.Client`, default the facade), `clock`, `timeout`, `retry`.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.put(opts, :name, name), name: name)
  end

  @doc "The base of `reference` as cached: `{:ok, base}`, `:missing` or `:unavailable`. Never calls Code."
  @spec cached(String.t(), String.t(), atom()) :: {:ok, base()} | :missing | :unavailable
  def cached(repository, reference, server \\ __MODULE__) do
    case lookup(server, {:reference, repository, reference}) do
      {:ok, {:ok, base}} -> {:ok, base}
      {:ok, :unavailable} -> :unavailable
      :none -> :missing
      :no_table -> :unavailable
    end
  end

  @doc """
  Asks for the base of `reference`; `notify` (`{pid, message}`) is sent `message` once it is
  cached (at once when it already is). Returns `:ok` at once, also when Bases is not running.
  """
  @spec request(String.t(), String.t(), {pid(), term()}, atom()) :: :ok
  def request(repository, reference, {pid, _message} = notify, server \\ __MODULE__)
      when is_pid(pid),
      do: GenServer.cast(server, {:request, {repository, reference}, notify})

  @doc """
  Restores the base of a held lease from the Code snapshot it was made from
  (`snapshot_id`), when Bases does not hold its `manifest` (after a restart). Returns
  `:ok` at once, also when Bases is not running. Bases reads that snapshot's manifest in
  its own task, never resolves a reference, and keeps the base only when the manifest it
  derives has the sha256 `manifest`; a failing Code is tried again after 30 s.
  """
  @spec restore(String.t(), String.t(), String.t(), atom()) :: :ok
  def restore(repository, snapshot_id, manifest, server \\ __MODULE__)
      when is_binary(repository) and is_binary(snapshot_id) and is_binary(manifest),
      do: GenServer.cast(server, {:restore, {:snapshot, repository, snapshot_id, manifest}})

  @doc """
  Whether Bases holds `manifest` as derived from `snapshot_id`: the lease pinning that
  snapshot is served its manifest blob. Reads the table only; `false` when Bases is not
  running.
  """
  @spec held?(String.t(), String.t(), atom()) :: boolean()
  def held?(manifest, snapshot_id, server \\ __MODULE__) do
    case lookup(server, {:manifest, manifest}) do
      {:ok, %{snapshots: snapshots}} -> MapSet.member?(snapshots, snapshot_id)
      _ -> false
    end
  end

  @doc """
  Every name a lease on this base may read: the manifest blob's sha256 and the sha256 of
  each of its write entries. `:not_found` for a manifest Bases does not hold.
  """
  @spec names(String.t(), atom()) :: {:ok, MapSet.t(String.t())} | :not_found
  def names(manifest, server \\ __MODULE__) do
    case lookup(server, {:manifest, manifest}) do
      {:ok, %{document: document}} -> {:ok, names_of(manifest, document)}
      _ -> :not_found
    end
  end

  @doc "The names of a manifest document (decoded), with `manifest` its sha256."
  @spec names_of(String.t(), map()) :: MapSet.t(String.t())
  def names_of(manifest, %{"roots" => roots}) do
    for %{"entries" => entries} <- roots,
        %{"op" => "write", "sha256" => sha256} <- entries,
        into: MapSet.new([manifest]),
        do: sha256
  end

  @doc """
  One blob of a base: the manifest blob itself (only to a snapshot Bases derived it from),
  or an entry's blob read through from Code (a stream; no blob is held whole). `{:ok, size, stream}`, `:not_found` or `:unavailable`.
  Called in the caller's process: it reads Code, so it is never called on the Engine's path.
  """
  @spec blob(String.t(), String.t(), atom()) ::
          {:ok, non_neg_integer(), Enumerable.t()} | :not_found | :unavailable
  def blob(sha256, snapshot_id, server \\ __MODULE__) do
    case lookup(server, {:manifest, sha256}) do
      {:ok, %{snapshots: snapshots, bytes: bytes}} ->
        if MapSet.member?(snapshots, snapshot_id),
          do: {:ok, byte_size(bytes), [bytes]},
          else: :not_found

      :no_table ->
        :unavailable

      :none ->
        {:ok, client} = lookup(server, :client)

        case Client.get_blob(client, snapshot_id, sha256) do
          {:ok, size, stream} -> {:ok, size, stream}
          {:error, :not_found} -> :not_found
          {:error, _} -> :unavailable
        end
    end
  end

  @doc """
  Resolves the base of `reference` with `client`, in the caller: `{:ok, base}` or
  `{:error, tag}`. Bases runs this in its own task, never in a caller of `cached/3` or
  `request/4`.
  """
  @spec for(Client.t(), String.t(), String.t()) :: {:ok, base()} | {:error, atom()}
  def for(client, repository, reference) do
    with {:ok, _revision, made} <- resolution(client, repository, reference, fn _ -> nil end),
         do: {:ok, made.base}
  end

  # `known` gives what was already made for a revision, so one revision is never
  # snapshotted twice.
  defp resolution(client, repository, reference, known) do
    with {:ok, revision} <- Client.resolve_reference(client, repository, reference) do
      case known.(revision) do
        nil -> snapshot(client, repository, revision)
        made -> {:ok, revision, made}
      end
    end
  end

  defp snapshot(client, repository, revision) do
    placement = %{repository: repository, revision: revision, path: root(repository)}

    with {:ok, snapshot_id} <- Client.create_snapshot(client, [placement]),
         {:ok, made} <- made(client, repository, snapshot_id),
         do: {:ok, revision, made}
  end

  # The base of a snapshot, from its manifest alone: what a snapshot id pins.
  defp made(client, repository, snapshot_id) do
    with {:ok, entries} <- Client.get_manifest(client, snapshot_id) do
      document = document(root(repository), entries)
      bytes = line(document)
      "sha256:" <> hex = snapshot_id

      base = %{base_id: "code-" <> hex, manifest: sha256(bytes), snapshot_id: snapshot_id}
      {:ok, %{base: base, document: document, bytes: bytes}}
    end
  end

  # A held lease's base, again from its snapshot id; only the lease's own manifest is kept.
  defp pinned(client, repository, snapshot_id, manifest) do
    case made(client, repository, snapshot_id) do
      {:ok, %{base: %{manifest: ^manifest}} = made} -> {:ok, :pinned, made}
      {:ok, _other} -> {:error, :manifest_mismatch}
      error -> error
    end
  end

  # The manifest document: Code's entries under the root, in the change-set write shape.
  defp document(root, entries) do
    prefix = root <> "/"

    entries =
      for %{path: ^prefix <> path} = entry <- entries do
        write = %{
          "kind" => entry.kind,
          "mode" => entry.mode,
          "op" => "write",
          "path" => path,
          "sha256" => entry.sha256,
          "size" => entry.size
        }

        if entry.kind == "symlink", do: Map.put(write, "target", entry.target), else: write
      end

    %{
      "format" => "atlas-base",
      "version" => 1,
      "roots" => [%{"root" => root, "entries" => Enum.sort_by(entries, & &1["path"])}]
    }
  end

  @doc "The manifest blob of a document: its canonical JSON as one line, ending in a newline."
  @spec line(map()) :: binary()
  def line(document), do: canonical(document) <> "\n"

  defp root(repository), do: repository |> String.split("/") |> List.last()

  @doc """
  The canonical JSON of a document: object keys in byte order, no whitespace. Lists keep
  their order; integers in decimal. Strings are escaped as `AtlasChangeset` escapes them,
  byte by byte and never by a general JSON encoder: `"` is `\\"`, `\\` is `\\\\`,
  U+0000..U+001F is `\\u00xx` (lowercase hex), every other code point its literal UTF-8.
  """
  def canonical(value), do: value |> encode() |> IO.iodata_to_binary()

  defp encode(map) when is_map(map) do
    pairs =
      map
      |> Enum.sort_by(fn {key, _} -> key end)
      |> Enum.map_intersperse(?,, fn {key, value} -> [string(key), ?:, encode(value)] end)

    [?{, pairs, ?}]
  end

  defp encode(list) when is_list(list), do: [?[, Enum.map_intersperse(list, ?,, &encode/1), ?]]
  defp encode(value) when is_binary(value), do: string(value)
  defp encode(value) when is_integer(value), do: Integer.to_string(value)

  defp string(value) do
    escaped =
      for <<byte <- value>>, into: "" do
        case byte do
          ?" -> ~S(\")
          ?\\ -> ~S(\\)
          byte when byte < 0x20 -> "\\u00" <> Base.encode16(<<byte>>, case: :lower)
          byte -> <<byte>>
        end
      end

    [?", escaped, ?"]
  end

  defp sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp lookup(server, key) do
    case :ets.whereis(server) do
      :undefined ->
        :no_table

      table ->
        case :ets.lookup(table, key) do
          [{^key, value}] -> {:ok, value}
          [] -> :none
        end
    end
  end

  ## Server

  @impl true
  def init(opts) do
    table =
      :ets.new(Keyword.fetch!(opts, :name), [:named_table, :protected, read_concurrency: true])

    client = Keyword.get(opts, :client, Client.default())
    :ets.insert(table, {:client, client})
    {:ok, tasks} = Task.Supervisor.start_link()

    {:ok,
     %{
       table: table,
       client: client,
       tasks: tasks,
       clock: Keyword.get(opts, :clock),
       timeout: Keyword.get(opts, :timeout, @timeout),
       retry: Keyword.get(opts, :retry, @retry),
       # {repository, reference} => %{status: :idle | :resolving | :waiting, notifies, task, timer}
       pending: %{}
     }}
  end

  @impl true
  def handle_cast({:request, {repository, reference} = key, notify}, state) do
    case cached(repository, reference, state.table) do
      {:ok, _base} ->
        send_notify(notify)
        {:noreply, state}

      _missing_or_unavailable ->
        {:noreply, state |> wait(key, notify) |> resolve(key)}
    end
  end

  def handle_cast({:restore, {:snapshot, _, snapshot_id, manifest} = key}, state) do
    if held?(manifest, snapshot_id, state.table),
      do: {:noreply, state},
      else: {:noreply, state |> wait(key, nil) |> resolve(key)}
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish(state, ref, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state),
    do: {:noreply, finish(state, ref, {:error, :crashed})}

  def handle_info({:timeout, key, ref}, state) do
    case state.pending[key] do
      %{status: :resolving, task: %{ref: ^ref} = task} ->
        Task.shutdown(task, :brutal_kill)
        {:noreply, finish(state, ref, {:error, :timeout})}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:retry, key}, state) do
    case state.pending[key] do
      %{status: :waiting} = entry ->
        state = put_in(state.pending[key], %{entry | status: :idle, timer: nil})
        {:noreply, resolve(state, key)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp wait(state, key, notify) do
    entry = Map.get(state.pending, key, %{status: :idle, notifies: [], task: nil, timer: nil})
    notifies = if notify, do: entry.notifies ++ [notify], else: entry.notifies
    put_in(state.pending[key], %{entry | notifies: notifies})
  end

  # One resolution per reference at a time, in a task: Code is never called from here, nor
  # from a caller. While a reference waits for its retry, requests only add their notify.
  defp resolve(state, key) do
    case state.pending[key] do
      %{status: :idle} = entry ->
        job = job(state, key)
        task = Task.Supervisor.async_nolink(state.tasks, job)

        timer = Clock.schedule(state.clock, self(), {:timeout, key, task.ref}, state.timeout)
        put_in(state.pending[key], %{entry | status: :resolving, task: task, timer: timer})

      _resolving_or_waiting ->
        state
    end
  end

  defp finish(state, ref, result) do
    case Enum.find(state.pending, fn {_key, entry} -> match?(%{task: %{ref: ^ref}}, entry) end) do
      nil -> state
      {key, entry} -> finish(state, key, entry, result)
    end
  end

  defp finish(state, {:snapshot, _repository, _snapshot_id, _manifest} = key, entry, result) do
    Clock.cancel(state.clock, entry.timer)

    case result do
      {:ok, :pinned, made} ->
        keep_manifest(state.table, made)

        %{state | pending: Map.delete(state.pending, key)}

      # Not this lease's base: Bases does not try it again (the Engine may ask once more).
      {:error, :manifest_mismatch} ->
        Logger.warning("flow bases: snapshot #{elem(key, 2)} does not give its lease's manifest")
        %{state | pending: Map.delete(state.pending, key)}

      _failure ->
        timer = Clock.schedule(state.clock, self(), {:retry, key}, state.retry)
        put_in(state.pending[key], %{entry | status: :waiting, task: nil, timer: timer})
    end
  end

  defp finish(state, {repository, reference} = key, entry, result) do
    Clock.cancel(state.clock, entry.timer)

    case result do
      {:ok, revision, made} ->
        :ets.insert(state.table, {{:revision, repository, revision}, made})
        keep_manifest(state.table, made)
        :ets.insert(state.table, {{:reference, repository, reference}, {:ok, made.base}})

        Enum.each(entry.notifies, &send_notify/1)
        %{state | pending: Map.delete(state.pending, key)}

      _failure ->
        :ets.insert(state.table, {{:reference, repository, reference}, :unavailable})
        timer = Clock.schedule(state.clock, self(), {:retry, key}, state.retry)
        put_in(state.pending[key], %{entry | status: :waiting, task: nil, timer: timer})
    end
  end

  # A manifest's entry keeps every snapshot it was derived from: a later snapshot of the
  # same tree adds to them, never replaces them (a held lease's pin stays served).
  defp keep_manifest(table, %{base: base} = made) do
    key = {:manifest, base.manifest}

    held =
      case :ets.lookup(table, key) do
        [{^key, %{snapshots: snapshots}}] -> snapshots
        [] -> MapSet.new()
      end

    :ets.insert(table, {key, Map.put(made, :snapshots, MapSet.put(held, base.snapshot_id))})
  end

  defp send_notify({pid, message}), do: send(pid, message)

  # What a pending entry runs in Bases' task: a reference resolved (and snapshotted once
  # per revision), or a lease's base rebuilt from its pinned snapshot id.
  defp job(%{client: client}, {:snapshot, repository, snapshot_id, manifest}),
    do: fn -> pinned(client, repository, snapshot_id, manifest) end

  defp job(%{table: table, client: client}, {repository, reference}) do
    known = fn revision ->
      case :ets.lookup(table, {:revision, repository, revision}) do
        [{_, made}] -> made
        [] -> nil
      end
    end

    fn -> resolution(client, repository, reference, known) end
  end
end
