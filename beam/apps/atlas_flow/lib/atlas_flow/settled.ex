defmodule AtlasFlow.Settled do
  @moduledoc """
  Flow's settled position (docs/design/page-freshness.md §2.1): every hint at or before it
  has been looked at, and the writes Flow made for those looks are stored. Pure; the
  engine (`AtlasFlow.Engine`) feeds it and answers who waits for it.

  - The engine looks at a hint at once, with every write it makes for it acknowledged,
    then reports the hint as handled (`handled/3`): settled through the hint's own
    position, and through Flow's own writes for it that follow it without a gap. A write
    of someone else's can fall in between (stored after the hint, before Flow's write);
    its hint is not handled yet, so the settled position stops before it. Flow's own
    later writes are reached when their own hints come (`seen/2`).
  - `value/1`: the highest position settled.
  - A hint whose runs could not be reconciled or whose required projection failed is
    not settled: the engine holds it (`hold/2`), and the value stays below it, however
    far later hints reach, until a round reconciles every run and successfully projects
    every subject (`release/1`). Then it is settled through every hint looked at by then.

  It assumes what one store guarantees: hints reach the engine in position order (Facts
  sends them one after the other), so every hint before one the engine handles was
  handled first. A writer may ask about its write before the engine has its hint: it is
  answered once the hint is handled, never before (`wait/3`).
  - `wait/3`: a waiter for position `p` is answered as soon as the value reaches `p`, at
    once when it has. Every change returns the waiters it answers, `{waiter, value}`.
  - At most `most` waiters wait (256), so a Flow that never settles holds no more: one
    more answers the oldest at once, with the value as it is, below its position. That
    still says how far Flow has settled; the asker waits on for as long as it chose to,
    and may ask again.
  """

  @most 256

  defstruct seen: 0, reached: 0, held: nil, waiters: [], most: @most

  @type t :: %__MODULE__{
          seen: non_neg_integer,
          reached: non_neg_integer,
          held: nil | non_neg_integer,
          waiters: [{non_neg_integer, term}],
          most: pos_integer
        }

  @doc "Nothing seen yet; at most `most:` waiters (256)."
  def new(opts \\ []), do: %__MODULE__{most: Keyword.get(opts, :most, @most)}

  @doc "The settled position."
  def value(%__MODULE__{seen: seen}), do: seen

  @doc "Every hint and write up to `position` was looked at and is stored."
  def seen(settled, position) do
    reached = max(settled.reached, position)
    capped = if settled.held, do: min(reached, settled.held - 1), else: reached
    due(%{settled | reached: reached, seen: max(settled.seen, capped)})
  end

  @doc """
  The hint at `position` was looked at, but reconciliation or required projection
  failed: settled no further than `position - 1` until `release/1`.
  """
  def hold(settled, position) do
    held = if settled.held, do: min(settled.held, position), else: position
    seen(%{settled | held: held}, position)
  end

  @doc "Every run reconciled and required projection succeeded: release every held hint."
  def release(settled), do: seen(%{settled | held: nil}, settled.reached)

  @doc """
  The hint at `position` was handled, and Flow's own writes for it are stored at `own`:
  settled through `position` and the positions of `own` that follow it without a gap.
  """
  def handled(settled, position, own) do
    own = MapSet.new(own)

    through =
      Enum.reduce_while(Stream.iterate(position + 1, &(&1 + 1)), position, fn p, at ->
        if MapSet.member?(own, p), do: {:cont, p}, else: {:halt, at}
      end)

    seen(settled, through)
  end

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
