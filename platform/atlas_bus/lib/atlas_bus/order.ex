defmodule AtlasBus.Order do
  @moduledoc """
  Work taken one at a time, in order (a selection's `order`, `%{"within", "by", "done"}`):
  the numbered facts under one parent, through the relation `within`, are picked up by
  the number field `by` of theirs, lowest first; equal numbers go by key, its number last
  (`X-9` before `X-10`). Only the first numbered one that is not finished may be picked
  up; the other numbered ones wait for it. A fact without a number never waits and is
  never waited for, nor is one under no parent.

  A fact is finished once it is completed (the model's completion) or its latest run of
  the subflow completed in one of the `done` states (any final state when `done` is
  empty), as a count of the composition says: a fact without a run is not finished.

  Flow refuses a pickup of a waiting fact; Facts presents what it waits for; Control
  offers no Pick up for it.
  """

  @doc """
  The key of the fact `key` waits for, or nil. `siblings` are the facts under its parent
  (itself among them), each `%{"key", "order", "finished"}`.
  """
  def waiting_for(key, siblings) do
    numbered = Enum.filter(siblings, &is_integer(&1["order"]))
    first = numbered |> Enum.sort_by(&rank/1) |> Enum.find(&(not &1["finished"]))

    case first do
      %{"key" => ^key} -> nil
      %{"key" => other} -> if Enum.any?(numbered, &(&1["key"] == key)), do: other
      nil -> nil
    end
  end

  @doc """
  Whether a fact is finished for `order` in `flow`: `completed` (the model's completion of
  the fact), or its latest `run` (`flow`, `status`, `state`; or nil) completed in a `done`
  state.
  """
  def finished?(order, flow, run, completed) do
    done = order["done"] || []

    completed or
      (run != nil and run["flow"] == flow and run["status"] == "completed" and
         (done == [] or run["state"] in done))
  end

  defp rank(%{"key" => key, "order" => order}) do
    case Regex.run(~r/^(.*?)(\d+)$/, key) do
      [_, prefix, number] -> {order, prefix, String.to_integer(number), key}
      nil -> {order, key, -1, key}
    end
  end
end
