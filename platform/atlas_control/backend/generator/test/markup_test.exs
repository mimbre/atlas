defmodule AtlasBFF.MarkupTest do
  use ExUnit.Case, async: true

  alias AtlasBFF.Markup

  @ids ~w(a b c d e)

  defp m(kind, s, e, extra \\ %{}),
    do: Map.merge(%{"kind" => kind, "start" => s, "end" => e, "props" => %{}}, extra)

  describe "check/2" do
    test "nested, side by side and equal stretches are well formed" do
      assert :ok = Markup.check(@ids, [m("part", "a", "e"), m("section", "b", "c")])
      assert :ok = Markup.check(@ids, [m("section", "a", "b"), m("section", "c", "e")])
      assert :ok = Markup.check(@ids, [m("section", "b", "d"), m("part", "b", "d")])
      assert :ok = Markup.check(@ids, [m("section", "b", "d"), m("highlight", "d", "d")])
    end

    test "crossing markup is refused, of every kind" do
      assert {:error, "section a..c and highlight b..d cross; markup must nest"} =
               Markup.check(@ids, [m("section", "a", "c"), m("highlight", "b", "d")])

      assert {:error, _} = Markup.check(@ids, [m("highlight", "c", "e"), m("part", "a", "c")])
    end

    test "a stretch must point at blocks of the content, start first" do
      assert {:error, "section a..x ends at unknown block \"x\""} =
               Markup.check(@ids, [m("section", "a", "x")])

      assert {:error, "section d..b ends before it starts"} =
               Markup.check(@ids, [m("section", "d", "b")])

      assert {:error, "block id \"a\" is used twice"} = Markup.check(["a", "a"], [])
    end
  end

  test "tree/2 renders top down, outer first; equal stretches nest in list order" do
    markup = [m("part", "a", "c"), m("section", "a", "c"), m("section", "e", "e")]

    assert [
             {:markup, %{"kind" => "part"},
              [{:markup, %{"kind" => "section"}, [{:block, "a"}, {:block, "b"}, {:block, "c"}]}]},
             {:block, "d"},
             {:markup, %{"kind" => "section"}, [{:block, "e"}]}
           ] = Markup.tree(@ids, markup)

    assert_raise ArgumentError, ~r/cross/, fn ->
      Markup.tree(@ids, [m("section", "a", "c"), m("section", "b", "d")])
    end
  end

  describe "delete/3" do
    test "a boundary moves to its neighbour inside the stretch" do
      assert {~w(b c d e), [%{"start" => "b", "end" => "c"}]} =
               Markup.delete(@ids, [m("section", "a", "c")], "a")

      assert {~w(a b d e), [%{"start" => "a", "end" => "b"}]} =
               Markup.delete(@ids, [m("section", "a", "c")], "c")
    end

    test "a stretch left empty drops its markup; others stay as they are" do
      assert {~w(a c d e), [%{"kind" => "section"}]} =
               Markup.delete(@ids, [m("highlight", "b", "b"), m("section", "c", "d")], "b")
    end
  end

  describe "move/4" do
    test "a block keeps markup only while it stays inside the stretch" do
      markup = [m("section", "a", "c")]
      assert {~w(a c b d e), ^markup} = Markup.move(@ids, markup, "b", 2)

      assert {~w(a c d b e), [%{"start" => "a", "end" => "c"}]} =
               Markup.move(@ids, markup, "b", 3)
    end

    test "a moved boundary block leaves its markup, which shrinks to its neighbour" do
      assert {~w(b c d e a), [%{"start" => "b", "end" => "c"}]} =
               Markup.move(@ids, [m("section", "a", "c")], "a", 4)
    end

    test "a block moved inside a stretch joins it; its own markup goes with it" do
      markup = [m("section", "a", "c"), m("highlight", "e", "e")]

      assert {~w(a e b c d), ^markup} = Markup.move(@ids, markup, "e", 1)
    end
  end

  describe "place/3" do
    test "markup that nests is added as it is" do
      assert [_, %{"kind" => "highlight"} = h] =
               Markup.place(@ids, [m("section", "a", "c")], m("highlight", "b", "c"))

      refute Map.has_key?(h, "group")
    end

    test "markup that would cross is split into pieces that share a group" do
      markup = [m("section", "a", "b"), m("section", "c", "e")]

      assert [_, _, p1, p2] = placed = Markup.place(@ids, markup, m("highlight", "b", "c"))
      assert {p1["start"], p1["end"], p2["start"], p2["end"]} == {"b", "b", "c", "c"}
      assert p1["group"] == "b..c" and p2["group"] == "b..c"
      assert :ok = Markup.check(@ids, placed)

      assert [_, _, %{"group" => "mine"}, %{"group" => "mine"}] =
               Markup.place(@ids, markup, m("highlight", "b", "c", %{"group" => "mine"}))
    end
  end

  test "random places, deletes and moves keep the markup one well-formed tree" do
    :rand.seed(:exsss, {1, 2, 3})
    kinds = ~w(part section highlight)

    for _run <- 1..200 do
      ids = for n <- 1..Enum.random(1..12), do: "b#{n}"

      markup =
        Enum.reduce(1..Enum.random(0..8)//1, [], fn _, markup ->
          [s, e] =
            Enum.sort([Enum.random(0..(length(ids) - 1)), Enum.random(0..(length(ids) - 1))])

          entry = m(Enum.random(kinds), Enum.at(ids, s), Enum.at(ids, e))
          placed = Markup.place(ids, markup, entry)
          assert :ok = Markup.check(ids, placed)
          placed
        end)

      Enum.reduce_while(1..Enum.random(1..6), {ids, markup}, fn _, {ids, markup} ->
        id = Enum.random(ids)

        {ids, markup} =
          if length(ids) > 1 and :rand.uniform() < 0.5,
            do: Markup.move(ids, markup, id, Enum.random(0..(length(ids) - 1))),
            else: Markup.delete(ids, markup, id)

        assert :ok = Markup.check(ids, markup), inspect({ids, markup})
        assert flatten(Markup.tree(ids, markup)) == ids

        if ids == [], do: {:halt, :empty}, else: {:cont, {ids, markup}}
      end)
    end
  end

  defp flatten(tree),
    do:
      Enum.flat_map(tree, fn
        {:block, id} -> [id]
        {:markup, _, children} -> flatten(children)
      end)
end
