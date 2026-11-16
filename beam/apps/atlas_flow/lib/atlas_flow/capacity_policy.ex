defmodule AtlasFlow.Capacity.Policy do
  @moduledoc "Pure FIFO selection and recoverable releases over existing slots."

  def pick(queue, slots, live, _now) do
    {picked, _used} =
      queue
      |> Enum.sort_by(&{timestamp(&1.since), &1.key})
      |> Enum.reduce({[], MapSet.new()}, fn item, {picked, used} ->
        candidates =
          for slot <- slots,
              not (item[:history_missing] == true),
              slot.machine in live,
              not slot.busy,
              not MapSet.member?(used, slot.key),
              slot.cannot_run in [nil, ""],
              {backend, models} <- Enum.sort(slot.models),
              backend in item.need["backend"],
              backend != item[:excluded_backend],
              model <- Enum.sort(models),
              item.need["model"] == "any" or model in item.need["model"],
              do: {slot, backend, model}

        case Enum.sort_by(candidates, fn {slot, backend, model} ->
               {slot.key != item[:affinity], slot[:warm] != true, timestamp(slot[:idle_since]),
                slot.key, backend, model}
             end) do
          [{slot, backend, model} | _] ->
            {[{item, slot, backend, model} | picked], MapSet.put(used, slot.key)}

          [] ->
            {picked, used}
        end
      end)

    Enum.reverse(picked)
  end

  def timestamp(value) when value in [nil, ""], do: -9_223_372_036_854_775_808

  def timestamp(value) do
    {:ok, time, _offset} = DateTime.from_iso8601(value)
    DateTime.to_unix(time, :microsecond)
  end

  # Time and connectivity can demand reconciliation, but never establish that
  # the old execution stopped. Only a matching, confirmed end releases a pick.
  def release(picks, turns, _live, _now) do
    Enum.filter(picks, fn pick ->
      matching = Enum.filter(turns, &(&1.pick == pick.pick))
      ended = Enum.any?(matching, &(&1.state == :ended and &1[:quiescent] == true))
      pick.pick not in [nil, ""] and ended
    end)
  end
end
