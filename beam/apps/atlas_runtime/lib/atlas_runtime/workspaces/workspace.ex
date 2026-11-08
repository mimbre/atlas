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

  def workspace_path(workspace), do: workspace_request(["path", workspace])

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
