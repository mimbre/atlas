defmodule AtlasRuntime.Sources.Upload do
  @moduledoc """
  Result upload to a work source (decision §5.2 "Result upload", §3 protection 6; M2 plan
  W6).

  For one leased work whose attempt has ended and is quiescent:

  1. It reads the work as the **source's client** through `AtlasRuntime.Boundary.Work`
     (`get_work`, `get_frozen`, `get_frozen_blob`), with the right `:read` only. Whatever
     rights the caller's client holds, `choose_path` is never used here, so the facade's
     projection cuts every path on the Runtime's machine (D44) before anything is sent.
     The agent's `answer`, which the projection passes as stored, is redacted here by the
     core's rule for a check's output tail (protection 6, H2): the work folder becomes `.`
     and any other path under the Runtime home `<runtime-home>`.
  2. It sends `report(ended)` with the result, the provenance and the change-set manifest
     (the frozen result's roots and entries), fenced by the `lease_id`.
  3. On `recorded(missing)` it sends `put_blob` only for the missing blobs that the
     manifest references, each once, streamed from the frozen store.

  Stops:
  - `lease_lost` (from `report` or any `put_blob`): stop at once, nothing more is sent;
  - `too_large` (from `put_blob`), or the missing blobs exceeding `:max_result_bytes`
    before any is sent: stop and log; the source holds the task;
  - `not_referenced` (from `put_blob`): stop and log.

  A source that cannot be reached (`{:error, reason}` from `report` or any `put_blob`) is
  not a stop: `report`'s error is answered as it is, a `put_blob`'s as
  `{:error, :unreachable}`, nothing more is sent, and the puller tries again.

  A repeat (after a restart or an unreachable source) sends the same report again, at the
  same revision, and uploads what the source still names as missing. Both steps are
  idempotent at the source.

  The source is reached through the `{module, ref}` seam below (`report/2`, `put_blob/2`).
  The M1 `work_source` contract's in-BEAM and HTTP client targets are adapted to it by the
  puller (assembly A3).
  """

  require Logger

  alias AtlasRuntime.Boundary.Work, as: F
  alias AtlasRuntime.Work.Folders

  @typedoc "The source as the upload calls it: a module implementing this behaviour and its ref."
  @type source :: {module(), term()}

  @typedoc "The report this upload sends: `state` is always `:ended`."
  @type report :: %{
          lease_id: String.t(),
          revision: non_neg_integer(),
          state: :ended,
          result: %{result: map() | nil, provenance: map() | nil, manifest: map() | nil}
        }

  @type put_blob :: %{
          lease_id: String.t(),
          sha256: String.t(),
          size: non_neg_integer(),
          content: Enumerable.t()
        }

  @callback report(ref :: term(), report()) ::
              {:recorded, [String.t()]} | :lease_lost | {:error, term()}
  @callback put_blob(ref :: term(), put_blob()) ::
              :stored | :lease_lost | :too_large | :not_referenced | {:error, term()}

  # The contract's per-result cap (decision §6.2; `work_source` `blob_max_bytes/0`).
  @default_max_result_bytes 20_000_000
  @terminal [:completed, :failed, :crashed, :interrupted, :cancelled, :returned]

  @type outcome ::
          {:ok, %{uploaded: [String.t()], skipped: [String.t()]}}
          | {:stopped, :lease_lost | :too_large | {:not_referenced, String.t()}}
          | {:error, :not_found | :not_ended | :unreachable | {:blob_unavailable, String.t()}}

  @doc """
  Uploads the ended attempt of `work_id` under `lease_id` to `source`, reading as `client`.

  Options:
  - `:attempt`: the attempt to upload (default: the work's current one);
  - `:home`: the Runtime home whose paths the answer must not name (default: the running
    core's, `AtlasRuntime.Work.runtime/0`);
  - `:max_result_bytes`: the most bytes of missing blobs one upload sends (default
    20 000 000, the contract's per-result cap, §6.2).
  """
  @spec run({String.t(), [atom()]}, source(), String.t(), String.t(), keyword()) :: outcome()
  def run(client, source, lease_id, work_id, options \\ []) do
    reader = reader(client)

    with {:ok, work} <- read_work(reader, work_id),
         {:ok, attempt} <- ended_attempt(work, Keyword.get(options, :attempt)),
         {:ok, redact} <- redaction(client, work_id, options),
         manifest = manifest(reader, work_id, attempt.attempt),
         report = report(lease_id, work, attempt, manifest, redact),
         {:recorded, missing} <- call(source, :report, report) do
      upload(reader, source, lease_id, work_id, attempt.attempt, manifest, missing, options)
    else
      :lease_lost -> stop(:lease_lost, lease_id)
      {:error, _} = error -> error
    end
  end

  # Only :read: the projection then redacts paths whatever the caller's rights (D44).
  defp reader({id, _rights}), do: {id, [:read]}

  defp read_work(reader, work_id) do
    case F.get_work(reader, %{work_id: work_id}) do
      %F.Outcome.Found{work: work} -> {:ok, work}
      _ -> {:error, :not_found}
    end
  end

  defp ended_attempt(work, number) do
    attempt =
      if number,
        do: Enum.find(work.attempts, &(&1.attempt == number)),
        else: List.last(work.attempts)

    case attempt do
      %{state: state, quiescent: true} = attempt when state in @terminal -> {:ok, attempt}
      nil -> {:error, :not_found}
      _ -> {:error, :not_ended}
    end
  end

  defp manifest(reader, work_id, attempt) do
    case F.get_frozen(reader, %{work_id: work_id, attempt: attempt}) do
      %F.Outcome.Frozen{} = frozen -> plain(%{base: frozen.base, roots: frozen.roots})
      _ -> nil
    end
  end

  defp report(lease_id, work, attempt, manifest, redact) do
    %{
      lease_id: lease_id,
      revision: work.revision,
      state: :ended,
      result: %{
        result: attempt.result |> plain() |> redact_answer(redact),
        provenance: plain(attempt.provenance),
        manifest: manifest
      }
    }
  end

  defp upload(reader, source, lease_id, work_id, attempt, manifest, missing, options) do
    sizes = referenced(manifest)
    {wanted, skipped} = missing |> Enum.uniq() |> Enum.split_with(&Map.has_key?(sizes, &1))

    if skipped != [],
      do:
        Logger.warning("upload #{lease_id}: source named unreferenced blobs #{inspect(skipped)}")

    cap = Keyword.get(options, :max_result_bytes, @default_max_result_bytes)

    if wanted |> Enum.map(&sizes[&1]) |> Enum.sum() > cap do
      stop(:too_large, lease_id)
    else
      put_all(reader, source, lease_id, work_id, attempt, wanted, skipped)
    end
  end

  defp put_all(reader, source, lease_id, work_id, attempt, wanted, skipped) do
    Enum.reduce_while(wanted, {:ok, %{uploaded: [], skipped: skipped}}, fn sha256, {:ok, done} ->
      input = %{work_id: work_id, attempt: attempt, sha256: sha256}

      case F.get_frozen_blob(reader, input) do
        %F.Outcome.Blob{sha256: ^sha256, size: size, content: content} ->
          blob = %{lease_id: lease_id, sha256: sha256, size: size, content: content}

          case call(source, :put_blob, blob) do
            :stored -> {:cont, {:ok, %{done | uploaded: done.uploaded ++ [sha256]}}}
            :lease_lost -> {:halt, stop(:lease_lost, lease_id)}
            :too_large -> {:halt, stop(:too_large, lease_id)}
            :not_referenced -> {:halt, stop({:not_referenced, sha256}, lease_id)}
            {:error, reason} -> {:halt, unreachable(lease_id, sha256, reason)}
          end

        _ ->
          Logger.warning("upload #{lease_id}: frozen blob #{sha256} is unavailable")
          {:halt, {:error, {:blob_unavailable, sha256}}}
      end
    end)
  end

  defp redact_answer(%{answer: answer} = result, redact) when is_binary(answer),
    do: %{result | answer: redact.(answer)}

  defp redact_answer(result, _redact), do: result

  # The core's rule (work/server.ex `redaction/4`, private there): the work's folder, and a
  # client-named folder it ran in, become `.`; any other path under the Runtime home, as given
  # or resolved, `<runtime-home>`; by plain prefix replacement. Applied whatever the caller's
  # rights, as the source never holds choose_path.
  defp redaction(client, work_id, options) do
    case Keyword.get_lazy(options, :home, fn -> (AtlasRuntime.Work.runtime() || %{})[:home] end) do
      home when is_binary(home) ->
        expanded = Path.expand(home)

        prefixes =
          Enum.uniq(
            for(path <- [folder(client, work_id)], is_binary(path), do: {path, "."}) ++
              [
                {Folders.path(home, work_id), "."},
                {Path.join([expanded, "workers", "work-" <> work_id]), "."},
                {Folders.real(expanded), "<runtime-home>"},
                {expanded, "<runtime-home>"}
              ]
          )

        {:ok,
         fn text ->
           Enum.reduce(prefixes, text, fn {from, to}, text -> String.replace(text, from, to) end)
         end}

      _ ->
        {:error, :not_found}
    end
  end

  # A folder work's folder, which only a client with choose_path can name; read, never sent.
  defp folder({_id, rights} = client, work_id) do
    with true <- :choose_path in rights,
         %F.Outcome.Found{work: %{request: %{workspace: %{path: path}}}} <-
           F.get_work(client, %{work_id: work_id}) do
      path
    else
      _ -> nil
    end
  end

  defp call({module, ref}, :report, input), do: module.report(ref, input)
  defp call({module, ref}, :put_blob, input), do: module.put_blob(ref, input)

  # The source was not reached for one blob: as a failed report, the puller tries again,
  # and the repeat uploads what the source still names as missing.
  defp unreachable(lease_id, sha256, reason) do
    Logger.warning("upload #{lease_id}: put_blob #{sha256} not done (#{inspect(reason)})")
    {:error, :unreachable}
  end

  defp stop(reason, lease_id) do
    Logger.warning("upload #{lease_id}: stopped (#{inspect(reason)})")
    {:stopped, reason}
  end

  # sha256 => size for every written entry of the manifest (deletes carry no blob).
  defp referenced(nil), do: %{}

  defp referenced(%{roots: roots}) do
    for %{entries: entries} <- roots,
        %{sha256: sha} = e when is_binary(sha) <- entries,
        into: %{},
        do: {sha, e.size || 0}
  end

  # The contract's structs as plain maps, nil fields dropped.
  defp plain(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp plain(%_{} = struct), do: struct |> Map.from_struct() |> plain()

  defp plain(%{} = map),
    do: for({k, v} <- map, v != nil, into: %{}, do: {k, plain(v)})

  defp plain(list) when is_list(list), do: Enum.map(list, &plain/1)
  defp plain(value), do: value
end
