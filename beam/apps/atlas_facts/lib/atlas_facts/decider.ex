defmodule AtlasFacts.Decider do
  @moduledoc "Finds the newest subject verdict for authority, directly from the store."
  alias AtlasFacts.Rela

  def lookup(description, rela, config, gate, key) do
    plural = get_in(description, ["entities", config["kind"], "plural"])

    if is_binary(plural) do
      case Rela.list(rela, plural) do
        {:ok, facts} -> newest(facts, gate, key, config["relation"])
        _ -> nil
      end
    end
  end

  def newest(facts, gate, key, relation) do
    facts
    |> Enum.filter(fn fact ->
      values = fact.properties

      values["gate"] == gate and values["subject"] == key and values["purpose"] == "decider" and
        key in List.wrap(get_in(fact, [:links, relation]))
    end)
    |> Enum.max_by(&{&1.properties["decided_at"] || "", &1.key}, fn -> nil end)
    |> case do
      nil -> nil
      fact -> fact.properties
    end
  end
end
