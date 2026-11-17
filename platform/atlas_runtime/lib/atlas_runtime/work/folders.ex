defmodule AtlasRuntime.Work.Folders do
  @moduledoc """
  The folders the Runtime chooses for a work (design §3.3, §3.9 RQ7; s5a-plan B6, B25, B30).

  **Where.** One folder per work, `<home>/workers/work-<work_id>` (`path/2`), the home taken
  through its symlinks: the helper records a materialization under its canonical path, and the
  host gives a folder scope below the Runtime home to exactly that path (the work-folder
  exemption, `workspace.RuntimeWorkFolder`). `work_id` already starts with `work-`, so the
  name reads `work-work-<hex>` (DQ11). No slot id starts with `work-`
  (`AtlasRuntime.Execution.Identity.valid_worker_id?/1`).

  **Preparing** (`prepare/3`) runs in a process of its own, never in the Work server (F17).
  It is monitored by the server and not linked to it: a server that dies leaves it to finish
  its helper and its clean-up. In order:

  1. `<home>/workers` and `<home>/scratch` exist (0700);
  2. an existing folder (a fresh retry, B30) is renamed to `<home>/scratch/rebuild-<work_id>.<n>`:
     the same filesystem, inside the home, denied to every agent (I8);
  3. the helper prepares the folder: `:materialize` fetches the base
     (`AtlasRuntime.Workspaces.materialize/4`, `base`); `:compose` builds it from the pinned
     source's frozen result, its `base` baseline plus exactly its change set, without Code
     (`AtlasRuntime.Workspaces.compose/6`, `from_work`, P9). The change set goes to
     `<home>/scratch/compose-<work_id>.<n>.json` (0600) for the helper and is removed after
     it. Its OS pid goes to the owner as `{:prepare_pid, ref, os_pid, pid}`, and the preparer
     waits for `{:prepare_pid_recorded, ref}` (or the owner's end) before it waits on the
     helper;
  4. the renamed tree is removed (write bits restored first: a read-only folder is sealed), after
     step 3 succeeded or failed;
  5. the owner gets `{:folder_ready, ref, :ok | {:error, detail}}`.

  A crash between steps 2 and 4 leaves a `rebuild-*` tree (and, for `:compose`, a `compose-*`
  file); `sweep/1` removes every one at boot, before any attempt starts. `ref` is the owner's monitor of the preparer, so a preparer that
  dies without a result arrives as that monitor's `:DOWN`.
  """

  alias AtlasRuntime.Work.{Frozen, FrozenStore}
  alias AtlasRuntime.Workspaces

  @doc "The work folder of `work_id`: `<home>/workers/work-<work_id>`, the home resolved."
  def path(home, work_id) when is_binary(work_id),
    do: Path.join([real(home), "workers", "work-" <> work_id])

  @doc """
  Removes every `<home>/scratch/rebuild-*` tree (B30) and `<home>/scratch/compose-*` change
  set file a crash left.
  """
  def sweep(home) do
    scratch = Path.join(home, "scratch")

    case File.ls(scratch) do
      {:ok, names} ->
        for name <- names,
            String.starts_with?(name, ["rebuild-", "compose-"]),
            do: remove(Path.join(scratch, name))

        :ok

      {:error, _} ->
        :ok
    end
  end

  @doc """
  Starts preparing a work's folder: `{pid, ref}`, with `ref` the owner's monitor of `pid`.
  `spec` for `:materialize`: `home`, `work_id`, `attempt`, `base_id`, `read_only`,
  `timeout_ms` and an optional `hook` (`fn stage -> any end`, tests: `:moved_aside`). For
  `:compose` (P9), `source` (`{work_id, attempt}`, the pinned frozen result, B4) instead of
  `base_id`; the hook also sees `:composing`, just before the helper starts.
  """
  def prepare(kind, spec, owner) when kind in [:materialize, :compose] do
    pid = spawn(fn -> run(kind, spec, owner) end)
    ref = Process.monitor(pid)
    send(pid, {:ref, ref})
    {pid, ref}
  end

  defp run(kind, spec, owner) do
    ref =
      receive do
        {:ref, ref} -> ref
      end

    result =
      try do
        build(kind, spec, owner, ref)
      rescue
        error -> {:error, Exception.message(error)}
      end

    send(owner, {:folder_ready, ref, result})
  end

  defp build(kind, spec, owner, ref) do
    home = real(spec.home)
    folder = path(home, spec.work_id)
    for dir <- ["workers", "scratch"], do: mkdir(Path.join(home, dir))
    aside = Path.join([home, "scratch", "rebuild-#{spec.work_id}.#{spec.attempt}"])

    moved =
      case File.lstat(folder) do
        {:ok, info} ->
          remove(aside)
          # Moving a directory to another parent rewrites its `..`: a sealed (0555) folder
          # needs its owner write bit back first.
          if info.type == :directory, do: File.chmod!(folder, 0o700)
          :ok = File.rename(folder, aside)
          true

        {:error, :enoent} ->
          false
      end

    hook = Map.get(spec, :hook) || fn _ -> :ok end
    if moved, do: hook.(:moved_aside)

    options = [
      read_only: spec.read_only,
      timeout_ms: spec.timeout_ms,
      os_pid: fn os_pid -> recorded(owner, ref, os_pid) end
    ]

    try do
      helper(kind, spec, home, folder, options, hook)
    after
      if moved, do: remove(aside)
    end
    |> case do
      {:ok, _result} -> :ok
      {:error, detail} -> {:error, detail}
    end
  end

  defp helper(:materialize, spec, home, folder, options, _hook),
    do: Workspaces.materialize(home, spec.base_id, folder, options)

  # from_work (§3.9): the base the source was frozen against (the original base_id, so a
  # chain stays cumulative) plus exactly its change set. The source is retained while this
  # work exists (B12); a tombstone or a missing record is a preparation failure.
  defp helper(:compose, spec, home, folder, options, hook) do
    {source_id, source_n} = spec.source

    case FrozenStore.read(home, source_id, source_n) do
      {:ok, %{pruned: false} = frozen} ->
        file = Path.join([home, "scratch", "compose-#{spec.work_id}.#{spec.attempt}.json"])
        remove(file)
        File.write!(file, JSON.encode!(Frozen.change_set(frozen)))
        File.chmod!(file, 0o600)
        hook.(:composing)

        try do
          Workspaces.compose(home, frozen.base, file, FrozenStore.blobs(home), folder, options)
        after
          remove(file)
        end

      _ ->
        {:error, "the frozen result #{source_id}.#{source_n} to compose from is gone"}
    end
  end

  # The owner commits the pid (B25) before the preparer waits on the helper. An owner gone before the
  # commit leaves a pid no restart probe knows, so the helper is killed (review S3).
  defp recorded(owner, ref, os_pid) do
    monitor = Process.monitor(owner)
    send(owner, {:prepare_pid, ref, os_pid, self()})

    receive do
      {:prepare_pid_recorded, ^ref} ->
        :ok

      {:DOWN, ^monitor, :process, _, _} ->
        System.cmd("/bin/kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
    end

    Process.demonitor(monitor, [:flush])
  end

  defp mkdir(dir) do
    case File.mkdir(dir) do
      :ok -> File.chmod!(dir, 0o700)
      {:error, :eexist} -> :ok
      {:error, why} -> raise "cannot create #{dir}: #{:file.format_error(why)}"
    end
  end

  # A sealed tree has no write bits: restore them on directories (symlinks are never
  # followed) so that it can be removed.
  defp remove(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        File.chmod(path, 0o700)

        case File.ls(path) do
          {:ok, names} -> for name <- names, do: remove(Path.join(path, name))
          _ -> :ok
        end

        File.rmdir(path)

      {:ok, _} ->
        File.rm(path)

      {:error, _} ->
        :ok
    end

    :ok
  end

  @doc false
  # The path through its symlinks, component by component (as the helper's EvalSymlinks).
  def real(path) do
    ["/" | parts] = Path.split(Path.expand(path))
    resolve([], parts, 0)
  end

  defp resolve(done, [], _hops), do: Path.join(["/" | done])

  defp resolve(done, [part | rest], hops) do
    current = Path.join(["/" | done ++ [part]])

    case :file.read_link_all(current) do
      {:ok, _target} when hops >= 40 ->
        raise "too many symlinks in #{current}"

      {:ok, target} ->
        expanded = Path.expand(IO.chardata_to_string(target), Path.join(["/" | done]))
        ["/" | parts] = Path.split(expanded)
        resolve([], parts ++ rest, hops + 1)

      {:error, _} ->
        resolve(done ++ [part], rest, hops)
    end
  end
end
