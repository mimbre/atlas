defmodule AtlasFacts.Collections do
  @moduledoc """
  Facts' raw collection copies. The Facts process owns the table; enriched answers
  are always computed again. A copy expires five seconds after its list began,
  including when local writes refresh individual rows: outside writers cannot keep
  an old copy alive indefinitely. Failed reloads never serve expired data.

  Point reads use fresh copies, including absent keys, and otherwise read through
  to Rela without loading a collection. Copies carry the collection's versions
  (normally nil: Rela's list endpoint supplies no ETag).
  After a write, reread just that
  row (Rela may normalize values or store warnings). An uncertain refresh evicts
  its collection. This also covers components, replacements and guidance.
  """
  @behaviour AtlasFacts.Rela
  alias AtlasFacts.Rela

  def open(backend, opts \\ []) do
    ttl =
      Keyword.get(
        opts,
        :collection_freshness_ms,
        Application.get_env(:atlas_facts, :collection_freshness_ms, 5_000)
      )

    true = is_integer(ttl) and ttl >= 0

    {__MODULE__,
     %{
       backend: backend,
       table: :ets.new(__MODULE__, [:set, :private]),
       ttl: ttl,
       clock: Keyword.get(opts, :collection_clock, fn -> System.monotonic_time(:millisecond) end)
     }}
  end

  @impl true
  def description(c), do: Rela.description(c.backend)

  # Mutation checks need current rows and ETags, while writes still reconcile the
  # same collection table. This view lasts only for the mutation request.
  def for_write({__MODULE__, c}), do: {__MODULE__, Map.put(c, :point_reads, :backend)}

  @impl true
  def get(%{point_reads: :backend} = c, plural, key), do: Rela.get(c.backend, plural, key)

  def get(c, plural, key) do
    now = c.clock.()

    case :ets.lookup(c.table, plural) do
      [{^plural, since, facts}] when now - since < c.ttl ->
        case Enum.find(facts, &(&1.key == key)) do
          nil -> {:error, :not_found}
          fact -> {:ok, fact}
        end

      _ ->
        Rela.get(c.backend, plural, key)
    end
  end

  @impl true
  def incoming(c, plural, key, relation), do: Rela.incoming(c.backend, plural, key, relation)
  @impl true
  def check_create(c, plural, key, props, targets),
    do: Rela.check_create(c.backend, plural, key, props, targets)

  @impl true
  def list(c, plural) do
    now = c.clock.()

    case :ets.lookup(c.table, plural) do
      [{^plural, since, facts}] when now - since < c.ttl ->
        {:ok, facts}

      _ ->
        :ets.delete(c.table, plural)

        case Rela.list(c.backend, plural) do
          {:ok, facts} = result ->
            :ets.insert(c.table, {plural, now, facts})
            result

          error ->
            error
        end
    end
  end

  @impl true
  def create(c, plural, key, props, targets),
    do: written(c, plural, key, Rela.create(c.backend, plural, key, props, targets))

  @impl true
  def change(c, plural, key, props, version, targets),
    do: written(c, plural, key, Rela.change(c.backend, plural, key, props, version, targets))

  @impl true
  def delete(c, plural, key, version) do
    result = written(c, plural, key, Rela.delete(c.backend, plural, key, version))

    # A backend may remove incoming links along with the row. Refresh only cached
    # rows that pointed at it; keep every other collection and its expiry intact.
    for {from, _since, facts} <- :ets.tab2list(c.table),
        fact <- facts,
        Enum.any?(fact.links, fn {_, keys} -> key in keys end) do
      written(c, from, fact.key, :ok)
    end

    result
  end

  defp written(c, plural, key, result) do
    case :ets.lookup(c.table, plural) do
      [{^plural, since, facts}] ->
        # Reconcile even a failed write: its response may have been lost after commit.
        case Rela.get(c.backend, plural, key) do
          {:ok, fact} ->
            # Collection responses carry no ETag, unlike point reads.
            fact = %{fact | version: nil}

            facts =
              if Enum.any?(facts, &(&1.key == key)),
                do: Enum.map(facts, &if(&1.key == key, do: fact, else: &1)),
                else: facts ++ [fact]

            :ets.insert(c.table, {plural, since, facts})

          {:error, :not_found} ->
            :ets.insert(c.table, {plural, since, Enum.reject(facts, &(&1.key == key))})

          _ ->
            :ets.delete(c.table, plural)
        end

      [] ->
        :ok
    end

    result
  end
end
