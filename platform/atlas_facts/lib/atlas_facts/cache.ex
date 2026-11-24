defmodule AtlasFacts.Cache do
  @moduledoc """
  Every fact of every described kind, in Facts' memory. Loaded from rela in full when
  Facts has rela's description (`load/2`), before it answers a read; then every read is
  answered from here, and every write goes to rela first and is put here once rela
  accepted it. rela stays the store; this is a copy of it that Facts keeps current.

  After each write the fact is read back from rela, so the copy is rela's and carries
  its version. A fact loaded from a list has no version (rela lists none) until Facts
  writes it. When the read-back fails, an accepted write is put here as Facts sent it.

  Facts is not the only writer: rela's own sync connectors write too. Facts hears of
  those through rela's change feed (`AtlasFacts.Rela.Events`) and reads that kind again
  (`refresh/2`); a kind no feed names is not seen until `load/2` runs again (a restart).
  """
  @behaviour AtlasFacts.Rela

  require Logger

  alias AtlasFacts.Rela

  def open(backend) do
    {__MODULE__, %{backend: backend, table: :ets.new(__MODULE__, [:ordered_set, :protected])}}
  end

  def loaded?({__MODULE__, c}), do: :ets.member(c.table, :relations)

  @doc "Read every kind `description` names from rela, replacing what was here."
  def load({__MODULE__, c}, description) do
    started = System.monotonic_time(:millisecond)
    plurals = for {_kind, %{"plural" => plural}} <- description["entities"] || %{}, do: plural

    listed =
      Enum.reduce_while(plurals, {:ok, []}, fn plural, {:ok, acc} ->
        case Rela.list(c.backend, plural) do
          {:ok, facts} -> {:cont, {:ok, [{plural, facts} | acc]}}
          error -> {:halt, error}
        end
      end)

    with {:ok, listed} <- listed do
      :ets.delete_all_objects(c.table)
      for {plural, facts} <- listed, fact <- facts, do: put(c, plural, fact)
      :ets.insert(c.table, {:relations, relation_kinds(description)})

      counts = listed |> Enum.map(fn {plural, facts} -> {plural, length(facts)} end)

      Logger.info(
        "Facts loaded #{Enum.sum_by(counts, &elem(&1, 1))} facts from rela in " <>
          "#{System.monotonic_time(:millisecond) - started} ms, " <>
          "#{div(:ets.info(c.table, :memory) * :erlang.system_info(:wordsize), 1024)} KiB: " <>
          (counts
           |> Enum.sort_by(&elem(&1, 1), :desc)
           |> Enum.map_join(", ", fn {p, n} -> "#{p} #{n}" end))
      )

      :ok
    end
  end

  @doc """
  Read `plural` from rela again and put here what differs from the copy: what another
  writer changed in rela. Answers `{:ok, [{key, before, after}]}`, nil for a fact that was
  not there (before) or is gone (after). A fact that did not change keeps its version.
  """
  def refresh({__MODULE__, c}, plural) do
    with {:ok, facts} <- Rela.list(c.backend, plural) do
      {:ok, held} = list(c, plural)
      held = Map.new(held, &{&1.key, &1})
      read = Map.new(facts, &{&1.key, &1})

      changed =
        for {key, fact} <- read, not same?(held[key], fact), do: {key, held[key], fact}

      gone = for {key, fact} <- held, not Map.has_key?(read, key), do: {key, fact, nil}

      for {_key, _before, fact} <- changed, do: put(c, plural, fact)
      for {key, _before, nil} <- gone, do: :ets.delete(c.table, {plural, key})
      {:ok, changed ++ gone}
    end
  end

  defp same?(nil, _fact), do: false
  defp same?(held, fact), do: held.properties == fact.properties and held.links == fact.links

  # The kinds each relation points from and to: `%{relation => {[plural], [plural]}}`.
  defp relation_kinds(description) do
    plurals = fn kinds ->
      for kind <- kinds || [], do: get_in(description, ["entities", kind, "plural"])
    end

    Map.new(description["relations"] || %{}, fn {relation, spec} ->
      {relation, {plurals.(spec["from"]), plurals.(spec["to"])}}
    end)
  end

  defp relations(c) do
    [{:relations, relations}] = :ets.lookup(c.table, :relations)
    relations
  end

  defp put(c, plural, fact), do: :ets.insert(c.table, {{plural, fact.key}, fact})

  @impl true
  def description(c), do: Rela.description(c.backend)

  @impl true
  def list(c, plural) do
    {:ok, :ets.select(c.table, [{{{plural, :_}, :"$1"}, [], [:"$1"]}])}
  end

  @impl true
  def get(c, plural, key) do
    case :ets.lookup(c.table, {plural, key}) do
      [{_, fact}] -> {:ok, fact}
      [] -> {:error, :not_found}
    end
  end

  @impl true
  def incoming(c, _plural, key, relation) do
    {froms, _tos} = Map.get(relations(c), relation, {[], []})

    keys =
      for from <- froms,
          fact <- elem(list(c, from), 1),
          key in (fact.links[relation] || []),
          do: fact.key

    {:ok, keys}
  end

  @impl true
  def check_create(c, plural, key, props, targets),
    do: Rela.check_create(c.backend, plural, key, props, targets)

  @impl true
  def create(c, plural, key, props, targets) do
    result = Rela.create(c.backend, plural, key, props, targets)

    written(c, plural, key, result, fn ->
      values = Map.reject(props, fn {_, v} -> v == nil end)
      %{key: key, properties: values, links: keys(targets), version: nil}
    end)
  end

  @impl true
  def change(c, plural, key, props, version, targets) do
    before = get(c, plural, key)
    result = Rela.change(c.backend, plural, key, props, version, targets)

    written(c, plural, key, result, fn ->
      # A change of a fact that was not here: dropped rather than guessed.
      with {:ok, old} <- before do
        %{
          old
          | properties: old.properties |> Map.merge(props) |> Map.reject(&(elem(&1, 1) == nil)),
            links: old.links |> Map.merge(keys(targets)) |> Map.reject(&(elem(&1, 1) == [])),
            version: nil
        }
      else
        _ -> nil
      end
    end)
  end

  @impl true
  def delete(c, plural, key, version) do
    result = Rela.delete(c.backend, plural, key, version)
    written(c, plural, key, result, fn -> nil end)

    # rela drops the links that pointed at a deleted fact: those facts are read back too.
    if not :ets.member(c.table, {plural, key}) do
      for {relation, {froms, tos}} <- relations(c),
          plural in tos,
          from <- froms,
          fact <- elem(list(c, from), 1),
          key in (fact.links[relation] || []) do
        written(c, from, fact.key, :ok, fn ->
          %{fact | links: Map.update!(fact.links, relation, &(&1 -- [key])), version: nil}
        end)
      end
    end

    result
  end

  # After any write, accepted or not (a lost answer may hide a stored one), the fact is
  # read back. When that fails too, an accepted write is put here as it was sent.
  defp written(c, plural, key, result, sent) do
    case Rela.get(c.backend, plural, key) do
      {:ok, fact} ->
        put(c, plural, fact)

      {:error, :not_found} ->
        :ets.delete(c.table, {plural, key})

      error ->
        Logger.warning("Facts could not read #{plural}/#{key} back: #{inspect(error)}")
        if accepted?(result), do: put_sent(c, plural, key, sent)
    end

    result
  end

  defp accepted?({:ok, _}), do: true
  defp accepted?(:ok), do: true
  defp accepted?(_), do: false

  defp put_sent(c, plural, key, sent) do
    case sent.() do
      nil -> :ets.delete(c.table, {plural, key})
      fact -> put(c, plural, fact)
    end
  end

  defp keys(targets), do: Map.new(targets, fn {relation, {_kind, keys}} -> {relation, keys} end)
end
