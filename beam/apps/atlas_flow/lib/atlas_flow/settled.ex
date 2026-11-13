defmodule AtlasFlow.Settled do
  @moduledoc """
  Flow's settled position (docs/design/page-freshness.md §2.1): every hint at or before it
  has been looked at, and the writes Flow made for those looks are stored. Pure; the
  engine (`AtlasFlow.Engine`) feeds it and answers who waits for it.

  - A hint at `p` that pokes processes gives each a ticket `p` (`hint/3`); one that pokes
    none is settled at once.
  - A process that looked, with every write it made acknowledged, reports the highest
    ticket it had and the highest position it wrote (`looked/4`); a process that is gone
    holds no ticket any more (`down/2`).
  - `value/1`: while tickets are held, the lowest one less one; otherwise the highest
    position seen, writes included. So the order in which hints and reports arrive does
    not matter.
  - `wait/3`: a waiter for position `p` is answered as soon as the value reaches `p`, at
    once when it has. Every change returns the waiters it answers, `{waiter, value}`.
  - At most `most` waiters wait (256), so a Flow that never settles holds no more: one
    more answers the oldest at once, with the value as it is, below its position. That
    still says how far Flow has settled; the asker waits on for as long as it chose to,
    and may ask again.
  """

  @most 256

  defstruct seen: 0, tickets: %{}, waiters: [], most: @most

  @type t :: %__MODULE__{
          seen: non_neg_integer,
          tickets: %{optional(term) => [pos_integer]},
          waiters: [{non_neg_integer, term}],
          most: pos_integer
        }

  @doc "Nothing seen yet; at most `most:` waiters (256)."
  def new(opts \\ []), do: %__MODULE__{most: Keyword.get(opts, :most, @most)}

  @doc "The settled position."
  def value(%__MODULE__{tickets: tickets, seen: seen}) when tickets == %{}, do: seen

  def value(%__MODULE__{tickets: tickets}),
    do: tickets |> Map.values() |> List.flatten() |> Enum.min() |> Kernel.-(1)

  @doc "Whether `holder` holds a ticket."
  def holds?(%__MODULE__{tickets: tickets}, holder), do: Map.has_key?(tickets, holder)

  @doc "A hint at `position` poked `holders` (none: settled at once)."
  def hint(settled, position, holders) do
    tickets =
      Enum.reduce(holders, settled.tickets, fn holder, tickets ->
        Map.update(tickets, holder, [position], &Enum.uniq([position | &1]))
      end)

    due(%{settled | seen: max(settled.seen, position), tickets: tickets})
  end

  @doc "A position seen with nobody to poke (a hint of Flow's own write, say)."
  def seen(settled, position), do: hint(settled, position, [])

  @doc """
  `holder` looked at what its tickets up to `ticket` were for and wrote up to `wrote`
  (nil: nothing).
  """
  def looked(settled, holder, ticket, wrote) do
    tickets =
      case Enum.reject(Map.get(settled.tickets, holder, []), &(&1 <= (ticket || 0))) do
        [] -> Map.delete(settled.tickets, holder)
        left -> Map.put(settled.tickets, holder, left)
      end

    due(%{settled | seen: max(settled.seen, wrote || 0), tickets: tickets})
  end

  @doc "`holder` is gone: what it held is no longer waited for."
  def down(settled, holder), do: due(%{settled | tickets: Map.delete(settled.tickets, holder)})

  @doc """
  `waiter` waits for `position`: answered at once when it is settled, else later. Beyond
  `most` waiting, the oldest are answered now, with the value as it is.
  """
  def wait(settled, position, waiter) do
    {answered, settled} = due(%{settled | waiters: settled.waiters ++ [{position, waiter}]})

    {oldest, waiters} =
      Enum.split(settled.waiters, max(length(settled.waiters) - settled.most, 0))

    value = value(settled)
    {answered ++ for({_, w} <- oldest, do: {w, value}), %{settled | waiters: waiters}}
  end

  defp due(settled) do
    value = value(settled)
    {now, later} = Enum.split_with(settled.waiters, fn {position, _} -> position <= value end)
    {for({_, waiter} <- now, do: {waiter, value}), %{settled | waiters: later}}
  end
end
