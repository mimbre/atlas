defmodule AtlasRuntime.Work.Frozen do
  @moduledoc """
  Freezing a completed attempt (design §3.9; s5a-plan B8–B11, I-K5): its folder's changes
  against the folder's recorded baseline become a change set (`AtlasChangeset`, D42), kept
  as the private `frozen_result` (`AtlasRuntime.Work.FrozenStore`), before the `completed`
  commit names it (I2).

  **Which works (B8).** `base` and `from_work` works (the Runtime made their folder, so a
  missing baseline is a failure), and a `folder{materialized-folder}` work whose folder has a
  materialization record (without one, the attempt completes without `frozen`). A
  `repository` work and a `folder` with `read-only` or `workspace-write` are never frozen.

  **How (B9–B11).** The helper (`snapshot changes`, I-H1) scans the folder twice under its lock
  and writes every written file's content to `<home>/frozen/blobs/<sha256>`. The core then
  refuses any change outside every root, validates the change set with `AtlasChangeset`,
  checks every write entry against its content (a file's blob in the store, a symlink's
  target), computes each root's `csf_` fingerprint with `AtlasChangeset` only, and writes the
  record. Every baseline root is a root of the change set, with `entries: []` when unchanged.
  Any refusal is `{:error, detail}`: the attempt then ends `failed: workspace` (B10), and the
  detail goes to the log only.

  `AtlasChangeset` takes plain data with string values: the model's enum atoms (`op`,
  `kind`) are never passed to it, and absent fields are left out rather than set to nil.
  """

  alias AtlasRuntime.Model.FrozenResult.FrozenResult
  alias AtlasRuntime.Model.Work, as: M
  alias AtlasRuntime.Work.FrozenStore
  alias AtlasRuntime.Workspaces

  @ops %{"write" => :write, "delete" => :delete}
  @kinds %{"file" => :file, "symlink" => :symlink}
  # The turn's helper holds the folder lock until it has reaped the turn's process group.
  @busy_tries 20
  @busy_wait_ms 100

  @doc """
  Whether a work's attempts are frozen: `:required` (`base`, `from_work`), `:if_recorded`
  (a `folder` with `materialized-folder`) or `:never`; never a job's base whose result goes
  back over Git (`imported.git_base`): its folder is a Git checkout, the result its commit.
  """
  def kind(%M.WorkRecord{imported: %M.Imported{git_base: ref}}) when is_binary(ref), do: :never
  def kind(%M.WorkRecord{request: %M.Request{workspace: workspace}}), do: kind(workspace)
  def kind(%M.Base{}), do: :required
  def kind(%M.FromWork{}), do: :required
  def kind(%M.Folder{permissions: :materialized_folder}), do: :if_recorded
  def kind(_workspace), do: :never

  @doc "The folder an attempt ran in: the Runtime-chosen one, or the client's `folder` path."
  def folder(%M.WorkRecord{request: %M.Request{workspace: %M.Folder{path: path}}}, _attempt),
    do: path

  def folder(_record, attempt), do: attempt.folder

  @doc """
  Freezes attempt `attempt` of `record`, which ran in `folder`: `{:ok, %FrozenResult{}}` once
  the record is written, `:not_frozen` (never frozen, or a socket folder without a
  materialization record), or `{:error, detail}`. `options`: `changes` (the helper call,
  tests), `timeout_ms`.
  """
  def freeze(dir, %M.WorkRecord{} = record, attempt, folder, options \\ []) do
    case kind(record) do
      :never ->
        :not_frozen

      _ when not is_binary(folder) ->
        {:error, "the attempt has no folder"}

      kind ->
        FrozenStore.ensure!(dir)

        case changes(dir, folder, options, @busy_tries) do
          {:ok, output} ->
            with {:ok, frozen} <- build(output, record, attempt.attempt, now()),
                 :ok <- verify_blobs(dir, frozen) do
              FrozenStore.put!(dir, frozen)
              {:ok, frozen}
            end

          {:error, "not_materialized", _detail} when kind == :if_recorded ->
            :not_frozen

          {:error, code, detail} ->
            {:error, "snapshot changes refused (#{code}): #{detail}"}
        end
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp changes(dir, folder, options, tries) do
    call =
      Keyword.get(options, :changes, fn dir, folder ->
        Workspaces.changes(dir, folder, FrozenStore.blobs(dir),
          timeout_ms: Keyword.get(options, :timeout_ms, 120_000)
        )
      end)

    case call.(dir, folder) do
      {:error, "busy", _detail} when tries > 1 ->
        Process.sleep(@busy_wait_ms)
        changes(dir, folder, options, tries - 1)

      answer ->
        answer
    end
  end

  @doc """
  The frozen result of attempt `n` of `record` from the helper's `snapshot changes` output
  (`snapshot_id`, `roots`, `outside`), frozen at `at`: `{:ok, %FrozenResult{}}` or `{:error,
  detail}`. Pure: it reads and writes nothing. The entries may come in any order; each
  root's fingerprint is `AtlasChangeset`'s, over the entries as given.
  """
  def build(%{"snapshot_id" => base, "roots" => roots, "outside" => outside}, record, n, at) do
    change_set = %{"base" => base, "roots" => roots}

    cond do
      outside != [] ->
        {:error,
         "changes outside every root (#{length(outside)}): " <>
           Enum.join(Enum.take(outside, 5), ", ")}

      mismatch?(record, base) ->
        {:error,
         "the folder is recorded as #{base}, not as the work's base #{record.request.workspace.base_id}"}

      true ->
        case AtlasChangeset.validate(change_set) do
          :ok ->
            fingerprints = AtlasChangeset.fingerprints(change_set)

            {:ok,
             FrozenResult.new!(
               frozen_id: FrozenStore.id(record.work_id, n),
               work_id: record.work_id,
               attempt: n,
               base: base,
               frozen_at: at,
               pruned: false,
               roots:
                 for {%{"root" => root, "entries" => entries}, %{fingerprint: fingerprint}} <-
                       Enum.zip(roots, fingerprints) do
                   %{
                     root: root,
                     fingerprint: fingerprint,
                     entries: entries |> Enum.sort_by(& &1["path"]) |> Enum.map(&model_entry/1)
                   }
                 end
             )}

          {:error, errors} ->
            {:error, "invalid change set: " <> Enum.join(errors, "; ")}
        end
    end
  end

  def build(_output, _record, _n, _at), do: {:error, "snapshot changes printed no change set"}

  # A base work's folder is materialized from its base_id; any other record is not its base.
  defp mismatch?(%M.WorkRecord{request: %{workspace: %M.Base{base_id: id}}}, base), do: id != base
  defp mismatch?(_record, _base), do: false

  defp model_entry(%{"op" => "delete", "path" => path}), do: %{path: path, op: :delete}

  defp model_entry(%{"op" => "write"} = entry) do
    %{
      path: entry["path"],
      op: :write,
      kind: Map.fetch!(@kinds, entry["kind"]),
      mode: entry["mode"],
      size: entry["size"],
      sha256: entry["sha256"]
    }
    |> then(fn model ->
      if entry["target"], do: Map.put(model, :target, entry["target"]), else: model
    end)
  end

  @doc """
  The plain change-set entry of a stored one, as `AtlasChangeset` takes it: string values,
  absent fields left out.
  """
  def plain_entry(entry) do
    op = Enum.find_value(@ops, fn {text, atom} -> atom == entry.op && text end)
    kind = Enum.find_value(@kinds, fn {text, atom} -> atom == entry.kind && text end)

    [
      {"path", entry.path},
      {"op", op},
      {"kind", kind},
      {"mode", entry.mode},
      {"size", entry.size},
      {"sha256", entry.sha256},
      {"target", entry.target}
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  @doc "The change set a frozen result holds, as plain data (`base`, `roots`)."
  def change_set(%FrozenResult{} = frozen) do
    %{
      "base" => frozen.base,
      "roots" =>
        for root <- frozen.roots do
          %{"root" => root.root, "entries" => Enum.map(root.entries, &plain_entry/1)}
        end
    }
  end

  # Every write entry against its content: a file's blob in the store (missing, or another
  # size or digest, is a refusal), a symlink's target.
  defp verify_blobs(dir, frozen) do
    frozen
    |> change_set()
    |> Map.fetch!("roots")
    |> Enum.flat_map(& &1["entries"])
    |> Enum.filter(&(&1["op"] == "write"))
    |> Enum.reduce_while(:ok, fn entry, :ok ->
      case verify(dir, entry) do
        :ok -> {:cont, :ok}
        {:error, why} -> {:halt, {:error, "#{entry["path"]}: #{why}"}}
      end
    end)
  end

  defp verify(_dir, %{"kind" => "symlink", "target" => target} = entry),
    do: entry |> AtlasChangeset.verify_blob([target]) |> blob_answer()

  defp verify(dir, entry) do
    path = FrozenStore.blob_path(dir, entry["sha256"])

    if File.regular?(path),
      do: entry |> AtlasChangeset.verify_blob(File.stream!(path, 65_536)) |> blob_answer(),
      else: {:error, "its blob #{entry["sha256"]} is missing"}
  end

  defp blob_answer(:ok), do: :ok
  defp blob_answer({:error, which}), do: {:error, "its blob does not match its #{which}"}

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:millisecond)
end
