defmodule AtlasFlow.FakeCode do
  @moduledoc """
  An `AtlasFlow.Code.Client` in memory, for Bases' tests. The client is `{FakeCode, pid}`.

  It holds repositories (`reference => revision`) and revisions (`path => bytes`, under
  `bin/` executable; or `path => {:symlink, target}`). Its manifest lists the entries in
  descending path order, so Bases' own sort is what the tests see. It records every call with the calling process, and it
  can be set to answer (`:ok`), to fail (`:failing`: Code answers `provider_unavailable`)
  or to block (`:blocked`: a call waits until `release/1`, then answers as `:ok`, or fails
  when the mode is `:failing` by then).
  """
  @behaviour AtlasFlow.Code.Client
  use Agent

  @chunk 64 * 1024

  def start_link(repositories \\ %{}) do
    Agent.start_link(fn ->
      %{repositories: repositories, mode: :ok, calls: [], snapshots: %{}, waiting: []}
    end)
  end

  def client(fake), do: {__MODULE__, fake}

  @doc "Sets `reference` of `repository` to `revision`, holding `files` (`path => bytes`)."
  def put(fake, repository, reference, revision, files) do
    Agent.update(fake, fn s ->
      update_in(s.repositories, fn repositories ->
        Map.update(
          repositories,
          repository,
          %{refs: %{reference => revision}, revisions: %{revision => files}},
          fn r ->
            %{
              refs: Map.put(r.refs, reference, revision),
              revisions: Map.put(r.revisions, revision, files)
            }
          end
        )
      end)
    end)
  end

  def mode(fake, mode) when mode in [:ok, :failing, :blocked],
    do: Agent.update(fake, &%{&1 | mode: mode})

  @doc "Lets every blocked call go on, answering as the mode now says."
  def release(fake) do
    waiting = Agent.get_and_update(fake, &{&1.waiting, %{&1 | waiting: []}})
    for {pid, ref} <- waiting, do: send(pid, {:release, ref})
    :ok
  end

  @doc "The calls so far, oldest first: `{capability, caller pid}`."
  def calls(fake), do: fake |> Agent.get(& &1.calls) |> Enum.reverse()

  @doc "How many calls are blocked right now."
  def blocked(fake), do: Agent.get(fake, &length(&1.waiting))

  @impl true
  def resolve_reference(fake, repository, reference) do
    answer(fake, :resolve_reference, fn s ->
      case s.repositories[repository] do
        %{refs: %{^reference => revision}} -> {:ok, revision}
        _ -> {:error, :unknown_reference}
      end
    end)
  end

  @impl true
  def create_snapshot(fake, [%{repository: repository, revision: revision, path: path}]) do
    answer(fake, :create_snapshot, fn s ->
      case s.repositories[repository] do
        %{revisions: %{^revision => _}} ->
          id = "sha256:" <> sha256(:erlang.term_to_binary({repository, revision, path}))
          {:update, {:ok, id}, put_in(s.snapshots[id], {repository, revision, path})}

        _ ->
          {:error, :unknown_revision}
      end
    end)
  end

  @impl true
  def get_manifest(fake, snapshot_id) do
    answer(fake, :get_manifest, fn s ->
      case files(s, snapshot_id) do
        nil ->
          {:error, :not_found}

        {repository, path, files} ->
          {:ok,
           for {file, content} <- Enum.sort(files, :desc) do
             {kind, mode, bytes, target} =
               case content do
                 {:symlink, target} -> {"symlink", "120000", target, target}
                 bytes -> {"file", file_mode(file), bytes, nil}
               end

             %{
               repository: repository,
               path: path <> "/" <> file,
               kind: kind,
               mode: mode,
               size: byte_size(bytes),
               sha256: sha256(bytes),
               target: target
             }
           end}
      end
    end)
  end

  defp file_mode(file), do: if(String.starts_with?(file, "bin/"), do: "100755", else: "100644")

  @impl true
  def get_blob(fake, snapshot_id, digest) do
    answer(fake, :get_blob, fn s ->
      with {_repository, _path, files} <- files(s, snapshot_id),
           {_file, content} <-
             Enum.find(files, fn {_, content} -> sha256(bytes(content)) == digest end),
           bytes = bytes(content) do
        {:ok, byte_size(bytes), chunks(bytes)}
      else
        _ -> {:error, :not_found}
      end
    end)
  end

  defp bytes({:symlink, target}), do: target
  defp bytes(bytes), do: bytes

  defp files(s, snapshot_id) do
    with {repository, revision, path} <- s.snapshots[snapshot_id],
         do: {repository, path, s.repositories[repository].revisions[revision]}
  end

  # A lazy stream of chunks of at most 64 KiB.
  defp chunks(bytes) do
    Stream.unfold(bytes, fn
      <<>> -> nil
      <<chunk::binary-size(@chunk), rest::binary>> -> {chunk, rest}
      rest -> {rest, <<>>}
    end)
  end

  defp answer(fake, capability, fun) do
    caller = self()

    mode =
      Agent.get_and_update(fake, fn s ->
        {s.mode, %{s | calls: [{capability, caller} | s.calls]}}
      end)

    mode = if mode == :blocked, do: block(fake), else: mode

    case mode do
      :failing ->
        {:error, :provider_unavailable}

      _ok ->
        Agent.get_and_update(fake, fn s ->
          case fun.(s) do
            {:update, answer, s} -> {answer, s}
            answer -> {answer, s}
          end
        end)
    end
  end

  defp block(fake) do
    ref = make_ref()
    caller = self()
    Agent.update(fake, &%{&1 | waiting: [{caller, ref} | &1.waiting]})

    receive do
      {:release, ^ref} -> Agent.get(fake, & &1.mode)
    end
  end

  defp sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
