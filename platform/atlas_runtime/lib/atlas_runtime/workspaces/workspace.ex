defmodule AtlasRuntime.Workspaces do
  @moduledoc "Workspace paths and repository requests owned by the runtime executable."

  def valid_request?(workspace, sandbox, scope, repository) do
    valid_permissions =
      (is_nil(scope) && sandbox in ["read-only", "workspace-write"]) ||
        (is_map(scope) && is_nil(sandbox))

    is_binary(workspace) &&
      (File.dir?(workspace) || is_map(repository)) &&
      (is_nil(repository) || (is_map(repository) && is_map(scope))) &&
      valid_permissions
  end

  def permission_scope(workspace), do: workspace_request(["scope", workspace])

  # Materialized under the Runtime home; verified without Git, so the scope is the snapshot identity.
  def folder_scope(workspace, home), do: workspace_request(["folder-scope", workspace, home])

  # A frozen packet tree: the folder scope plus the packet, its findings folder and fingerprint;
  # refused once the tree or its packet files changed after the freeze.
  def packet_scope(workspace, home), do: workspace_request(["packet-scope", workspace, home])

  def workspace_path(workspace), do: workspace_request(["path", workspace])

  # What a review pass (turn) wrote to its packet's findings, recorded under the Runtime
  # home by fixed rules (`snapshot findings`): `{:ok, record}`, or `{:refused, code}` for
  # a coded refusal. Runtime never writes a verdict; a refusal is never a pass.
  def findings(packet, turn, home) do
    executable = System.fetch_env!("ATLAS_RUNTIME_EXECUTABLE")
    args = ["snapshot", "findings", "--packet", packet, "--turn", turn]

    case System.cmd(executable, args,
           env: [{"ATLAS_RUNTIME_HOME", home}],
           stderr_to_stdout: true
         ) do
      {record, 0} ->
        {:ok, JSON.decode!(record)}

      {error, _} ->
        case JSON.decode(error) do
          {:ok, %{"code" => code}} when is_binary(code) -> {:refused, code}
          _ -> raise(String.trim(error))
        end
    end
  end

  @doc """
  Materializes Code snapshot `base_id` into the new folder `dest` (`atlas-runtime snapshot
  materialize`, I-H0), as a Port: `{:ok, result}` or `{:error, detail}`. `--read-only` with
  `read_only: true`. `os_pid` is called with the helper's OS pid before the result is awaited;
  after `timeout_ms` the helper is killed (SIGKILL) and the answer is `{:error, "timed out …"}`.
  The detail is the helper's own text, for the log only.
  """
  def materialize(home, base_id, dest, options) do
    executable = System.fetch_env!("ATLAS_RUNTIME_EXECUTABLE")
    read_only = if Keyword.get(options, :read_only, false), do: ["--read-only"], else: []
    timeout = Keyword.fetch!(options, :timeout_ms)

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        args: ["snapshot", "materialize", "--snapshot", base_id, "--dest", dest] ++ read_only,
        env: [{~c"ATLAS_RUNTIME_HOME", String.to_charlist(home)}]
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    Keyword.get(options, :os_pid, fn _ -> :ok end).(os_pid)
    deadline = System.monotonic_time(:millisecond) + timeout
    collect(port, os_pid, {deadline, timeout, "snapshot materialize"}, [])
  end

  @doc """
  Composes the new folder `dest` from the baseline of `base_id` under the Runtime home plus
  exactly the change set in the file `change_set`, every written file's content taken from
  `blobs` (`atlas-runtime snapshot compose`, I-H2), as a Port: `{:ok, result}` or `{:error,
  detail}`. `--read-only` with `read_only: true`. The helper never contacts Code. `os_pid` and
  `timeout_ms` as for `materialize/4`; the detail is the helper's own text, for the log only.
  """
  def compose(home, base_id, change_set, blobs, dest, options) do
    executable = System.fetch_env!("ATLAS_RUNTIME_EXECUTABLE")
    read_only = if Keyword.get(options, :read_only, false), do: ["--read-only"], else: []
    timeout = Keyword.fetch!(options, :timeout_ms)

    args =
      ["snapshot", "compose", "--base-id", base_id, "--change-set", change_set] ++
        ["--blobs", blobs, "--dest", dest] ++ read_only

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        args: args,
        env: [{~c"ATLAS_RUNTIME_HOME", String.to_charlist(home)}]
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    Keyword.get(options, :os_pid, fn _ -> :ok end).(os_pid)
    deadline = System.monotonic_time(:millisecond) + timeout
    collect(port, os_pid, {deadline, timeout, "snapshot compose"}, [])
  end

  defp collect(port, os_pid, {deadline, timeout, name} = limit, output) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        collect(port, os_pid, limit, [output | data])

      {^port, {:exit_status, 0}} ->
        case JSON.decode(IO.iodata_to_binary(output)) do
          {:ok, %{} = result} -> {:ok, result}
          _ -> {:error, "#{name} printed no result"}
        end

      {^port, {:exit_status, status}} ->
        {:error, "#{name} exited #{status}: #{String.trim(IO.iodata_to_binary(output))}"}
    after
      remaining ->
        System.cmd("/bin/kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
        Port.close(port)
        {:error, "#{name} timed out after #{timeout} ms"}
    end
  end

  @doc """
  The folder `dest` as a change set against its recorded baseline (`atlas-runtime snapshot
  changes`, I-H1), with every written file's content kept in `blobs` as `blobs/<sha256>`
  (0444; an existing blob is kept). `{:ok, %{"snapshot_id", "roots", "outside"}}`, or
  `{:error, code, detail}` with the helper's code (`not_materialized`, `busy`,
  `changed_during_scan`, `unsupported_entry`, `io`) or `"helper"` when it reported none. The
  helper writes nothing to `dest` or its baseline and never contacts Code. After `timeout_ms`
  (default 120 s) it is killed (SIGKILL) and the answer is `{:error, "timeout", detail}`.
  """
  def changes(home, dest, blobs, options \\ []) do
    executable = System.fetch_env!("ATLAS_RUNTIME_EXECUTABLE")
    timeout = Keyword.get(options, :timeout_ms, 120_000)

    # stdout carries only the result and stderr only the failure, so one stream holds either.
    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        args: ["snapshot", "changes", "--dest", dest, "--blobs", blobs],
        env: [{~c"ATLAS_RUNTIME_HOME", String.to_charlist(home)}]
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    deadline = System.monotonic_time(:millisecond) + timeout
    collect_changes(port, os_pid, {deadline, timeout}, [])
  end

  defp collect_changes(port, os_pid, {deadline, timeout} = limit, output) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        collect_changes(port, os_pid, limit, [output | data])

      {^port, {:exit_status, status}} ->
        text = IO.iodata_to_binary(output)

        case {status, JSON.decode(text)} do
          {0, {:ok, %{"snapshot_id" => _, "roots" => roots, "outside" => outside} = result}}
          when is_list(roots) and is_list(outside) ->
            {:ok, result}

          {0, _} ->
            {:error, "helper", "snapshot changes printed no result"}

          {_, {:ok, %{"code" => code} = failure}} when is_binary(code) ->
            {:error, code, to_string(failure["error"])}

          {_, _} ->
            {:error, "helper", "snapshot changes exited #{status}: #{String.trim(text)}"}
        end
    after
      remaining ->
        System.cmd("/bin/kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
        Port.close(port)
        {:error, "timeout", "snapshot changes timed out after #{timeout} ms"}
    end
  end

  def repository_request(home, url, branch),
    do: workspace_request(["request", home, url, branch])

  defp workspace_request(args) do
    executable = System.fetch_env!("ATLAS_RUNTIME_EXECUTABLE")

    case System.cmd(executable, ["workspace" | args], stderr_to_stdout: true) do
      {scope, 0} -> JSON.decode!(scope)
      {error, _} -> raise(String.trim(error))
    end
  end
end
