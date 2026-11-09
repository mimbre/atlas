defmodule AtlasGates.Facts.Bus do
  @moduledoc """
  Records verdicts in Facts over the Bus, from the calling process, which `attach/2` makes
  an endpoint. Reads and facts go to the store as every layer sends them.

  A new verdict's key is the kind's id prefix and the next number (the model's `ids/0`,
  `AtlasGates.Model`; `ids` in the state, else the configured model's). Each try is sent
  with the id `<request id>.<try>`, so Facts stores a resend once and answers it as it did
  the first time; when the key is taken meanwhile (`exists`, `reserved`) the next number is
  tried. Links are set in one change right after it is made, as `atlas put --link` does. No answer within `wait` milliseconds is asked again, a few times, then an error.
  """
  @behaviour AtlasGates.Facts

  alias AtlasBus.Envelope

  @tries 3
  @key_tries 5

  @doc """
  Attach the calling process as `endpoint`: `{:ok, {AtlasGates.Facts.Bus, state}}`.
  `opts`: `wait` (ms, default 2000) and `ids` (the key rules; default the configured
  model's).
  """
  def attach(endpoint, opts \\ []) do
    with :ok <- AtlasBus.attach(endpoint),
         do:
           {:ok,
            {__MODULE__, %{wait: Keyword.get(opts, :wait, 2_000), ids: Keyword.get(opts, :ids)}}}
  end

  @impl true
  def fetch(state, nil, key) when is_binary(key) do
    ids = ids(state)

    candidates =
      for {kind, rule} <- ids,
          prefix <- rule["prefixes"] || [],
          is_binary(prefix) and prefix != "" and String.starts_with?(key, prefix),
          do: {byte_size(prefix), kind}

    case Enum.sort(candidates, :desc) do
      [{_, kind} | _] -> fetch(state, kind, key)
      [] -> fetch_unprefixed(state, ids, key)
    end
  end

  def fetch(state, kind, key) do
    content =
      if key, do: %{"key" => key, "plain" => true}, else: %{"plain" => true, "linked" => %{}}

    case read(state, kind, Map.put(content, "consistency", "transition")) do
      %{"fact" => fact} -> {:ok, fact}
      %{"facts" => facts} -> {:ok, facts}
      other -> {:error, "Facts answered #{inspect(other)}"}
    end
  end

  defp fetch_unprefixed(state, ids, key) do
    Enum.reduce_while(Enum.sort(ids), {:ok, nil}, fn {kind, rule}, acc ->
      if Enum.any?(rule["prefixes"] || [], &(is_binary(&1) and &1 != "")) do
        {:cont, acc}
      else
        case fetch(state, kind, key) do
          {:ok, nil} -> {:cont, acc}
          result -> {:halt, result}
        end
      end
    end)
  end

  @impl true

  def find(state, kind, identity) do
    with {:ok, facts} <- facts(state, kind) do
      found =
        facts
        |> Enum.filter(fn fact ->
          values = fact |> Map.get("values", %{}) |> Map.values() |> Enum.map(&to_string/1)
          Enum.all?(identity, &(&1 in values))
        end)
        |> Enum.map(& &1["key"])
        |> Enum.sort(:desc)
        |> List.first()

      {:ok, found}
    end
  end

  @impl true
  def create(state, kind, request_id, values, links) do
    with {:ok, rule} <- id_rule(state, kind),
         {:ok, facts} <- facts(state, kind) do
      keys = Enum.map(facts, & &1["key"])
      try_create(state, kind, request_id, values, links, rule, next(rule, keys, 0), 1)
    end
  end

  defp try_create(_state, _kind, _id, _values, _links, _rule, _key, attempt)
       when attempt > @key_tries,
       do: {:error, "no free key after #{@key_tries} tries"}

  defp try_create(state, kind, id, values, links, rule, {key, number}, attempt) do
    content = %{"op" => "create", "key" => key, "values" => values}
    envelope = Envelope.new("fact", kind, id: "#{id}.#{attempt}")

    case put(state, envelope, content, @tries) do
      {:stored, %{"key" => stored}} ->
        link(state, kind, id, stored, links)

      {:refused, %{"code" => code}} when code in ["exists", "reserved"] ->
        try_create(state, kind, id, values, links, rule, next(rule, [], number), attempt + 1)

      {:refused, refusal} ->
        {:error,
         "Facts refused it: " <> Enum.join(List.wrap(refusal["reasons"] || refusal), "; ")}

      :no_answer ->
        {:error, "Facts did not answer"}
    end
  end

  # Links are set right after the verdict is made, in one change, as Control does: Facts
  # makes a fact with the links of its parent only.
  def ensure_links(state, kind, id, key, links), do: link(state, kind, id, key, links)

  defp link(_state, _kind, _id, key, links) when links == %{}, do: {:ok, key}

  defp link(state, kind, id, key, links) do
    links = Map.new(links, fn {relation, keys} -> {relation, List.wrap(keys)} end)
    envelope = Envelope.new("fact", kind, id: "#{id}.links")

    case put(state, envelope, %{"op" => "change", "key" => key, "links" => links}, @tries) do
      {:stored, _} ->
        {:ok, key}

      {:refused, refusal} ->
        {:error, "#{key} is made, but not linked: #{inspect(refusal["reasons"])}"}

      :no_answer ->
        {:error, "#{key} is made, but not linked: Facts did not answer"}
    end
  end

  defp put(_state, _envelope, _content, 0), do: :no_answer

  defp put(state, envelope, content, tries) do
    id = envelope.id

    with :ok <- AtlasBus.send(envelope, content) do
      receive do
        {:atlas_bus, %Envelope{id: ^id, class: "stored"}, answer} -> {:stored, answer}
        {:atlas_bus, %Envelope{id: ^id, class: "refused"}, refusal} -> {:refused, refusal}
      after
        state.wait -> put(state, envelope, content, tries - 1)
      end
    else
      {:error, why} -> {:refused, %{"reasons" => ["the Bus did not take it: #{inspect(why)}"]}}
    end
  end

  defp facts(state, kind) do
    case read(state, kind, %{}) do
      %{"facts" => facts} when is_list(facts) -> {:ok, facts}
      %{"error" => why} -> {:error, "Facts could not read #{kind}: #{why}"}
      other -> {:error, "Facts answered #{inspect(other)}"}
    end
  end

  # The id rule of `kind`, the model's: its prefix and digits.
  defp id_rule(state, kind) do
    case ids(state)[kind] do
      %{"prefix" => prefix, "digits" => digits} when is_binary(prefix) and prefix != "" ->
        {:ok, %{prefix: prefix, digits: digits}}

      %{} ->
        {:error, "#{kind} has no id prefix in the model"}

      nil ->
        {:error, "the model has no kind #{kind}"}
    end
  end

  defp ids(%{ids: ids}) when is_map(ids), do: ids
  defp ids(_state), do: AtlasGates.Model.configured!().ids()

  defp next(%{prefix: prefix, digits: digits}, keys, after_number) do
    {:ok, pattern} = Regex.compile("^" <> Regex.escape(prefix) <> "(\\d+)$")

    highest =
      keys
      |> Enum.flat_map(fn key ->
        case Regex.run(pattern, key || "") do
          [_, n] -> [String.to_integer(n)]
          nil -> []
        end
      end)
      |> Enum.max(fn -> 0 end)

    number = max(highest, after_number) + 1
    {prefix <> String.pad_leading(Integer.to_string(number), digits, "0"), number}
  end

  defp read(state, kind, content), do: read(state, kind, content, @tries)
  defp read(_state, _kind, _content, 0), do: %{"error" => "Facts did not answer"}

  defp read(state, kind, content, tries) do
    envelope = Envelope.new("read", kind)
    id = envelope.id

    case AtlasBus.send(envelope, content) do
      :ok ->
        receive do
          {:atlas_bus, %Envelope{id: ^id, class: "answer"}, answer} -> answer
        after
          state.wait -> read(state, kind, content, tries - 1)
        end

      {:error, why} ->
        %{"error" => "the Bus did not take it: #{inspect(why)}"}
    end
  end
end
