defmodule AtlasFacts.Freshness.Changes do
  @moduledoc """
  What a write changed: one entry per fact, for the `changes` of its `stored` hint
  (docs/design/page-freshness.md §1.2). Facts stores every write, with what it brings
  along (components, the facts it replaces, a run's records), through rela; while a
  write is handled the store is wrapped by a recorder (`recorder/2`), so every create,
  change and delete that rela accepted is noted, with the fact as it was before. One
  write may touch a fact more than once; its entry says what differs between before the
  first and after the last.

  An entry: `%{"kind", "key", "op" => "create" | "change" | "delete", "fields",
  "relinked", "links"}`:

    * `fields`: the properties whose values differ (on a create: those it sets; on a
      delete: those the fact had);
    * `relinked`: the relations whose targets differ;
    * `links`: per outgoing relation, its targets before ∪ after (only relations with
      targets), so a change of a fact's own fields still says what it hangs under.

  A change that changed nothing has no entry. The fact the write is about comes first.
  """
  @behaviour AtlasFacts.Rela

  alias AtlasFacts.Rela

  @doc "A new, empty record of changes, held by the calling process until `close/1`."
  def open do
    log = make_ref()
    Process.put(log, [])
    log
  end

  def close(log), do: Process.delete(log)

  @doc "`backend` (a store, `{module, config}`), noting each write it accepts in `log`."
  def recorder(backend, log), do: {__MODULE__, %{backend: backend, log: log}}

  @doc """
  The entries of what `log` noted so far, `first` (`{kind, key}`, the fact the write is
  about) first. Kinds are named by `description` (rela's schema: a plural's kind).
  """
  def of(nil, _description, _first), do: []

  def of(log, description, first) do
    kinds =
      for {kind, %{"plural" => plural}} <- (description || %{})["entities"] || %{},
          into: %{},
          do: {plural, kind}

    entries =
      (Process.get(log) || [])
      |> Enum.reverse()
      |> Enum.reduce({[], %{}}, fn {plural, key, before, later}, {order, acc} ->
        case acc do
          %{{^plural, ^key} => {first, _}} ->
            {order, Map.put(acc, {plural, key}, {first, later})}

          _ ->
            {[{plural, key} | order], Map.put(acc, {plural, key}, {before, later})}
        end
      end)
      |> then(fn {order, acc} ->
        for {plural, key} <- Enum.reverse(order),
            kind = kinds[plural],
            kind != nil,
            {before, later} = acc[{plural, key}],
            entry = entry(kind, key, before, later),
            entry != nil,
            do: entry
      end)

    {own, others} = Enum.split_with(entries, &({&1["kind"], &1["key"]} == first))
    own ++ others
  end

  @doc """
  The entry of the fact `key` of `kind`, from how it was (`before`) to how it is
  (`later`), each `%{values, links}` or nil (absent); nil when nothing differs. Pure.
  """
  def entry(_kind, _key, nil, nil), do: nil

  def entry(kind, key, before, later) do
    old = before || %{values: %{}, links: %{}}
    new = later || %{values: %{}, links: %{}}
    names = Enum.uniq(Map.keys(old.values) ++ Map.keys(new.values))
    relations = Enum.uniq(Map.keys(old.links) ++ Map.keys(new.links))

    {op, fields, relinked} =
      case {before, later} do
        {nil, _} ->
          {"create", present(new.values), linked(new.links)}

        {_, nil} ->
          {"delete", present(old.values), linked(old.links)}

        _ ->
          {"change", Enum.filter(names, &(loose(old.values[&1]) != loose(new.values[&1]))),
           Enum.filter(relations, &(targets(old.links, &1) != targets(new.links, &1)))}
      end

    links =
      for relation <- relations,
          keys =
            Enum.sort(Enum.uniq(targets(old.links, relation) ++ targets(new.links, relation))),
          keys != [],
          into: %{},
          do: {relation, keys}

    if op == "change" and fields == [] and relinked == [] do
      nil
    else
      %{
        "kind" => kind,
        "key" => key,
        "op" => op,
        "fields" => Enum.sort(fields),
        "relinked" => Enum.sort(relinked),
        "links" => links
      }
    end
  end

  defp present(values), do: for({name, value} <- values, loose(value) != nil, do: name)
  defp linked(links), do: for({relation, keys} <- links, keys not in [nil, []], do: relation)
  defp targets(links, relation), do: Enum.sort(List.wrap(links[relation]))

  defp loose(value) when value in [nil, ""], do: nil
  defp loose(value), do: value

  defp note(c, plural, key, before, later),
    do: Process.put(c.log, [{plural, key, before, later} | Process.get(c.log) || []])

  defp shape(%{properties: properties} = fact),
    do: %{values: properties || %{}, links: fact[:links] || %{}}

  defp was(c, plural, key) do
    case Rela.get(c.backend, plural, key) do
      {:ok, fact} -> shape(fact)
      _ -> nil
    end
  end

  defp keys(targets), do: Map.new(targets, fn {relation, {_kind, keys}} -> {relation, keys} end)

  # Reads go through as they are.

  @impl true
  def description(c), do: Rela.description(c.backend)
  @impl true
  def list(c, plural), do: Rela.list(c.backend, plural)
  @impl true
  def get(c, plural, key), do: Rela.get(c.backend, plural, key)
  @impl true
  def incoming(c, plural, key, relation), do: Rela.incoming(c.backend, plural, key, relation)

  @impl true
  def check_create(c, plural, key, props, targets),
    do: Rela.check_create(c.backend, plural, key, props, targets)

  # Writes are noted once rela accepted them.

  @impl true
  def create(c, plural, key, props, targets) do
    result = Rela.create(c.backend, plural, key, props, targets)

    with {:ok, _} <- result do
      values = Map.reject(props, fn {_, v} -> v == nil end)
      note(c, plural, key, nil, %{values: values, links: keys(targets)})
    end

    result
  end

  @impl true
  def change(c, plural, key, props, version, targets) do
    # Not readable before: what it sets counts as changed.
    before = was(c, plural, key) || %{values: %{}, links: %{}}
    result = Rela.change(c.backend, plural, key, props, version, targets)

    with {:ok, _} <- result do
      old = before

      later = %{
        values: old.values |> Map.merge(props) |> Map.reject(fn {_, v} -> v == nil end),
        links: Map.merge(old.links, keys(targets))
      }

      note(c, plural, key, before, later)
    end

    result
  end

  @impl true
  def delete(c, plural, key, version) do
    before = was(c, plural, key)
    result = Rela.delete(c.backend, plural, key, version)
    if result == :ok and before != nil, do: note(c, plural, key, before, nil)
    result
  end
end
