defmodule AtlasGates.Evidence do
  @moduledoc "Builds named evidence from the sources in a gate's data, never from caller classifications."

  def build(name, gate, subject, {module, state} = facts, opts \\ []) do
    with {:ok, verdicts} <-
           module.fetch(state, Keyword.get_lazy(opts, :kind, &AtlasGates.Record.kind/0), nil) do
      previous =
        verdicts
        |> Enum.filter(
          &(get_in(&1, ["values", "gate"]) == name and
              get_in(&1, ["values", "purpose"]) == "decider")
        )
        |> Enum.sort_by(&{get_in(&1, ["values", "decided_at"]) || "", &1["key"]}, :desc)

      context = %{
        name: name,
        subject: subject,
        facts: facts,
        verdicts: previous,
        fingerprint: gate["fingerprint"],
        flow: Keyword.get(opts, :flow, %{})
      }

      Enum.reduce_while(gate["evidence"], {:ok, %{}, previous}, fn {field, source},
                                                                   {:ok, acc, previous} ->
        case source(source, context) do
          {:ok, value} -> {:cont, {:ok, Map.put(acc, field, value), previous}}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
  end

  defp source(["field", field], c), do: {:ok, get_in(c.subject, ["values", field])}
  defp source(["constant", value], _c), do: {:ok, value}
  defp source(["present", relation], c), do: {:ok, keys(c.subject, relation) != []}
  defp source(["flow", field, options], c), do: {:ok, Map.get(c.flow, field, options["default"])}

  defp source(["linked", relation, field], c) do
    {module, state} = c.facts

    Enum.reduce_while(keys(c.subject, relation), {:ok, []}, fn key, {:ok, acc} ->
      case module.fetch(state, nil, key) do
        {:ok, %{} = fact} -> {:cont, {:ok, acc ++ [get_in(fact, ["values", field])]}}
        {:ok, nil} -> {:cont, {:ok, acc ++ [nil]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp source(["history", measure, options], c) when measure in ["count", "overruled"] do
    matching =
      c.verdicts
      # Re-asking one unchanged episode must not train on its own previous answer.
      |> Enum.reject(
        &(get_in(&1, ["values", "subject"]) == c.subject["key"] and
            get_in(&1, ["values", "fingerprint"]) ==
              AtlasBus.SubjectFingerprint.of(c.subject, c.fingerprint))
      )
      |> Enum.filter(fn fact ->
        # Use the recorded snapshot, rather than today's classification of its subject.
        evidence = recorded_evidence(get_in(fact, ["values", "evidence"]))

        Enum.all?(options["same"] || [], fn field ->
          Map.has_key?(evidence, field) and
            evidence[field] == get_in(c.subject, ["values", field])
        end)
      end)
      |> Enum.take(options["window"])

    count = length(matching)
    overruled = Enum.count(matching, &(keys(&1, "overruled_by") != []))
    {:ok, if(measure == "count", do: count, else: if(count == 0, do: 0, else: overruled / count))}
  end

  defp source([[_ | _] | _] = sources, c) do
    Enum.reduce_while(sources, {:ok, []}, fn item, {:ok, acc} ->
      case source(item, c) do
        {:ok, value} -> {:cont, {:ok, acc ++ if(is_list(value), do: value, else: [value])}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, if(Enum.any?(values, &is_nil/1), do: nil, else: values)}
      error -> error
    end
  end

  defp source(other, _c), do: {:error, "unsupported evidence source #{inspect(other)}"}

  defp keys(fact, relation), do: fact |> get_in(["links", relation]) |> List.wrap() |> Enum.sort()

  defp recorded_evidence(value) when is_map(value), do: value

  defp recorded_evidence(value) when is_binary(value) do
    value
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case String.split(line, ": ", parts: 2) do
        [key, text] ->
          [
            {key,
             case JSON.decode(text) do
               {:ok, v} -> v
               _ -> text
             end}
          ]

        _ ->
          []
      end
    end)
    |> Map.new()
  end

  defp recorded_evidence(_), do: %{}
end
