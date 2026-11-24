defmodule AtlasBus.Order do
  @moduledoc """
  Work taken one at a time, in order (a selection's `order`, `%{"within", "by", "done"}`):
  the facts under one parent, through the relation `within`, are picked up by the number
  field `by` of theirs, lowest first; a fact without one comes after those with one; equal
  numbers go by key, its number last (`X-9` before `X-10`). Only the first that is not
  finished may be picked up; the others wait for it. A fact is finished once its latest
  run of the subflow completed in one of the `done` states (any final state when `done`
  is empty), as a count of the composition says: a fact without a run is not finished. A
  fact under no parent waits for nothing.

  Flow refuses a pickup of a waiting fact; Facts presents what it waits for; Control
  offers no Pick up for it.
  """

  @doc """
  The key of the fact `key` waits for, or nil. `siblings` are the facts under its parent
  (itself among them), each `%{"key", "order", "finished"}`.
  """
  def waiting_for(key, siblings) do
    first = siblings |> Enum.sort_by(&rank/1) |> Enum.find(&(not &1["finished"]))

    case first do
      %{"key" => ^key} -> nil
      %{"key" => other} -> if Enum.any?(siblings, &(&1["key"] == key)), do: other
      nil -> nil
    end
  end

  @doc "Whether `run` (`flow`, `status`, `state`; or nil) finished the work of `order` in `flow`."
  def finished?(order, flow, run) do
    done = order["done"] || []

    run != nil and run["flow"] == flow and run["status"] == "completed" and
      (done == [] or run["state"] in done)
  end

  defp rank(%{"key" => key, "order" => order}) do
    {if(is_integer(order), do: 0, else: 1), if(is_integer(order), do: order, else: 0),
     key_rank(key)}
  end

  defp key_rank(key) do
    case Regex.run(~r/^(.*?)(\d+)$/, key) do
      [_, prefix, number] -> {prefix, String.to_integer(number), key}
      nil -> {key, -1, key}
    end
  end
end
