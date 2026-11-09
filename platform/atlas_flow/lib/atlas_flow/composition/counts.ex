defmodule AtlasFlow.Composition.Counts do
  @moduledoc """
  A count of the model's composition (`AtlasFlow.Model.composition/0`, version 1): the
  parent's `all` (how many children relate to it by `relation`) and `open` (how many of
  them have no run of the child subflow that completed). Pure, and always worked out
  again from the children as they are now, so a deleted, moved or added child, or a hint
  that was lost, is counted right on the next look; nothing is counted up or down.

  A child without a run yet is open: it has not finished.
  """

  @doc "Whether a runner can apply `count`: `:ok`, or `{:error, why}`."
  def valid?(%{"all" => a, "open" => o, "relation" => r})
      when is_binary(a) and is_binary(o) and is_binary(r) and a != o,
      do: :ok

  def valid?(_count), do: {:error, :invalid_count}

  @doc """
  The values of `count` for `children` (the facts related to the parent) and `runs`
  (each child's latest run of the count's subflow, by child key):
  `%{all => n, open => m}`.
  """
  def values(count, children, runs) do
    open =
      Enum.count(children, fn child ->
        run = runs[child["key"]]
        not (run != nil and run["flow"] == count["child"] and run["status"] == "completed")
      end)

    %{count["all"] => length(children), count["open"] => open}
  end

  @doc "The values of `values` that `parent` (`%{\"values\"}`) does not hold yet."
  def changes(values, parent) do
    held = parent["values"] || %{}
    for {field, value} <- values, held[field] != value, into: %{}, do: {field, value}
  end
end
