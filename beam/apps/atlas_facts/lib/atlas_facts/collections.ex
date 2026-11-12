defmodule AtlasFacts.Collections do
  @moduledoc """
  Bounded raw collection copies owned by Facts. Every mutation discards all
  copies, including failed writes whose response may have been lost after commit.
  Outside writers are bounded by the freshness interval; private fixtures flush
  explicitly after direct writes. Enriched answers are always computed again.

  Point reads use fresh copies, including absent keys, and otherwise read through
  to Rela without loading a collection. Copies carry the collection's versions
  (normally nil: Rela's list endpoint supplies no ETag).
  Protocol reads and mutation checks bypass copies entirely. No row-refresh reads
  are issued after writes, so a refresh cannot consume an authority-read failure.
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

  def clear({__MODULE__, c}) do
    :ets.delete_all_objects(c.table)
    :ok
  end

  def mutation(copy, fun) do
    clear(copy)

    try do
      fun.()
    after
      clear(copy)
    end
  end

  # Protocol projections and mutation checks need current rows and ETags, including
  # list reads. Writes invalidate the same table through either view.
  def uncached({__MODULE__, c}), do: {__MODULE__, Map.put(c, :reads, :backend)}

  @doc "The same copies over `wrap.(backend)`: a store that notes what is written through it."
  def through({__MODULE__, c}, wrap), do: {__MODULE__, %{c | backend: wrap.(c.backend)}}

  @impl true
  def get(%{reads: :backend} = c, plural, key), do: Rela.get(c.backend, plural, key)

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
  def list(%{reads: :backend} = c, plural), do: Rela.list(c.backend, plural)

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
    do: mutation({__MODULE__, c}, fn -> Rela.create(c.backend, plural, key, props, targets) end)

  @impl true
  def change(c, plural, key, props, version, targets),
    do:
      mutation({__MODULE__, c}, fn ->
        Rela.change(c.backend, plural, key, props, version, targets)
      end)

  @impl true
  def delete(c, plural, key, version),
    do: mutation({__MODULE__, c}, fn -> Rela.delete(c.backend, plural, key, version) end)
end
