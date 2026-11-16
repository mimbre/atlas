defmodule AtlasRuntime.Work.Mode do
  @moduledoc """
  The Runtime's persisted mode (design §3.4, §13.1 Q5, Q6): `open`, `paused` or `draining`,
  kept in `$ATLAS_RUNTIME_HOME/mode.json` through the private model
  (`AtlasRuntime.Model.RuntimeMode`, one `runtime_mode` entry). The work core
  (`AtlasRuntime.Work.Server`) loads it at boot and is its only writer.

  - A missing file, or one without an entry, is `open`. A file that does not decode is a
    refusal, never `open`: an unreadable pause must not silently reopen the Runtime (Q6).
  - The file is written to a temporary file and renamed into place, before anything
    mentions the new mode (I2).
  - `stopping` is never persisted (Q6): it is the core's own state while the Runtime is on
    its way out, and overrides the persisted mode only in memory (`effective/2`).

  | Mode | submit / retry | start of `buffered` | `starting`/`running` | `buffered` on entry |
  |---|---|---|---|---|
  | `open` | taken | starts | run | — |
  | `paused` | `at_capacity: not_accepting` | none | continue | stay |
  | `draining` | `at_capacity: not_accepting` | none | finish | `returned` |

  Every persisted mode may follow every other (Q5); the same mode again changes nothing.
  """

  alias AtlasRuntime.Model.RuntimeMode.RuntimeMode

  @type t :: :open | :paused | :draining
  @modes [:open, :paused, :draining]

  @doc "The modes that can be set and persisted."
  def modes, do: @modes

  @doc "The persisted mode: `{:ok, mode}` (missing = `open`) or `{:error, why}`."
  @spec load(Path.t()) :: {:ok, t()} | {:error, String.t()}
  def load(dir) do
    path = path(dir)

    case File.read(path) do
      {:ok, bytes} ->
        with {:ok, map} <- JSON.decode(bytes),
             {:ok, entries} <- RuntimeMode.decode_file(map) do
          case entries do
            [] -> {:ok, :open}
            [%RuntimeMode{mode: mode}] -> {:ok, mode}
            _ -> {:error, "#{RuntimeMode.path()}: more than one mode"}
          end
        else
          {:error, error} -> {:error, "#{RuntimeMode.path()}: #{inspect(error)}"}
        end

      {:error, :enoent} ->
        {:ok, :open}

      {:error, reason} ->
        {:error, "#{RuntimeMode.path()}: #{:file.format_error(reason)}"}
    end
  end

  @doc "Persists `mode`, set by the client id `by`, atomically."
  @spec put!(Path.t(), t(), String.t()) :: :ok
  def put!(dir, mode, by) when mode in @modes and is_binary(by) do
    entry =
      RuntimeMode.new!(
        mode: mode,
        changed_at: DateTime.utc_now() |> DateTime.truncate(:millisecond),
        changed_by: by
      )

    path = path(dir)
    temporary = path <> ".tmp"
    File.mkdir_p!(Path.dirname(path))
    File.write!(temporary, JSON.encode!(RuntimeMode.encode_file([entry])))
    File.rename!(temporary, path)
    :ok
  end

  @doc "The mode a caller sees: `stopping` while the Runtime stops, else the persisted one."
  @spec effective(t(), boolean()) :: t() | :stopping
  def effective(_mode, true = _stopping), do: :stopping
  def effective(mode, false), do: mode

  defp path(dir), do: Path.join(dir, RuntimeMode.path())
end
