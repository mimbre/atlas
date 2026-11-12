defmodule AtlasControl.Freshness.RecentTest do
  use ExUnit.Case, async: true

  alias AtlasControl.Freshness.Recent

  defp entry(n), do: %{route: {:item, "widget", "W-#{n}"}, deps: [], as_of: n}

  test "it keeps the last 8 paths viewed, the least recently viewed out" do
    recent = Enum.reduce(1..9, Recent.new(), &Recent.viewed(&2, "/k/widget/W-#{&1}", entry(&1)))
    assert Recent.paths(recent) == for(n <- 9..2//-1, do: "/k/widget/W-#{n}")
    assert Recent.get(recent, "/k/widget/W-1") == nil

    # Viewed again: the most recent, once.
    recent = Recent.viewed(recent, "/k/widget/W-5", entry(50))
    assert hd(Recent.paths(recent)) == "/k/widget/W-5"
    assert length(Recent.paths(recent)) == 8
    assert Recent.get(recent, "/k/widget/W-5").as_of == 50
  end

  test "a page pushed off screen keeps its place; a dropped path is gone" do
    recent =
      Recent.new()
      |> Recent.viewed("/a", entry(1))
      |> Recent.viewed("/b", entry(2))
      |> Recent.sent("/a", entry(3))
      |> Recent.sent("/c", entry(4))

    assert Recent.paths(recent) == ["/b", "/a"]
    assert Recent.get(recent, "/a").as_of == 3
    assert Recent.get(recent, "/c") == nil
    assert Recent.paths(Recent.drop(recent, ["/a"])) == ["/b"]
  end
end
