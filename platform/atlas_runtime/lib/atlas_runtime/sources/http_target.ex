defmodule AtlasRuntime.Sources.HttpTarget do
  @moduledoc """
  A remote work source as the puller reaches it (M2 plan A2): the `work_source` contract's
  HTTP client target (`AtlasRuntimeBackend.Generator.Targets.Client` on
  `AtlasRuntimeBackend.WorkSource`, M1) over W3's transport (`AtlasRuntime.Sources.Transport`:
  TLS 1.3 only, the peer verified, no redirect, no proxy) with the source's bearer credential
  (`AtlasRuntime.Sources.Credential`, `<home>/sources/<name>/token`).

  The ref is `%{conn: conn}`, `conn` from `open/3`; the puller closes it with `close/1`.

  It implements the puller's seam (`AtlasRuntime.Sources.Puller.Target`) and `Upload`'s
  (`AtlasRuntime.Sources.Upload`, with the ref and the lease's report revision):
  - `poll` and `report` are carried as the client answers them; a transport failure is
    `{:error, reason}`, and the puller retries;
  - `get_blob` (the import's download, M2 A3) is the client's streamed answer.

  There is no `put_blob` (`work_source` 0.4.0, IS-Atlas-100): a result travels over Git.
  """
  @behaviour AtlasRuntime.Sources.Puller.Target
  @behaviour AtlasRuntime.Sources.Upload

  require Logger

  alias AtlasRuntime.Sources.{InBeamTarget, Transport}

  defmodule Client do
    @moduledoc "The `work_source` HTTP client target on W3's transport."
    use AtlasRuntimeBackend.Generator.Targets.Client,
      contract: AtlasRuntimeBackend.WorkSource,
      transport: AtlasRuntime.Sources.Transport
  end

  @doc """
  Opens source `name` at `url` with its credential from `home` (`Transport.open/3`; `opts`
  as there, `home:` set here). Answers `{:ok, ref}` or `{:error, reason}`.
  """
  def open(name, url, home, opts \\ []) do
    case Transport.open(name, url, Keyword.put(opts, :home, home)) do
      {:ok, conn} -> {:ok, %{conn: conn}}
      {:error, _} = error -> error
    end
  end

  @doc """
  `open/4` trusting only the CAs of the source's own `ca_file` (pull-e2e D5): the checked
  open of `AtlasRuntime.Sources.Supervisor.open/5`, with the same answers. It is reached
  through this module because the puller takes the module of its `open:` `{module, fun,
  args}` as the target's (`{module, ref}`): an open given as any other module's would make
  every poll call that module.
  """
  def open_with_ca_file(name, url, home, ca_file, opts),
    do: AtlasRuntime.Sources.Supervisor.open(name, url, home, ca_file, opts)

  @doc "Closes the ref's connection."
  def close(%{conn: conn}), do: Transport.close(conn)

  ## The puller's seam

  @impl AtlasRuntime.Sources.Puller.Target
  def poll(%{conn: conn}, input) do
    case Client.poll(input, transport: [conn: conn]) do
      {:polled, polled} -> {:polled, polled}
      {:rejected, %{reason: reason}} -> {:rejected, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl AtlasRuntime.Sources.Puller.Target
  def send_report(%{conn: conn}, input) do
    case Client.report(input, transport: [conn: conn]) do
      {:recorded, %{missing: missing}} -> {:recorded, missing}
      :lease_lost -> :lease_lost
      {:rejected, %{reason: reason}} -> {:rejected, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl AtlasRuntime.Sources.Puller.Target
  def uploader(ref, revision), do: {__MODULE__, Map.put(ref, :revision, revision)}

  # M2 A3: one blob of the lease's input, as the client streams it (the import counts and
  # checks it as it reads).
  @impl AtlasRuntime.Sources.Puller.Target
  def get_blob(%{conn: conn}, lease_id, sha256) do
    case Client.get_blob(%{lease_id: lease_id, sha256: sha256}, transport: [conn: conn]) do
      {:blob, %{sha256: _, size: _, content: _} = blob} -> {:ok, blob}
      other -> {:not_served, name(other)}
    end
  end

  ## Upload's seam

  @impl AtlasRuntime.Sources.Upload
  def report(%{revision: revision} = ref, %{state: :ended} = report) do
    input = %{
      lease_id: report.lease_id,
      revision: revision,
      report: InBeamTarget.ended_report(report.result)
    }

    case send_report(ref, input) do
      {:recorded, missing} ->
        {:recorded, missing}

      # Unreachable: `Upload.run/5` answers it as it is, and the puller tries again.
      {:error, _} = error ->
        error

      other ->
        Logger.warning("upload #{report.lease_id}: the source answered report #{name(other)}")
        :lease_lost
    end
  end

  # Only an answer's name: a rejection's details are the source's.
  defp name({name, _}) when is_atom(name), do: name
  defp name(name) when is_atom(name), do: name
  defp name(_other), do: :failed
end
