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

  def workspace_path(workspace), do: workspace_request(["path", workspace])

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
    collect(port, os_pid, {deadline, timeout}, [])
  end

  defp collect(port, os_pid, {deadline, timeout} = limit, output) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        collect(port, os_pid, limit, [output | data])

      {^port, {:exit_status, 0}} ->
        case JSON.decode(IO.iodata_to_binary(output)) do
          {:ok, %{} = result} -> {:ok, result}
          _ -> {:error, "snapshot materialize printed no result"}
        end

      {^port, {:exit_status, status}} ->
        {:error,
         "snapshot materialize exited #{status}: #{String.trim(IO.iodata_to_binary(output))}"}
    after
      remaining ->
        System.cmd("/bin/kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
        Port.close(port)
        {:error, "snapshot materialize timed out after #{timeout} ms"}
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
