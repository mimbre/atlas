defmodule AtlasChangeset.ValidateTest do
  use ExUnit.Case, async: true

  @base "sha256:" <> String.duplicate("ab", 32)
  @sha String.duplicate("0f", 32)

  defp file(path, extra \\ %{}),
    do:
      Map.merge(
        %{path: path, op: "write", kind: "file", mode: "100644", size: 1, sha256: @sha},
        extra
      )

  defp link(path, extra \\ %{}),
    do:
      Map.merge(
        %{
          path: path,
          op: "write",
          kind: "symlink",
          mode: "120000",
          size: 1,
          sha256: @sha,
          target: "t"
        },
        extra
      )

  defp delete(path), do: %{path: path, op: "delete"}
  defp set(entries, root \\ "atlas"), do: %{base: @base, roots: [%{root: root, entries: entries}]}

  defp refused(change_set, pattern) do
    assert {:error, messages} = AtlasChangeset.validate(change_set)

    assert Enum.any?(messages, &(&1 =~ pattern)),
           "no message matches #{inspect(pattern)}: #{inspect(messages)}"
  end

  test "a valid change set with every kind of entry, atom or string keys, and an empty root" do
    entries = [file("a.txt"), file("bin/x", %{mode: "100755"}), link("l"), delete("old")]
    assert AtlasChangeset.validate(set(entries)) == :ok

    stringly = %{
      "base" => @base,
      "roots" => [
        %{"root" => "atlas", "entries" => [%{"path" => "a", "op" => "delete"}]},
        %{"root" => "docs", "entries" => []}
      ]
    }

    assert AtlasChangeset.validate(stringly) == :ok
    assert AtlasChangeset.validate(%{base: @base, roots: []}) == :ok
  end

  describe "refuses a path that" do
    test "is empty", do: refused(set([delete("")]), "path is empty")
    test "starts with /", do: refused(set([delete("/etc/passwd")]), "starts with /")
    test "has a . segment", do: refused(set([delete("a/./b")]), ". or .. segment")
    test "is .", do: refused(set([delete(".")]), ". or .. segment")
    test "has a .. segment", do: refused(set([delete("a/../../b")]), ". or .. segment")
    test "is ..", do: refused(set([delete("..")]), ". or .. segment")
    test "contains a NUL", do: refused(set([delete("a\0b")]), "contains a NUL")
    test "has an empty segment", do: refused(set([delete("a//b")]), "empty segment")
    test "ends with /", do: refused(set([delete("a/")]), "empty segment")
    test "is not UTF-8", do: refused(set([delete(<<0xFF>>)]), "not UTF-8")
    test "is not a string", do: refused(set([delete(:a)]), "path is not a string")
    test "is missing", do: refused(set([%{op: "delete"}]), "path is missing")
  end

  test "refuses a duplicate path in a root, but not the same path in two roots" do
    refused(set([file("a"), delete("a")]), "duplicate path \"a\"")

    two = %{
      base: @base,
      roots: [%{root: "x", entries: [delete("a")]}, %{root: "y", entries: [delete("a")]}]
    }

    assert AtlasChangeset.validate(two) == :ok
  end

  test "refuses a duplicate root" do
    refused(
      %{base: @base, roots: [%{root: "x", entries: []}, %{root: "x", entries: []}]},
      "duplicate root \"x\""
    )
  end

  test "refuses a delete that carries extra keys" do
    refused(
      set([%{path: "a", op: "delete", size: 0}]),
      "a delete carries only path and op, not size"
    )

    refused(set([Map.put(delete("a"), :sha256, @sha)]), "not sha256")
  end

  test "refuses a symlink without target, and a file with one" do
    refused(set([Map.delete(link("l"), :target)]), "a symlink needs a target")
    refused(set([link("l", %{target: ""})]), "target is empty")
    refused(set([file("f", %{target: "t"})]), "only a symlink carries a target")
  end

  test "refuses a mode that does not fit the kind (120000 exactly for a symlink)" do
    refused(set([file("f", %{mode: "120000"})]), "mode 120000 does not fit kind file")
    refused(set([link("l", %{mode: "100644"})]), "mode 100644 does not fit kind symlink")
    refused(set([link("l", %{mode: "100755"})]), "mode 100755 does not fit kind symlink")
    refused(set([file("f", %{mode: "100600"})]), "is not 100644, 100755 or 120000")
  end

  test "refuses other malformed entries" do
    refused(set([%{path: "a"}]), "op is missing")
    refused(set([%{path: "a", op: "rename"}]), "op \"rename\"")
    refused(set([file("a", %{kind: "dir"})]), "kind \"dir\"")
    refused(set([Map.delete(file("a"), :size)]), "size is missing")
    refused(set([file("a", %{size: -1})]), "not a non-negative integer")
    refused(set([file("a", %{size: "1"})]), "not a non-negative integer")
    refused(set([file("a", %{sha256: String.upcase(@sha)})]), "sha256 is not 64 lowercase hex")
    refused(set([file("a", %{sha256: "abc"})]), "sha256 is not 64 lowercase hex")
    refused(set([file("a", %{extra: 1})]), "unknown keys extra")
    refused(set([Map.put(file("a"), "path", "b")]), "key path is given twice")
    refused(set([%{1 => "x"}]), "is not an atom or a string")
    refused(set(["a"]), "is not a map")
  end

  test "refuses a malformed change set or root" do
    refused(%{roots: []}, "base is missing")
    refused(%{base: "", roots: []}, "base is empty")
    refused(%{base: @base}, "roots is missing")
    refused(%{base: @base, roots: %{}}, "roots is not a list")
    refused(%{base: @base, roots: [], extra: 1}, "unknown keys extra")
    refused(set([], "a/b"), "is not one folder name")
    refused(set([], ".."), "is not one folder name")
    refused(set([], ""), "root is empty")
    refused(%{base: @base, roots: [%{root: "x"}]}, "entries is missing")
    refused(%{base: @base, roots: [%{root: "x", entries: nil, more: 1}]}, "unknown keys more")
    refused("not a map", "change set is not a map")
  end

  test "reports every problem, not only the first" do
    assert {:error, messages} =
             AtlasChangeset.validate(set([delete("/a"), delete("b/.."), file("c", %{size: -1})]))

    assert length(messages) == 3
  end
end
