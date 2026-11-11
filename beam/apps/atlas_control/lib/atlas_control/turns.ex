defmodule AtlasControl.Turns do
  @moduledoc "The current owner's turn and outcome, named entirely by runtime.turn."

  def current(description, by, read) do
    with %{"kind" => kind} = n <- get_in(description, ["runtime", "turn"]),
         %{"facts" => turns} <- read.(kind, %{"linked" => %{n["by"] => by}, "plain" => true}),
         [turn] <- Enum.filter(turns, &(&1["values"][n["state"]] == n["running"])),
         [key] <- get_in(turn, ["links", n["on"]]) || [],
         [on_kind] <- get_in(description, ["relations", n["on"], "to"]),
         %{"fact" => %{} = item} <- read.(on_kind, %{"key" => key, "plain" => true}),
         true <- owner?(description, on_kind, item, by),
         {:ok, {kind_of_on, on}} <- original(description, on_kind, key, read) do
      context = %{"key" => turn["key"], "on" => on, "turn" => turn, "names" => n}

      # What the worker reads before it acts (the item's anchors and the standing rules).
      case AtlasControl.ReadFirst.text(description, kind_of_on, on, read) do
        nil -> {:ok, context}
        text -> {:ok, Map.put(context, "read_first", text)}
      end
    else
      _ -> {:error, "No single running turn is owned by this agent. Set ATLAS_AS to its key."}
    end
  end

  def outcome(description, by, message, read) do
    with value when is_binary(value) <- message["outcome"],
         true <- String.trim(value) != "",
         {:ok, context} <- current(description, by, read),
         true <- message["key"] == context["key"],
         n = context["names"],
         field when is_binary(field) <- n["outcome"],
         old = context["turn"]["values"][field],
         true <- old in [nil, "", value] do
      {:ok, n["kind"],
       %{
         "op" => "change",
         "key" => context["key"],
         "values" => %{field => value},
         "version" => nil,
         "was" => %{field => old},
         "cause" => "#{by} ended its turn: #{value}"
       }}
    else
      {:error, _} = error ->
        error

      _ ->
        {:error,
         "The outcome needs text and this agent's current running turn; an outcome cannot be replaced."}
    end
  end

  defp owner?(description, kind, fact, by) do
    Enum.any?(description["flows"] || %{}, fn {_name, flow} ->
      kinds =
        case flow["on"] && get_in(description, ["relations", flow["on"], "to"]) do
          [to] -> [to]
          _ -> flow["kinds"] || []
        end

      kind in kinds and by in (get_in(fact, ["links", flow["owner_relation"]]) || [])
    end)
  end

  defp original(description, kind, key, read) do
    components =
      for {relation, %{"component" => %{}, "to" => [^kind], "from" => from}} <-
            description["relations"] || %{},
          from_kind <- from,
          do: {relation, from_kind}

    if components == [] do
      {:ok, {kind, key}}
    else
      found =
        Enum.flat_map(components, fn {relation, from_kind} ->
          case read.(from_kind, %{"linked" => %{relation => key}, "plain" => true}) do
            %{"facts" => facts} -> Enum.map(facts, &{from_kind, &1["key"]})
            _ -> []
          end
        end)
        |> Enum.uniq()

      case found do
        [on] -> {:ok, on}
        _ -> {:error, "The turn's item could not be read."}
      end
    end
  end
end
