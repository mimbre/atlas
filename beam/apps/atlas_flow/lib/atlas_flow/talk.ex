defmodule AtlasFlow.Talk do
  @moduledoc """
  Reads and facts over the Bus, from the calling process (which must be attached), and
  the answer to each. A read is asked again a few times; a fact is sent again with the
  same id while Facts does not answer, so it is stored once.
  """

  alias AtlasBus.Envelope

  @wait 2_000
  @tries 3
  @wrote {__MODULE__, :wrote}

  @doc """
  Run `fun`: `{its result, the positions the facts put while it ran were stored at}`,
  ascending (`[]`: none).
  """
  def writing(fun) do
    Process.put(@wrote, [])

    try do
      result = fun.()
      {result, Enum.sort(Enum.uniq(Process.get(@wrote)))}
    after
      Process.delete(@wrote)
    end
  end

  defp wrote(position) when is_integer(position) do
    case Process.get(@wrote, :none) do
      :none -> :ok
      positions -> Process.put(@wrote, [position | positions])
    end
  end

  defp wrote(_position), do: :ok

  def gate(operation, intent) do
    envelope = %{
      Envelope.new("request", "gate_activity", id: intent["id"] <> "." <> operation)
      | address: "gates"
    }

    with :ok <- AtlasBus.send(envelope, Map.put(intent, "operation", operation)) do
      receive do
        {:atlas_bus, %Envelope{id: id, class: "answer", sender: "gates"}, answer}
        when id == envelope.id ->
          {:ok, answer}
      after
        @wait -> {:error, :gate_unavailable}
      end
    end
  end

  @doc "Read: Facts' answer, or `%{\"error\" => …}`."
  def transition_read(kind, content),
    do: read(kind, Map.put(content, "consistency", "transition"))

  def read(kind, content), do: read(kind, content, @tries)

  defp read(_kind, _content, 0), do: %{"error" => "Facts did not answer"}

  defp read(kind, content, tries) do
    envelope = Envelope.new("read", kind)
    id = envelope.id
    :ok = AtlasBus.send(envelope, content)

    receive do
      {:atlas_bus, %Envelope{id: ^id, class: "answer"}, answer} -> answer
    after
      @wait -> read(kind, content, tries - 1)
    end
  end

  @doc "Put a fact: `{:stored, position}`, `{:refused, reasons}` or `{:error, :no_answer}`."
  def put(kind, content), do: transmit(Envelope.new("fact", kind), content, @tries)

  def put(kind, content, id) when is_binary(kind) and is_binary(id),
    do: transmit(Envelope.new("fact", kind, id: id), content, @tries)

  defp transmit(_envelope, _content, 0), do: {:error, :no_answer}

  defp transmit(envelope, content, tries) do
    id = envelope.id
    :ok = AtlasBus.send(envelope, content)

    receive do
      {:atlas_bus, %Envelope{id: ^id, class: "stored"} = stored, _} ->
        wrote(stored.position)
        {:stored, stored.position}

      {:atlas_bus, %Envelope{id: ^id, class: "refused"}, refusal} ->
        {:refused, refusal["reasons"]}
    after
      @wait -> transmit(envelope, content, tries - 1)
    end
  end
end
