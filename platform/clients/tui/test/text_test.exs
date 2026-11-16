defmodule AtlasTui.TextTest do
  use ExUnit.Case, async: true

  alias AtlasTui.Text

  test "rows break after a space, inside a word only when it is longer than a row" do
    assert Text.rows("aaa bbb ccc", 7) == [{0, 8}, {8, 3}]
    assert Text.rows("abcdefghij", 4) == [{0, 4}, {4, 4}, {8, 2}]
    assert Text.rows("", 5) == [{0, 0}]
  end

  test "wrap keeps line breaks and blank lines, and hangs list items" do
    assert Text.wrap("a\n\nb", 20) == ["a", "", "b"]

    assert Text.wrap("- one two three four five six", 12) ==
             ["- one two", "  three four", "  five six"]
  end

  test "editing: insert, new line, join, and the cursor at the edges" do
    assert Text.key("ab", {0, 1}, {:char, "x"}) == {:ok, "axb", {0, 2}}
    assert Text.key("ab", {0, 1}, :enter) == {:ok, "a\nb", {1, 0}}
    assert Text.key("a\nb", {1, 0}, :backspace) == {:ok, "ab", {0, 1}}
    assert Text.key("a\nlong", {1, 4}, :up) == {:ok, "a\nlong", {0, 1}}
    assert Text.key("a\nb", {0, 0}, :up) == {:leave, :up}
    assert Text.key("a\nb", {1, 1}, :down) == {:leave, :down}
    assert Text.key("a\nb", {0, 1}, :right) == {:ok, "a\nb", {1, 0}}
    assert Text.key("é\nb", nil, :left) == {:ok, "é\nb", {1, 0}}
    assert Text.cursor("ab", {5, 9}) == {0, 2}
  end
end
