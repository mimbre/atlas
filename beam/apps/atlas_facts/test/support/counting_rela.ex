defmodule AtlasFacts.CountingRela do
  @moduledoc false
  @behaviour AtlasFacts.Rela

  def schema do
    %{
      "entities" => %{
        "box" => %{"plural" => "boxes", "progress" => %{"over" => "in_box", "field" => "phase"}},
        "jar" => %{"plural" => "jars", "progress" => %{"over" => "in_jar", "field" => "phase"}},
        "bead" => %{
          "plural" => "beads",
          "completion" => %{"through" => "sealed_by", "field" => "status", "value" => "sealed"}
        },
        "tag" => %{"plural" => "tags"},
        "stamp" => %{"plural" => "stamps"},
        "clerk" => %{"plural" => "clerks"}
      },
      "relations" => %{
        "in_box" => %{"from" => ["jar"], "to" => ["box"]},
        "in_jar" => %{"from" => ["bead"], "to" => ["jar"]},
        "sealed_by" => %{"from" => ["bead"], "to" => ["stamp"]},
        "held_by" => %{"from" => ["tag"], "to" => ["clerk"]},
        "tagged" => %{
          "from" => ["box", "jar", "bead"],
          "to" => ["tag"],
          "component" => %{"key" => "T-{key}"}
        }
      },
      "progress" => %{"order" => ["packing", "sealed"]},
      "start" => %{"assigned" => %{"relation" => "held_by"}, "open" => %{}}
    }
    |> Map.update!("entities", fn entities ->
      Map.new(entities, fn {kind, spec} ->
        {kind,
         Map.put(spec, "properties", %{
           "phase" => %{"type" => "string"},
           "status" => %{"type" => "string"}
         })}
      end)
    end)
  end

  def start_link(n) do
    facts =
      for {kind, spec} <- schema()["entities"], into: %{} do
        rows =
          for i <- 1..div(n, 6) do
            key = "#{kind}-#{i}"

            links =
              case kind do
                "box" ->
                  %{"tagged" => ["tag-#{i}"]}

                "jar" ->
                  %{"in_box" => ["box-#{i}"], "tagged" => ["tag-#{i}"]}

                "bead" ->
                  %{
                    "in_jar" => ["jar-#{i}"],
                    "sealed_by" => ["stamp-#{i}"],
                    "tagged" => ["tag-#{i}"]
                  }

                "tag" ->
                  %{"held_by" => ["clerk-#{i}"]}

                _ ->
                  %{}
              end

            %{
              key: key,
              properties: %{"phase" => "packing", "status" => "open"},
              links: links,
              version: nil
            }
          end

        {spec["plural"], rows}
      end

    # Keep the requested total exact, including sizes not divisible by six.
    extras =
      for i <- 1..rem(n, 6)//1,
          rem(n, 6) > 0,
          do: %{key: "extra-#{i}", properties: %{}, links: %{}, version: nil}

    facts = Map.update!(facts, "clerks", &(&1 ++ extras))
    Agent.start_link(fn -> %{facts: facts, calls: %{}, now: 0, down: false} end)
  end

  def clock(pid), do: Agent.get(pid, & &1.now)
  def advance(pid, ms), do: Agent.update(pid, &%{&1 | now: &1.now + ms})
  def calls(pid), do: Agent.get(pid, & &1.calls)
  def reset(pid), do: Agent.update(pid, &%{&1 | calls: %{}})

  defp call(pid, op, fun) do
    Agent.get_and_update(pid, fn s ->
      s = %{s | calls: Map.update(s.calls, op, 1, &(&1 + 1))}
      if s.down, do: {{:error, :unavailable}, s}, else: fun.(s)
    end)
  end

  @impl true
  def description(pid), do: call(pid, :description, &{{:ok, schema()}, &1})
  @impl true
  def list(pid, plural), do: call(pid, {:list, plural}, &{{:ok, &1.facts[plural]}, &1})
  @impl true
  def get(pid, plural, key) do
    call(pid, :get, fn s ->
      result =
        case Enum.find(s.facts[plural], &(&1.key == key)) do
          nil -> {:error, :not_found}
          fact -> {:ok, %{fact | version: "v1"}}
        end

      {result, s}
    end)
  end

  @impl true
  def incoming(pid, _plural, key, relation) do
    call(pid, :incoming, fn s ->
      {{:ok,
        for(
          {_, facts} <- s.facts,
          fact <- facts,
          key in (fact.links[relation] || []),
          do: fact.key
        )}, s}
    end)
  end

  @impl true
  def check_create(_, _, _, _, _), do: {:ok, []}
  @impl true
  def create(pid, plural, key, props, targets) do
    call(pid, :create, fn s ->
      fact = %{key: key, properties: props, links: links(targets), version: nil}
      {s[:write_reply] || {:ok, []}, update_in(s.facts[plural], &(&1 ++ [fact]))}
    end)
  end

  @impl true
  def change(pid, plural, key, props, _version, targets) do
    call(pid, :change, fn s ->
      rows =
        Enum.map(s.facts[plural], fn fact ->
          if fact.key == key,
            do: %{
              fact
              | properties: Map.merge(fact.properties, props),
                links: Map.merge(fact.links, links(targets))
            },
            else: fact
        end)

      {s[:write_reply] || {:ok, []}, put_in(s.facts[plural], rows)}
    end)
  end

  @impl true
  def delete(pid, plural, key, _version) do
    call(pid, :delete, fn s ->
      s = update_in(s.facts[plural], &Enum.reject(&1, fn fact -> fact.key == key end))

      facts =
        Map.new(s.facts, fn {from, rows} ->
          {from,
           Enum.map(rows, fn fact ->
             links = Map.new(fact.links, fn {rel, keys} -> {rel, List.delete(keys, key)} end)
             %{fact | links: links}
           end)}
        end)

      {:ok, %{s | facts: facts}}
    end)
  end

  defp links(targets), do: Map.new(targets, fn {rel, {_, keys}} -> {rel, keys} end)
end
