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
