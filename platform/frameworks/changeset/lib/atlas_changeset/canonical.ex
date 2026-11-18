defmodule AtlasChangeset.Canonical do
  @moduledoc false
  # The canonical JSON of one root, from entries that `AtlasChangeset.Validate` accepted
  # (string keys, no absent values). It is written here, byte by byte, and never by a general
  # JSON encoder, so its escaping cannot change with one:
  #
  #   - UTF-8, compact, no whitespace; object keys in byte order; integers in decimal;
  #   - the object is {base, entries, root}; entries are sorted by path in byte order;
  #   - a delete is {op, path}; a write is {kind, mode, op, path, sha256, size}, plus target
  #     for a symlink;
  #   - in a string, `"` is `\"`, `\` is `\\`, U+0000..U+001F is `\u00xx` (lowercase hex),
  #     and every other code point is its literal UTF-8 (including `/`, U+2028 and U+2029).

  @doc false
  def encode(base, root, entries) do
    sorted = Enum.sort_by(entries, & &1["path"])

    IO.iodata_to_binary([
      ~s({"base":),
      string(base),
      ~s(,"entries":[),
      Enum.map_intersperse(sorted, ?,, &entry/1),
      ~s(],"root":),
      string(root),
      ?}
    ])
  end

  @doc false
  # The keys of each object, in the order they are written: byte order (tested).
  def key_orders do
    [
      ~w(base entries root),
      ~w(op path),
      ~w(kind mode op path sha256 size),
      ~w(kind mode op path sha256 size target)
    ]
  end

  defp entry(%{"op" => "delete"} = e) do
    [~s({"op":"delete","path":), string(e["path"]), ?}]
  end

  defp entry(%{"op" => "write"} = e) do
    [
      ~s({"kind":),
      string(e["kind"]),
      ~s(,"mode":),
      string(e["mode"]),
      ~s(,"op":"write","path":),
      string(e["path"]),
      ~s(,"sha256":),
      string(e["sha256"]),
      ~s(,"size":),
      Integer.to_string(e["size"]),
      target(e),
      ?}
    ]
  end

  defp target(%{"kind" => "symlink", "target" => target}), do: [~s(,"target":), string(target)]
  defp target(_entry), do: []

  defp string(value), do: [?", escape(value), ?"]

  defp escape(value) do
    for <<byte <- value>>, into: "" do
      case byte do
        ?" -> ~S(\")
        ?\\ -> ~S(\\)
        byte when byte < 0x20 -> "\\u00" <> Base.encode16(<<byte>>, case: :lower)
        byte -> <<byte>>
      end
    end
  end
end
