defmodule AtlasChangeset.CanonicalTest do
  use ExUnit.Case, async: true

  @fixture "priv/fixtures/canonical.json"

  defp cases do
    Application.app_dir(:atlas_changeset, @fixture)
    |> File.read!()
    |> JSON.decode!()
    |> Map.fetch!("cases")
  end

  defp kinds, do: Enum.find(cases(), &(&1["name"] == "kinds"))

  test "the fixture has the cases the canonical form is pinned by" do
    assert Enum.map(cases(), & &1["name"]) == ~w(empty-root kinds unsorted escaping large-size)
  end

  for name <- ~w(empty-root kinds unsorted escaping large-size) do
    test "fixture case #{name}: exact canonical bytes and fingerprint" do
      c = Enum.find(cases(), &(&1["name"] == unquote(name)))
      assert AtlasChangeset.canonical(c["base"], c["root"], c["entries"]) == c["canonical"]
      assert AtlasChangeset.fingerprint(c["base"], c["root"], c["entries"]) == c["fingerprint"]
    end
  end

  test "a fingerprint is csf_ and 64 lowercase hex digits" do
    for c <- cases(), do: assert(c["fingerprint"] =~ ~r/\Acsf_[0-9a-f]{64}\z/)
  end

  test "the input order of entries does not change the canonical form or the fingerprint" do
    for c <- cases(),
        order <- [Enum.reverse(c["entries"]), Enum.sort_by(c["entries"], &(&1["sha256"] || "~"))] do
      assert AtlasChangeset.canonical(c["base"], c["root"], order) == c["canonical"]
      assert AtlasChangeset.fingerprint(c["base"], c["root"], order) == c["fingerprint"]
    end
  end

  test "atom keys, nil (absent) values and structs give the same canonical form" do
    c = kinds()

    atoms =
      for entry <- c["entries"] do
        entry = Map.new(entry, fn {k, v} -> {String.to_atom(k), v} end)
        Map.merge(%{kind: nil, mode: nil, size: nil, sha256: nil, target: nil}, entry)
      end

    structs = for entry <- atoms, do: struct(AtlasChangeset.TestEntry, entry)

    assert AtlasChangeset.canonical(c["base"], c["root"], atoms) == c["canonical"]
    assert AtlasChangeset.canonical(c["base"], c["root"], structs) == c["canonical"]
  end

  # Each change keeps the entry valid: op and kind change the fields that go with them.
  test "changing any one field changes the fingerprint" do
    c = kinds()
    fp = fn base, root, entries -> AtlasChangeset.fingerprint(base, root, entries) end
    original = fp.(c["base"], c["root"], c["entries"])

    at = fn path, fun ->
      Enum.map(c["entries"], fn e -> if e["path"] == path, do: fun.(e), else: e end)
    end

    variants = [
      path: at.("docs/guide.md", &Map.put(&1, "path", "docs/guide.txt")),
      op: at.("docs/guide.md", &Map.take(Map.put(&1, "op", "delete"), ~w(op path))),
      kind:
        at.(
          "docs/guide.md",
          &Map.merge(&1, %{"kind" => "symlink", "mode" => "120000", "target" => "x"})
        ),
      mode: at.("docs/guide.md", &Map.put(&1, "mode", "100755")),
      size: at.("docs/guide.md", &Map.put(&1, "size", 7)),
      sha256: at.("docs/guide.md", &Map.update!(&1, "sha256", fn "5" <> rest -> "6" <> rest end)),
      target: at.("lib/current", &Map.put(&1, "target", "../releases/v3"))
    ]

    prints =
      for {field, entries} <- variants do
        assert {field, fp.(c["base"], c["root"], entries)} != {field, original}
        fp.(c["base"], c["root"], entries)
      end

    other_base = "sha256:" <> String.duplicate("f", 64)
    refute fp.(other_base, c["root"], c["entries"]) == original
    refute fp.(c["base"], "docs", c["entries"]) == original
    assert length(Enum.uniq([original | prints])) == length(prints) + 1
  end

  test "the canonical form writes no whitespace and its object keys in byte order" do
    for keys <- AtlasChangeset.Canonical.key_orders(), do: assert(keys == Enum.sort(keys))
    c = kinds()
    refute AtlasChangeset.canonical(c["base"], c["root"], c["entries"]) =~ ~r/\s/
  end

  test "a file never carries a target in the canonical form" do
    c = kinds()
    refute AtlasChangeset.canonical(c["base"], c["root"], c["entries"]) =~ "null"

    with_nil =
      for e <- c["entries"], do: if(e["kind"] == "file", do: Map.put(e, "target", nil), else: e)

    assert AtlasChangeset.canonical(c["base"], c["root"], with_nil) == c["canonical"]
  end

  test "a string is escaped as the canonical form says" do
    base = "sha256:" <> String.duplicate("0", 64)
    path = "q\"b\\s/é  \x00\x01\n\x1f\x7f"
    # NUL is refused in a path, so it is checked through the root name below instead.
    entries = [%{path: String.replace(path, "\x00", ""), op: "delete"}]

    assert AtlasChangeset.canonical(base, "r", entries) ==
             ~s({"base":"#{base}","entries":[{"op":"delete","path":"q\\"b\\\\s/é  \\u0001\\u000a\\u001f\x7f"}],"root":"r"})
  end

  test "an invalid root has no canonical form or fingerprint" do
    c = kinds()
    bad = [%{path: "/abs", op: "delete"}]

    assert_raise ArgumentError, ~r/starts with \//, fn ->
      AtlasChangeset.canonical(c["base"], c["root"], bad)
    end

    assert_raise ArgumentError, fn ->
      AtlasChangeset.fingerprint(c["base"], "a/b", c["entries"])
    end

    assert_raise ArgumentError, fn -> AtlasChangeset.fingerprint(nil, c["root"], c["entries"]) end
  end

  test "fingerprints/1 gives one fingerprint per root, in the order the roots are given" do
    [empty, kinds, unsorted | _] = cases()

    set = %{
      base: kinds["base"],
      roots: [
        %{root: "src", entries: unsorted["entries"]},
        %{root: "atlas", entries: kinds["entries"]},
        %{"root" => "empty", "entries" => []}
      ]
    }

    assert AtlasChangeset.fingerprints(set) == [
             %{root: "src", fingerprint: unsorted["fingerprint"]},
             %{root: "atlas", fingerprint: kinds["fingerprint"]},
             %{root: "empty", fingerprint: AtlasChangeset.fingerprint(empty["base"], "empty", [])}
           ]

    assert_raise ArgumentError, fn -> AtlasChangeset.fingerprints(%{set | base: ""}) end
  end
end
