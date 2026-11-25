defmodule AtlasFlow.Code.Client.Boundary do
  @moduledoc """
  `AtlasFlow.Code.Client` on Code's boundary facade, `AtlasCode.Boundary`, in the same BEAM
  (ADR 0006; Flow plan §3.4). This is the only Flow file that names Code, and it names only
  the facade and the outcome structs the facade generates (`atlas_bus` boundary test).

  It carries Flow's one use: Bases' snapshot reads. The context is the facade's caller,
  `{id, rights}` (`AtlasFlow.Code.Client.default/0`). Each answer is translated to Flow's
  terms here: the outcome struct's own name becomes the error tag. When no Code instance
  is registered in this BEAM the facade raises; that is `{:error, :unavailable}`.
  """
  @behaviour AtlasFlow.Code.Client

  alias AtlasCode.Boundary
  alias AtlasCode.Boundary.Outcome

  @impl true
  def resolve_reference(caller, repository, reference) do
    call(fn ->
      Boundary.resolve_reference(caller, %{repository: repository, reference: reference})
    end)
    |> case do
      %Outcome.Resolved{revision: revision} -> {:ok, revision}
      other -> failure(other)
    end
  end

  @impl true
  def create_snapshot(caller, placements) do
    repositories =
      for %{repository: repository, revision: revision, path: path} <- placements,
          do: %{repository: repository, revision: revision, path: path}

    call(fn -> Boundary.create_snapshot(caller, %{repositories: repositories}) end)
    |> case do
      %Outcome.Created{snapshot_id: snapshot_id} -> {:ok, snapshot_id}
      other -> failure(other)
    end
  end

  @impl true
  def get_manifest(caller, snapshot_id) do
    call(fn -> Boundary.get_manifest(caller, %{snapshot_id: snapshot_id}) end)
    |> case do
      %Outcome.Manifest{entries: entries} -> {:ok, Enum.map(entries, &entry/1)}
      other -> failure(other)
    end
  end

  @impl true
  def get_blob(caller, snapshot_id, sha256) do
    call(fn -> Boundary.get_blob(caller, %{snapshot_id: snapshot_id, sha256: sha256}) end)
    |> case do
      %Outcome.Blob{size: size, content: content} -> {:ok, size, content}
      other -> failure(other)
    end
  end

  defp entry(entry) do
    %{
      repository: entry.repository,
      path: entry.path,
      kind: Atom.to_string(entry.kind),
      mode: entry.mode,
      size: entry.size,
      sha256: entry.sha256,
      target: entry.target
    }
  end

  # The facade raises when no Code is registered (or the registered one stopped).
  defp call(fun) do
    fun.()
  rescue
    RuntimeError -> :unavailable
  end

  defp failure(:unavailable), do: {:error, :unavailable}

  # Every refusal is an outcome struct (the contract's, or the generator's own for a
  # missing right or an invalid input): its last name, underscored, is the tag.
  defp failure(%module{}) do
    {:error, module |> Module.split() |> List.last() |> Macro.underscore() |> String.to_atom()}
  end
end
