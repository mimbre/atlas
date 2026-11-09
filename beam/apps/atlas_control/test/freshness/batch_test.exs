defmodule AtlasControl.Freshness.BatchTest do
  use ExUnit.Case, async: true

  alias AtlasControl.Freshness.Batch

  defp hint(p), do: %{position: p, changes: [%{"key" => "W-#{p}"}]}

  test "it flushes once no hint came for a while, and at the latest a while after the first" do
    assert Batch.due(Batch.new()) == nil
    batch = Batch.add(Batch.new(), hint(1), 1_000)
    assert Batch.due(batch) == 1_020
    batch = Batch.add(batch, hint(2), 1_015)
    assert Batch.due(batch) == 1_035
    batch = Enum.reduce(3..10, batch, &Batch.add(&2, hint(&1), 1_015 + &1 * 10))
    # Hints keep coming: the first one waits no longer than 100 ms.
    assert Batch.due(batch) == 1_100
    assert Batch.due(batch, quiet: 5, most: 50) == 1_050
  end

  test "taken, the hints come oldest first, by position" do
    batch = Batch.new() |> Batch.add(hint(1), 0) |> Batch.add(hint(3), 1)
    {hints, rest} = Batch.take(batch)
    assert Batch.empty?(rest)
    assert Batch.changes(hints) == [{1, [%{"key" => "W-1"}]}, {3, [%{"key" => "W-3"}]}]
    assert Batch.position(hints) == 3
    assert Batch.position([]) == nil
  end
end
