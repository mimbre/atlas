defmodule AtlasPlan.Producer do
  @moduledoc """
  The UC-Atlas-23 one-off: every scene, use case and issue records its producer
  (`produced_by`), also one made before producers were recorded.

  For each item without one, it reads what Facts records of the write that made it: the
  oldest entry of the links a create sets (its parent and its Assignment; Facts keeps
  every entry of a link, with who sent it and why, `AtlasFacts.Links`). From that entry:

    * made by Flow (`by` is `flow`): the person its cause names, `For <person>: proposed
      by …` (a break-down's or a review's run's supervisor);
    * put in by an agent on someone's behalf: the person its cause names (`… on behalf
      of <person>`);
    * made by hand: the person who sent it;
    * made by an agent: the person that agent assists (`assists` in the environment's
      settings);
    * otherwise (no such entry, or one by a migration, a connector or an agent that
      assists nobody): the configured decider (`actors.decider`).

  It reads and writes only through Control, as a client that says it is the migration,
  which the relation lets set it (`set_by: [:flow, :migration]`): one change per item,
  linking `produced_by`, with a cause that says it was backfilled and from what. A dry run
  reads and prints the steps, and writes nothing. A second run finds nothing to do.

  rela offers neither half itself (D-0100; asked of the pinned 26.11.9): `rela migrate
  data`'s `lua` step rewrites an entity's properties but sets no relation, and rela
  records no Atlas writer and keeps history only in its postgres build. Those are requests
  for the rela project.
  """

  @relation "produced_by"
  @kinds ["scene", "use_case", "issue"]

  # The links a create of each kind sets, whose oldest entry is the create's.
  @made_with %{
    "scene" => ["assignment"],
    "use_case" => ["in_scene", "assignment"],
    "issue" => ["in_use_case", "assignment"]
  }

  @doc "The kinds whose items record a producer."
  def kinds, do: @kinds

  @doc """
  The entry of `history` (`%{relation => [entry]}`, as Facts answers a fact's read) that
  the write which made a fact of `kind` left: the oldest by position among the links such
  a create sets. Nil when there is none.
  """
  def made(kind, history) do
    entries =
      for relation <- Map.get(@made_with, kind, []),
          entry <- List.wrap((history || %{})[relation]),
          is_map(entry),
          do: entry

    Enum.min_by(entries, &position/1, fn -> nil end)
  end

  defp position(%{"position" => p}) when is_integer(p), do: p
  defp position(_), do: :infinity

  @doc """
  Whom an item's producer is, from `entry` (the write that made it, or nil), `people` (the
  keys of persons), `assists` (`%{agent => person}`) and `decider` (a person's key):
  `{person, how}`, `how` being `:flow`, `:on_behalf`, `:by_hand`, `:assisting` or
  `:unknown`.
  """
  def choose(entry, people, assists, decider) do
    by = entry && entry["by"]
    cause = (entry && entry["cause"]) || ""
    person? = &(is_binary(&1) and &1 in people)

    cond do
      by == "flow" and person?.(for_whom(cause)) -> {for_whom(cause), :flow}
      person?.(on_behalf(cause)) -> {on_behalf(cause), :on_behalf}
      person?.(by) -> {by, :by_hand}
      is_binary(by) and person?.(assists[by]) -> {assists[by], :assisting}
      true -> {decider, :unknown}
    end
  end

  defp for_whom(cause) do
    case Regex.run(~r/\AFor ([^\s:]+): /, cause) do
      [_, who] -> who
      _ -> nil
    end
  end

  defp on_behalf(cause) do
    case Regex.run(~r/on behalf of ([^\s:;,)]+)/, cause) do
      [_, who] -> who
      _ -> nil
    end
  end

  @doc "The cause of the link: that it was backfilled, and from what."
  def cause({person, :flow}, entry),
    do: "backfilled (UC-Atlas-23): made by flow, #{inspect(entry["cause"])}: #{person}"

  def cause({person, :on_behalf}, entry),
    do:
      "backfilled (UC-Atlas-23): put in by #{entry["by"]}, #{inspect(entry["cause"])}: #{person}"

  def cause({person, :by_hand}, _entry),
    do: "backfilled (UC-Atlas-23): put in by #{person} by hand: #{person}"

  def cause({person, :assisting}, entry),
    do: "backfilled (UC-Atlas-23): put in by #{entry["by"]}, who assists #{person}: #{person}"

  def cause({person, :unknown}, nil),
    do:
      "backfilled (UC-Atlas-23): its history names nobody who made it: the configured decider, #{person}"

  def cause({person, :unknown}, entry),
    do:
      "backfilled (UC-Atlas-23): its history names nobody who made it (made by #{entry["by"] || "nobody"}): the configured decider, #{person}"

  @doc """
  The steps for `items` (`[%{"kind", "key", "links", "history"}]`): `{:link, kind, key,
  person, cause}` for each without a producer, in key order.
  """
  def steps(items, people, assists, decider) do
    for item <- Enum.sort_by(items, &{&1["kind"], &1["key"]}),
        missing?(item) do
      entry = made(item["kind"], item["history"])
      choice = choose(entry, people, assists, decider)
      {:link, item["kind"], item["key"], elem(choice, 0), cause(choice, entry)}
    end
  end

  @doc "Whether an item records no producer."
  def missing?(item),
    do: Enum.all?(List.wrap(get_in(item, ["links", @relation])), &(&1 in [nil, ""]))

  @doc "One step as a line of text."
  def line({:link, _kind, key, person, cause}),
    do: "link #{key}  #{@relation} #{person}  (#{cause})"

  @doc """
  Read the items through `client` (connected as the migration) and link each one's
  producer. `opts`: `assists` (`%{agent => person}`), `decider` (a person's key),
  `dry_run`, `say` (prints a line), and `read` and `write` (for tests: `read.(kind, key)`
  answers Facts' read, `nil` key a list; `write.(key, %{relation => person}, cause)`).
  """
  def run(client, opts) do
    say = Keyword.get(opts, :say, &IO.puts/1)
    read = Keyword.get(opts, :read, &read(client, &1, &2))
    write = Keyword.get(opts, :write, &AtlasAgent.set(client, &1, &2, &3))
    decider = opts[:decider]

    with :ok <- if(is_binary(decider) and decider != "", do: :ok, else: {:error, "no decider"}),
         {:ok, people} <- keys(read, "person"),
         :ok <-
           if(decider in people,
             do: :ok,
             else: {:error, "the configured decider #{decider} is no person"}
           ),
         {:ok, items} <- items(read) do
      steps = steps(items, people, opts[:assists] || %{}, decider)
      say.("UC-Atlas-23 one-off: #{length(steps)} steps")
      Enum.each(steps, &say.(line(&1)))

      if Keyword.get(opts, :dry_run, false) do
        say.("Dry run: nothing was written.")
        {:ok, %{steps: steps, written: 0}}
      else
        apply_steps(steps, write, say)
      end
    end
  end

  defp read(client, kind, key) do
    case AtlasAgent.Client.facts(client, kind, key, history: key != nil) do
      {:ok, data} -> {:ok, data}
      {:error, _} = error -> error
      other -> {:error, inspect(other)}
    end
  end

  defp keys(read, kind) do
    with {:ok, %{"facts" => facts}} <- read.(kind, nil),
         do: {:ok, for(%{"key" => key} <- facts, do: key)},
         else: (other -> answer(kind, other))
  end

  # Every item, and for those without a producer the history Facts keeps of its links.
  defp items(read) do
    Enum.reduce_while(@kinds, {:ok, []}, fn kind, {:ok, acc} ->
      case read.(kind, nil) do
        {:ok, %{"facts" => facts}} ->
          case histories(read, kind, Enum.filter(facts, &missing?/1)) do
            {:ok, missing} -> {:cont, {:ok, acc ++ missing}}
            error -> {:halt, error}
          end

        other ->
          {:halt, answer(kind, other)}
      end
    end)
  end

  defp histories(read, kind, facts) do
    Enum.reduce_while(facts, {:ok, []}, fn fact, {:ok, acc} ->
      case read.(kind, fact["key"]) do
        {:ok, %{"fact" => %{} = full} = data} ->
          item = %{
            "kind" => kind,
            "key" => full["key"],
            "links" => full["links"] || %{},
            "history" => data["history"] || %{}
          }

          {:cont, {:ok, acc ++ [item]}}

        other ->
          {:halt, answer("#{kind} #{fact["key"]}", other)}
      end
    end)
  end

  defp answer(what, {:error, text}) when is_binary(text),
    do: {:error, "Facts did not answer #{what}: #{text}"}

  defp answer(what, other),
    do: {:error, "Facts answered #{what} with #{inspect(other) |> String.slice(0, 200)}"}

  defp apply_steps(steps, write, say) do
    Enum.reduce_while(steps, {:ok, 0}, fn {:link, _kind, key, person, cause} = step, {:ok, n} ->
      case write.(key, %{@relation => person}, cause) do
        {:ok, _} ->
          say.("done     " <> line(step))
          {:cont, {:ok, n + 1}}

        {:refused, reasons} ->
          {:halt, {:error, "#{line(step)}: refused: #{Enum.join(reasons, "; ")}"}}

        {:error, text} ->
          {:halt, {:error, "#{line(step)}: #{text}"}}
      end
    end)
    |> case do
      {:ok, n} ->
        say.("Done: #{n} of #{length(steps)} steps written.")
        {:ok, %{steps: steps, written: n}}

      error ->
        error
    end
  end
end
