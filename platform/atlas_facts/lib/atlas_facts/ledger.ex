defmodule AtlasFacts.Ledger do
  @moduledoc """
  What Facts answered to each fact id, and the environment's last position, on disk.

  A resent fact gets the answer recorded here, unchanged: the same "stored" with the
  same position, or the same "refused". So each id is stored once (rule 6) and
  answered every time (rule 7).
  """

  def open(dir) do
    File.mkdir_p!(dir)
    file = dir |> Path.join("ledger.dets") |> String.to_charlist()
    {:ok, table} = :dets.open_file(make_ref(), file: file, type: :set)
    table
  end

  def close(table), do: :dets.close(table)

  def answer(table, id) do
    case :dets.lookup(table, {:answer, id}) do
      [{_, answer}] -> answer
      [] -> nil
    end
  end

  @doc "A deletion request's complete trusted identity; nil for older/unbound requests."
  def request(table, id) do
    case :dets.lookup(table, {:delete_request, id}) do
      [{_, binding}] -> binding
      [] -> nil
    end
  end

  def request_identity(envelope, content),
    do: %{
      environment: envelope.environment,
      kind: envelope.kind,
      sender: envelope.sender,
      content: content
    }

  def matches_request?(table, id, binding),
    do: request(table, id) in [nil, binding]

  @doc "A delete may use only its bound id or a genuinely unused id, never an unbound answer."
  def delete_request_available?(table, id, binding) do
    case request(table, id) do
      nil -> answer(table, id) == nil
      ^binding -> true
      _ -> false
    end
  end

  @doc "An authorized deletion intent/completion, checked against the entire request."
  def deletion(table, binding) do
    case :dets.lookup(table, deletion_key(binding)) do
      [{_, %{binding: ^binding} = proof}] -> {:ok, proof}
      [] -> :none
      _ -> {:error, :request_conflict}
    end
  end

  @doc "Sync validated authorization before the backend delete can take effect."
  def prepare_delete(table, id, binding, target) do
    if delete_request_available?(table, id, binding) do
      proof =
        case deletion(table, binding) do
          :none -> %{binding: binding, target: target, answer: nil}
          {:ok, %{target: ^target} = proof} -> proof
          _ -> nil
        end

      if proof do
        :ok =
          :dets.insert(table, [{{:delete_request, id}, binding}, {deletion_key(binding), proof}])

        :ok = :dets.sync(table)
        :ok
      else
        {:error, :delete_target_changed}
      end
    else
      {:error, :request_conflict}
    end
  end

  defp deletion_key(binding),
    do: {:delete, :crypto.hash(:sha256, :erlang.term_to_binary(canonical(binding)))}

  # A hash is only an index: deletion/2 compares the full stored identity as well.
  defp canonical(value) when is_map(value),
    do: {:map, value |> Enum.map(fn {k, v} -> {k, canonical(v)} end) |> Enum.sort()}

  defp canonical(value) when is_list(value), do: {:list, Enum.map(value, &canonical/1)}
  defp canonical(value), do: value

  def position(table) do
    case :dets.lookup(table, :position) do
      [{_, position}] -> position
      [] -> 0
    end
  end

  @doc "Reserve durable ordering before an immutable backend create; unused positions are gaps."
  def reserve(table) do
    position = position(table) + 1
    :ok = :dets.insert(table, {:position, position})
    :ok = :dets.sync(table)
    position
  end

  @doc "Record a stored fact under the next position; returns that position."
  def stored(table, id, content) do
    position = position(table) + 1

    answer = {"stored", content, position}

    completion =
      case request(table, id) do
        nil ->
          []

        binding ->
          {:ok, proof} = deletion(table, binding)
          [{deletion_key(binding), %{proof | answer: answer}}]
      end

    :ok = :dets.insert(table, [{:position, position}, {{:answer, id}, answer} | completion])

    :ok = :dets.sync(table)
    position
  end

  def refused(table, id, content) do
    :ok = :dets.insert(table, {{:answer, id}, {"refused", content, nil}})
    :ok = :dets.sync(table)
  end
end
