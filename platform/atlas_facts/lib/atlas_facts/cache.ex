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

  Reads are also answered outside Facts' process, while it waits for rela on a write
  (`consistently/2`, IS-Atlas-85). Those see the copy as Facts last published it: a write
  is staged in Facts' process (`stage/1`), where Facts' own reads see it, and put here
  whole (`publish/3`), with Facts' position, before Facts answers it. A generation, odd
  while Facts puts, tells a reader that the copy changed under it: it reads again, so it
  never sees a write half applied.
  """
  @behaviour AtlasFacts.Rela

  require Logger

  alias AtlasFacts.Rela

  def open(backend) do
    table = :ets.new(__MODULE__, [:ordered_set, :protected, read_concurrency: true])
    meta = :ets.new(__MODULE__, [:set, :protected, read_concurrency: true])
    :ets.insert(meta, [{:generation, 0}, {:position, 0}, {:description, nil}])
    {__MODULE__, %{backend: backend, table: table, meta: meta}}
  end

  def loaded?({__MODULE__, c}), do: :ets.member(c.table, :relations)

  # Facts' process only: what it put since it last published (`{plural, key} => fact or
  # :gone`), whether readers are told the copy is changing, what it published last.
  defp staged_key(c), do: {__MODULE__, c.table, :staged}
  defp open_key(c), do: {__MODULE__, c.table, :open}
  defp published_key(c), do: {__MODULE__, c.table, :published}

  @doc "From now on, in the calling process (Facts'), writes are staged until `publish/3`."
  def stage({__MODULE__, c}), do: Process.put(staged_key(c), Process.get(staged_key(c), %{}))

  @doc """
  Tell readers the copy is changing, before Facts changes what they read beside it (the
  origins of links, `AtlasFacts.Links`); `publish/3` tells them it is done.
  """
  def changing({__MODULE__, c}), do: open_window(c)

  defp open_window(c) do
    if Process.get(open_key(c)) != true do
      :ets.update_counter(c.meta, :generation, 1)
      Process.put(open_key(c), true)
    end

    :ok
  end

  @doc """
  Put what was staged here, with Facts' `position` and rela's `description`, for the reads
  answered outside Facts. Nothing changes for them when nothing did.
  """
  def publish({__MODULE__, c}, position, description) do
    staged = Process.get(staged_key(c), %{})
    published = Process.get(published_key(c))
    moved? = not match?({^position, ^description}, published)

    if staged != %{} or moved? or Process.get(open_key(c)) == true do
      open_window(c)
      {gone, put} = Enum.split_with(staged, fn {_at, fact} -> fact == :gone end)
      for {at, :gone} <- gone, do: :ets.delete(c.table, at)
      :ets.insert(c.table, put)

      if moved? do
        :ets.insert(c.meta, [{:position, position}, {:description, description}])
        Process.put(published_key(c), {position, description})
      end

      if Process.get(staged_key(c)), do: Process.put(staged_key(c), %{})
      :ets.update_counter(c.meta, :generation, 1)
      Process.delete(open_key(c))
    end

    :ok
  end

  @doc """
  Run `fun` on the copy as last published, from any process: `fun` gets `%{position,
  description}` and reads the copy (`get/3`, `list/2`, `incoming/4`). Run again when Facts
  published meanwhile; `{:ok, result}`, or `:busy` when the copy kept changing for a second.
  """
  def consistently({__MODULE__, c}, fun), do: consistently(c, fun, deadline(), 0)

  defp consistently(c, fun, deadline, tries) do
    [{:generation, before}] = :ets.lookup(c.meta, :generation)

    result =
      if rem(before, 2) == 0 do
        [{:position, position}] = :ets.lookup(c.meta, :position)
        [{:description, description}] = :ets.lookup(c.meta, :description)
        {:ok, fun.(%{position: position, description: description})}
      end

    cond do
      result != nil and :ets.lookup(c.meta, :generation) == [{:generation, before}] ->
        result

      System.monotonic_time(:millisecond) > deadline ->
        :busy

      true ->
        # Facts puts a write in a moment (no rela request in between): yield, then sleep.
        if tries < 100, do: :erlang.yield(), else: Process.sleep(1)
        consistently(c, fun, deadline, tries + 1)
    end
  end

  defp deadline, do: System.monotonic_time(:millisecond) + 1_000

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
      # Put at once, between rela's answers and `publish/3`: readers wait for it.
      open_window(c)
      if Process.get(staged_key(c)), do: Process.put(staged_key(c), %{})
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
      for {key, _before, nil} <- gone, do: drop(c, plural, key)
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

  defp put(c, plural, fact), do: stage(c, {plural, fact.key}, fact)
  defp drop(c, plural, key), do: stage(c, {plural, key}, :gone)

  # Staged while Facts handles a message; put here at once otherwise (a load at start).
  defp stage(c, at, fact) do
    case Process.get(staged_key(c)) do
      nil ->
        open_window(c)
        if fact == :gone, do: :ets.delete(c.table, at), else: :ets.insert(c.table, {at, fact})

      staged ->
        Process.put(staged_key(c), Map.put(staged, at, fact))
    end
  end

  @impl true
  def description(c), do: Rela.description(c.backend)

  # Facts' own reads see what it staged; any other process's, what was published.
  @impl true
  def list(c, plural) do
    held = :ets.select(c.table, [{{{plural, :_}, :"$1"}, [], [:"$1"]}])
    staged = for {{^plural, key}, fact} <- Process.get(staged_key(c)) || %{}, do: {key, fact}

    if staged == [] do
      {:ok, held}
    else
      facts =
        held
        |> Map.new(&{&1.key, &1})
        |> Map.merge(Map.new(staged))
        |> Enum.reject(fn {_key, fact} -> fact == :gone end)
        |> Enum.sort()
        |> Enum.map(&elem(&1, 1))

      {:ok, facts}
    end
  end

  @impl true
  def get(c, plural, key) do
    case Map.fetch(Process.get(staged_key(c)) || %{}, {plural, key}) do
      {:ok, :gone} ->
        {:error, :not_found}

      {:ok, fact} ->
        {:ok, fact}

      :error ->
        case :ets.lookup(c.table, {plural, key}) do
          [{_, fact}] -> {:ok, fact}
          [] -> {:error, :not_found}
        end
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
    if get(c, plural, key) == {:error, :not_found} do
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
        drop(c, plural, key)

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
      nil -> drop(c, plural, key)
      fact -> put(c, plural, fact)
    end
  end

  defp keys(targets), do: Map.new(targets, fn {relation, {_kind, keys}} -> {relation, keys} end)
end
