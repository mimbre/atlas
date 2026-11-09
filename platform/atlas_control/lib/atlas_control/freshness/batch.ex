defmodule AtlasControl.Freshness.Batch do
  @moduledoc """
  The hints a session collects until it handles them at once (docs/design/page-freshness.md
  §4): it flushes once no hint came for `quiet` ms (20), and at the latest `most` ms (100)
  after the first. Pure: the time is passed in, in milliseconds. A hint is `%{position,
  changes}`.
  """

  defstruct hints: [], first: nil, last: nil

  @quiet 20
  @most 100

  def new, do: %__MODULE__{}

  def add(%__MODULE__{} = batch, hint, now),
    do: %{batch | hints: [hint | batch.hints], first: batch.first || now, last: now}

  def empty?(%__MODULE__{hints: hints}), do: hints == []

  @doc "When to flush, in the same time as `add/3` was given; nil when empty."
  def due(batch, timing \\ [])
  def due(%__MODULE__{first: nil}, _timing), do: nil

  def due(%__MODULE__{first: first, last: last}, timing),
    do: min(last + Keyword.get(timing, :quiet, @quiet), first + Keyword.get(timing, :most, @most))

  @doc "The hints, oldest first, and an empty batch."
  def take(%__MODULE__{hints: hints}), do: {Enum.reverse(hints), new()}

  @doc "The changes of `hints` by position, as `AtlasControl.Freshness.Affected` takes them."
  def changes(hints), do: for(h <- hints, do: {h.position, h.changes})

  @doc "The highest position among the hints, or nil."
  def position(hints) do
    case for(%{position: p} <- hints, is_integer(p), do: p) do
      [] -> nil
      positions -> Enum.max(positions)
    end
  end
end
