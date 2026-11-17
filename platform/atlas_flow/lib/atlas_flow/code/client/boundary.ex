defmodule AtlasFlow.Code.Client.Boundary do
  @moduledoc """
  `AtlasFlow.Code.Client` on Code's boundary facade, `AtlasCode.Boundary`, in the same BEAM
  (ADR 0006; Flow plan §3.4). This is the only Flow file that names Code, and it names only
  the facade and the outcome structs the facade generates (`atlas_bus` boundary test).

  It carries both of Flow's uses: Bases' snapshot reads, and Publish's changes and reviews
  (F3). The context is the facade's caller, `{id, rights}` (`AtlasFlow.Code.Client.default/0`
  or `publishing/0`). Each answer is translated to Flow's
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

  @impl true
  def snapshot_revision(caller, snapshot_id, repository) do
    call(fn -> Boundary.get_manifest(caller, %{snapshot_id: snapshot_id}) end)
    |> case do
      %Outcome.Manifest{repositories: repositories} ->
        case Enum.find(repositories, &(&1.repository == repository)) do
          %{revision: revision} -> {:ok, revision}
          nil -> {:error, :repository_mismatch}
        end

      other ->
        failure(other)
    end
  end

  @impl true
  def create_change(caller, request) do
    input = Map.take(request, [:change_id, :snapshot_id, :repository, :base_revision, :entries])

    call(fn -> Boundary.create_change(caller, input) end)
    |> change()
  end

  @impl true
  def put_change_blob(caller, change_id, sha256, content) do
    input = %{change_id: change_id, sha256: sha256, content: content}

    call(fn -> Boundary.put_change_blob(caller, input) end)
    |> change()
  end

  @impl true
  def seal_change(caller, change_id) do
    call(fn -> Boundary.seal_change(caller, %{change_id: change_id}) end)
    |> change()
  end

  @impl true
  def create_review(caller, request) do
    input =
      request
      |> Map.take([:review_id, :change_id, :target, :title, :body, :fingerprint, :draft])
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    call(fn -> Boundary.create_review(caller, input) end)
    |> case do
      %Outcome.Review{} = review -> {:ok, plain(review)}
      other -> failure(other)
    end
  end

  @impl true
  def update_review(caller, request) do
    input = Map.take(request, [:update_id, :review_id, :change_id, :revision, :fingerprint])

    call(fn -> Boundary.update_review(caller, input) end)
    |> case do
      %Outcome.Updated{} = update -> {:ok, plain(update)}
      other -> failure(other)
    end
  end

  @impl true
  def mark_ready(caller, review_id) do
    call(fn -> Boundary.mark_ready(caller, %{review_id: review_id}) end)
    |> case do
      %Outcome.Ready{} = ready -> {:ok, plain(ready)}
      other -> failure(other)
    end
  end

  @impl true
  def review_status(caller, review_id) do
    call(fn -> Boundary.review_status(caller, %{review_id: review_id}) end)
    |> case do
      %Outcome.Report{} = report -> {:ok, plain(report)}
      other -> failure(other)
    end
  end

  defp change(%Outcome.Change{} = change), do: {:ok, plain(change)}
  defp change(other), do: failure(other)

  # An outcome struct as a plain map of its fields, in Flow's terms.
  defp plain(struct), do: Map.from_struct(struct)

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
