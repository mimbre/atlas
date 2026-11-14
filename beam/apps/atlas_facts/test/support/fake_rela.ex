defmodule AtlasFacts.FakeRela do
  @moduledoc """
  rela in memory, with the current release's habits: invalid values are stored with
  warnings, a second create answers "exists", a deleted id stays reserved, versions
  are checked when given. Its kinds are made up on purpose: Facts must not care.
  """
  @behaviour AtlasFacts.Rela

  @doc "What it serves at `_schema` by default: the neutral workshop's schema, as rela serves it."
  def description, do: AtlasFacts.Workshop.rela_schema()

  @doc "A rela that serves `model`'s schema (`rela_schema/0`)."
  def start(model \\ AtlasFacts.Workshop) do
    {:ok, pid} =
      Agent.start_link(fn ->
        %{
          facts: %{},
          reserved: MapSet.new(),
          up: true,
          links: %{},
          n: 0,
          plurals: %{},
          schema: model.rela_schema()
        }
      end)

    pid
  end

  @doc "Serve `model`'s schema from now on, as a rela restarted with it would."
  def serve(pid, model), do: Agent.update(pid, &%{&1 | schema: model.rela_schema()})

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
  def description(pid), do: call(pid, &{{:ok, &1.schema}, &1})

  # As rela: a kind lists the facts made in it (and those put without one).
  @impl true
  def list(pid, plural) do
    call(pid, fn s ->
      facts =
        for {k, {p, _}} <- Enum.sort(s.facts),
            s.plurals[k] in [nil, plural],
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
  def check_create(pid, plural, _key, props, _targets),
    do: call(pid, &{{:ok, warnings(&1, plural, props)}, &1})

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

          {{:ok, warnings(s, plural, props)},
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

    {{:ok, warnings(s, s.plurals[key], new)},
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

  # A fact of a kind with a title, or of a kind the schema does not serve, is stored
  # with a warning when it has none; a kind without a title field (Flow's runs) is not.
  defp warnings(s, plural, props) do
    kind =
      Enum.find_value(s.schema["entities"] || %{}, fn {_, e} -> e["plural"] == plural && e end)

    titled = kind == nil or Map.has_key?(kind["properties"] || %{}, "title")

    if titled and not Map.has_key?(props, "title"),
      do: ["/properties/title is required"],
      else: []
  end
end
