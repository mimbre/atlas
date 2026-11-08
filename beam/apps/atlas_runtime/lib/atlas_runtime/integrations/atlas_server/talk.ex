defmodule AtlasRuntime.Talk do
  @moduledoc """
  Reads and facts over the Bus, from the calling process (which must be attached), and
  the answer to each. A read is asked again a few times; a fact is sent again with the
  same id while State does not answer, so it is stored once.
  """

  alias AtlasBus.Envelope

  @wait 2_000
  @tries 3

  @doc "Read: State's answer, or `%{\"error\" => …}`."
  def read(kind, content, opts \\ []),
    do:
      read_request(
        kind,
        content,
        Keyword.get(opts, :tries, @tries),
        Keyword.get(opts, :wait, @wait)
      )

  defp read_request(_kind, _content, 0, _wait), do: %{"error" => "State did not answer"}

  defp read_request(kind, content, tries, wait) do
    envelope = Envelope.new("read", kind)
    id = envelope.id
    :ok = AtlasBus.send(envelope, content)

    receive do
      {:atlas_bus, %Envelope{id: ^id, class: "answer"}, answer} -> answer
    after
      wait -> read_request(kind, content, tries - 1, wait)
    end
  end

  @doc "Put a fact: `{:stored, position}`, `{:refused, reasons}` or `{:error, :no_answer}`."
  def put(kind, content) do
    case fact(kind, content) do
      {:stored, _answer, position} -> {:stored, position}
      {:refused, refusal} -> {:refused, refusal["reasons"] || List.wrap(refusal["code"])}
      error -> error
    end
  end

  @doc "Full acknowledgement, including immutable fact identity and typed refusal."
  def fact(kind, content, opts \\ []),
    do:
      fact_request(
        Envelope.new("fact", kind),
        content,
        Keyword.get(opts, :tries, @tries),
        Keyword.get(opts, :wait, @wait)
      )

  defp fact_request(_envelope, _content, 0, _wait), do: {:error, :no_answer}

  defp fact_request(envelope, content, tries, wait) do
    id = envelope.id
    :ok = AtlasBus.send(envelope, content)

    receive do
      {:atlas_bus, %Envelope{id: ^id, class: "stored"} = stored, answer} ->
        {:stored, answer, stored.position}

      {:atlas_bus, %Envelope{id: ^id, class: "refused"}, refusal} ->
        {:refused, refusal}
    after
      wait -> fact_request(envelope, content, tries - 1, wait)
    end
  end
end
