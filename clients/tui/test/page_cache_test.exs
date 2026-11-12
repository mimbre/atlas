defmodule AtlasTui.PageCacheTest do
  use ExUnit.Case, async: true

  alias AtlasTui.PageCache

  defp page(path, position, title \\ "T"),
    do: %{"op" => "page", "path" => path, "position" => position, "title" => title}

  test "a page is kept for its path unless the cached one is newer" do
    cache = PageCache.new() |> PageCache.put(page("/a", 5, "five"))

    assert PageCache.get(PageCache.put(cache, page("/a", 4, "four")), "/a")["title"] == "five"
    assert PageCache.get(PageCache.put(cache, page("/a", 5, "again")), "/a")["title"] == "again"
    assert PageCache.get(PageCache.put(cache, page("/a", 6, "six")), "/a")["title"] == "six"
    assert PageCache.get(cache, "/b") == nil
  end

  test "a page without a position always replaces and is always replaced" do
    cache = PageCache.new() |> PageCache.put(page("/a", 5, "five"))
    cache = PageCache.put(cache, page("/a", nil, "none"))
    assert PageCache.get(cache, "/a")["title"] == "none"
    assert PageCache.get(PageCache.put(cache, page("/a", 1, "one")), "/a")["title"] == "one"
  end

  test "it holds 16 paths, the least recently stored out" do
    cache = Enum.reduce(1..17, PageCache.new(), &PageCache.put(&2, page("/p/#{&1}", &1)))
    assert length(PageCache.paths(cache)) == 16
    assert PageCache.get(cache, "/p/1") == nil
    assert hd(PageCache.paths(cache)) == "/p/17"

    cache = PageCache.put(cache, page("/p/2", 30))
    assert hd(PageCache.paths(cache)) == "/p/2"
    cache = PageCache.put(cache, page("/p/18", 31))
    assert PageCache.get(cache, "/p/2") != nil
    assert PageCache.get(cache, "/p/3") == nil
  end

  test "a message without a path is not kept" do
    assert PageCache.put(PageCache.new(), %{"op" => "page"}) == PageCache.new()
  end
end
