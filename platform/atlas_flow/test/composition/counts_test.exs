defmodule AtlasFlow.Composition.CountsTest do
  use ExUnit.Case, async: true
  alias AtlasFlow.Composition.Counts

  # The neutral yard's count: a tray's cups and the open ones.
  @count hd(AtlasFlow.Yard.composition()["counts"])

  defp cup(key), do: %{"key" => key, "values" => %{}}
  defp run(status, flow \\ "pour"), do: %{"flow" => flow, "status" => status}

  test "a count needs two distinct fields and a relation" do
    assert Counts.valid?(@count) == :ok
    assert Counts.valid?(Map.put(@count, "open", "cups")) == {:error, :invalid_count}
    assert Counts.valid?(Map.delete(@count, "relation")) == {:error, :invalid_count}
  end

  test "all and open are worked out from the children as they are now" do
    children = [cup("C-1"), cup("C-2"), cup("C-3"), cup("C-4")]

    runs = %{
      "C-1" => run("completed"),
      "C-2" => run("active"),
      "C-3" => run("blocked"),
      # C-4 has no run yet: it has not finished, so it is open.
      "C-5" => run("completed")
    }

    assert Counts.values(@count, children, runs) == %{"cups" => 4, "open_cups" => 3}

    # A run of another subflow on the child does not close it.
    assert Counts.values(@count, [cup("C-1")], %{"C-1" => run("completed", "other")}) ==
             %{"cups" => 1, "open_cups" => 1}
  end

  test "an empty aggregate is zero, and only what the parent does not hold changes" do
    values = Counts.values(@count, [], %{})
    assert values == %{"cups" => 0, "open_cups" => 0}
    assert Counts.changes(values, %{"values" => %{}}) == values

    assert Counts.changes(values, %{"values" => %{"cups" => 0, "open_cups" => 1}}) == %{
             "open_cups" => 0
           }

    assert Counts.changes(values, %{"values" => values}) == %{}
  end
end
