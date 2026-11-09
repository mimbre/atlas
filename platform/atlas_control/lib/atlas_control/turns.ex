defmodule AtlasControl.Turns do
  @moduledoc """
  The current owner's turn and outcome, named entirely by the model's turn (`turn/0`),
  with what the worker reads first (the model's compiled `read_first/2`). `m` is the
  model as Control serves it (`AtlasControl.Model.catalog/2`).
  """

  def current(m, by, read) do
    with %{"kind" => kind} = n <- m.turn,
         %{"facts" => turns} <- read.(kind, %{"linked" => %{n["by"] => by}, "plain" => true}),
         [turn] <- Enum.filter(turns, &(&1["values"][n["state"]] == n["running"])),
         [key] <- get_in(turn, ["links", n["on"]]) || [],
         [on_kind] <- n["on_kinds"] || [],
         %{"fact" => %{} = item} <-
           read.(on_kind, %{"key" => key, "plain" => true, "presentation" => true}),
         true <- owner?(n, on_kind, item, by),
         {:ok, {kind_of_on, on}} <- original(m, on_kind, key, read) do
      context = %{"key" => turn["key"], "on" => on, "turn" => turn, "names" => n}

      # What the worker reads before it acts (the item's anchors and the standing rules);
      # an item that cannot be read leaves its anchors out.
      fact =
        case read.(kind_of_on, %{"key" => on, "plain" => true}) do
          %{"fact" => %{} = fact} -> fact
          _ -> %{}
        end

      case m.module.read_first(fact, read) do
        nil -> {:ok, context}
        text -> {:ok, Map.put(context, "read_first", text)}
      end
    else
      _ -> {:error, "No single running turn is owned by this agent. Set ATLAS_AS to its key."}
    end
  end

  def outcome(m, by, message, read) do
    with value when is_binary(value) <- message["outcome"],
         true <- String.trim(value) != "",
         {:ok, context} <- current(m, by, read),
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

  # The facts a turn works on are the model's (`items`); who owns the work on one, Facts'
  # presentation of it says.
  defp owner?(n, kind, fact, by) do
    Enum.any?(n["items"] || [], &(&1["kind"] == kind)) and
      by in (get_in(fact, ["presentation", "owner"]) || [])
  end

  # The fact the item is the component of, when it is one; else the item itself.
  defp original(m, kind, key, read) do
    components =
      for {_name, r} <- Enum.sort(m.relations),
          is_map(r.component),
          r.to == [kind],
          from_kind <- r.from,
          do: {r.name, from_kind}

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
