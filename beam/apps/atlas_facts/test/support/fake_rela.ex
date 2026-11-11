defmodule AtlasFacts.FakeRela do
  @moduledoc """
  rela in memory, with the current release's habits: invalid values are stored with
  warnings, a second create answers "exists", a deleted id stays reserved, versions
  are checked when given. Its kinds are made up on purpose: Facts must not care.
  """
  @behaviour AtlasFacts.Rela

  def description do
    %{
      "entities" => %{
        "widget" => %{
          "plural" => "widgets",
          "primary" => "title",
          "id_type" => "manual",
          "id_prefixes" => ["W-"],
          "properties" => %{
            "title" => %{"type" => "string", "required" => true},
            "shade" => %{"type" => "shade", "values" => ["light", "dark"]},
            "done" => %{"type" => "boolean"}
          }
        },
        "part" => %{"plural" => "parts", "properties" => %{"title" => %{"type" => "string"}}},
        "maker" => %{"plural" => "makers", "properties" => %{"title" => %{"type" => "string"}}}
      },
      "relations" => %{
        "of_widget" => %{"from" => ["part"], "to" => ["widget"], "max_outgoing" => 1},
        "made_by" => %{"from" => ["widget", "part"], "to" => ["maker"], "max_outgoing" => 1}
      }
    }
  end

  def start do
    {:ok, pid} =
      Agent.start_link(fn ->
        %{facts: %{}, reserved: MapSet.new(), up: true, links: %{}, n: 0, plurals: %{}}
      end)

    pid
  end

  def down(pid), do: Agent.update(pid, &%{&1 | up: false})
  def up(pid), do: Agent.update(pid, &%{&1 | up: true})
  def facts(pid), do: Agent.get(pid, & &1.facts)
  def links(pid), do: Agent.get(pid, & &1.links)

  def link(pid, part, widget, relation \\ "of_widget"),
    do: Agent.update(pid, &%{&1 | links: put_links(&1.links, part, relation, [widget])})

  defp put_links(links, key, relation, keys) do
    own = Map.get(links, key, %{})
    own = if keys == [], do: Map.delete(own, relation), else: Map.put(own, relation, keys)
    Map.put(links, key, own)
  end

  @doc "Change a fact behind Facts' back, as another writer would."
  def poke(pid, key, values) do
    Agent.update(pid, fn s ->
      {props, n} = s.facts[key]
      %{s | facts: Map.put(s.facts, key, {Map.merge(props, values), n + 100})}
    end)
  end

  defp call(pid, fun) do
    Agent.get_and_update(pid, fn s ->
      if s.up, do: fun.(s), else: {{:error, :unavailable}, s}
    end)
  end

  @impl true
  def description(pid), do: call(pid, &{{:ok, description()}, &1})

  @impl true
  def list(pid, _plural) do
    call(pid, fn s ->
      facts =
        for {k, {p, _}} <- Enum.sort(s.facts),
            do: %{key: k, properties: p, links: links_of(s, k), version: nil}

      {{:ok, facts}, s}
    end)
  end

  # As rela: a fact is only found under its own kind (the kind it was made in).
  @impl true
  def get(pid, plural, key) do
    call(pid, fn s ->
      case {s.facts[key], s.plurals[key]} do
        {{p, n}, of} when of in [nil, plural] ->
          {{:ok, %{key: key, properties: p, links: links_of(s, key), version: "v#{n}"}}, s}

        _ ->
          {{:error, :not_found}, s}
      end
    end)
  end

  @impl true
  def incoming(pid, _plural, key, relation) do
    call(pid, fn s ->
      {{:ok, for({from, own} <- s.links, key in Map.get(own, relation, []), do: from)}, s}
    end)
  end

  @impl true
  def check_create(pid, _plural, _key, props, _targets),
    do: call(pid, &{{:ok, warnings(props)}, &1})

  @impl true
  def create(pid, plural, key, props, targets) do
    call(pid, fn s ->
      cond do
        Map.has_key?(s.facts, key) or key in s.reserved ->
          {{:error, :exists}, s}

        Enum.any?(targets, fn {_, {_, keys}} ->
          Enum.any?(keys, &(not Map.has_key?(s.facts, &1)))
        end) ->
          {{:error, {:invalid, ["the fact it points at does not exist"]}}, s}

        true ->
          links =
            Enum.reduce(targets, s.links, fn {relation, {_, keys}}, acc ->
              put_links(acc, key, relation, keys)
            end)

          {{:ok, warnings(props)},
           %{
             s
             | facts: Map.put(s.facts, key, {props, s.n}),
               n: s.n + 1,
               links: links,
               plurals: Map.put(s.plurals, key, plural)
           }}
      end
    end)
  end

  defp links_of(s, key), do: Map.get(s.links, key, %{})

  @impl true
  def change(pid, _plural, key, props, version, targets) do
    call(pid, fn s ->
      case s.facts[key] do
        nil ->
          {{:error, :not_found}, s}

        {old, n} ->
          cond do
            stale?(version, n) ->
              {{:error, :version_mismatch}, s}

            Enum.any?(targets, fn {_, {_, keys}} ->
              Enum.any?(keys, &(not Map.has_key?(s.facts, &1)))
            end) ->
              {{:error, {:invalid, ["the fact it points at does not exist"]}}, s}

            true ->
              changed(s, key, old, props, targets)
          end
      end
    end)
  end

  # A relation given replaces what the fact pointed at, as rela's PATCH does.
  defp changed(s, key, old, props, targets) do
    new = old |> Map.merge(props) |> Map.reject(fn {_, v} -> is_nil(v) end)

    links =
      Enum.reduce(targets, s.links, fn {relation, {_, keys}}, acc ->
        put_links(acc, key, relation, keys)
      end)

    {{:ok, warnings(new)},
     %{s | facts: Map.put(s.facts, key, {new, s.n}), n: s.n + 1, links: links}}
  end

  @impl true
  def delete(pid, _plural, key, version) do
    call(pid, fn s ->
      case s.facts[key] do
        nil ->
          {{:error, :not_found}, s}

        {_, n} ->
          if stale?(version, n),
            do: {{:error, :version_mismatch}, s},
            else:
              {:ok, %{s | facts: Map.delete(s.facts, key), reserved: MapSet.put(s.reserved, key)}}
      end
    end)
  end

  defp stale?(nil, _n), do: false
  defp stale?(version, n), do: version != "v#{n}"

  defp warnings(props) do
    if Map.has_key?(props, "title"), do: [], else: ["/properties/title is required"]
  end
end
