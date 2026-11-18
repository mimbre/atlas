defmodule AtlasChangeset.VerifyBlobTest do
  use ExUnit.Case, async: false

  defp sha(data), do: Base.encode16(:crypto.hash(:sha256, data), case: :lower)

  defp entry(data),
    do: %{
      path: "f",
      op: "write",
      kind: "file",
      mode: "100644",
      size: byte_size(data),
      sha256: sha(data)
    }

  # Raises when it is enumerated a second time: verify_blob may read the content only once.
  defp once(chunks) do
    key = {__MODULE__, make_ref()}

    Stream.resource(
      fn ->
        if Process.get(key), do: raise("the content was enumerated twice")
        Process.put(key, true)
        chunks
      end,
      fn
        [] -> {:halt, []}
        [chunk | rest] -> {[chunk], rest}
      end,
      fn _ -> :ok end
    )
  end

  test "accepts content of the right size and sha256, in chunks, read once" do
    assert AtlasChangeset.verify_blob(entry("hello\n"), once(["he", "llo", "\n"])) == :ok
    assert AtlasChangeset.verify_blob(entry("hello\n"), once([["h", ["el"]], "lo\n"])) == :ok
    assert AtlasChangeset.verify_blob(entry(""), once([])) == :ok
  end

  test "checks a symlink's content too, with string keys" do
    e = %{"path" => "l", "op" => "write", "kind" => "symlink", "mode" => "120000"}
    e = Map.merge(e, %{"size" => 2, "sha256" => sha("ab"), "target" => "ab"})
    assert AtlasChangeset.verify_blob(e, once(["ab"])) == :ok
  end

  test "catches a size mismatch: shorter or longer" do
    assert AtlasChangeset.verify_blob(entry("hello\n"), once(["hello"])) == {:error, :size}
    assert AtlasChangeset.verify_blob(entry("hello\n"), once(["hello\n", "!"])) == {:error, :size}
  end

  test "stops reading once the content is longer than size" do
    endless = Stream.repeatedly(fn -> "x" end)
    assert AtlasChangeset.verify_blob(entry("hello\n"), endless) == {:error, :size}
  end

  test "catches a sha256 mismatch of the same size" do
    assert AtlasChangeset.verify_blob(entry("hello\n"), once(["hellO\n"])) == {:error, :sha256}
  end

  test "refuses an entry without a blob, or an invalid one" do
    assert_raise ArgumentError, fn ->
      AtlasChangeset.verify_blob(%{path: "f", op: "delete"}, [])
    end

    assert_raise ArgumentError, fn ->
      AtlasChangeset.verify_blob(Map.delete(entry("a"), :size), ["a"])
    end
  end

  @chunk 64 * 1024
  @chunks 1024

  test "streams: 64 MiB of content never adds more than 16 MiB of binary memory" do
    chunk = :binary.copy("a", @chunk)

    expected =
      Enum.reduce(1..@chunks, :crypto.hash_init(:sha256), fn _, h ->
        :crypto.hash_update(h, chunk)
      end)

    e = %{path: "big", op: "write", kind: "file", mode: "100644", size: @chunk * @chunks}
    e = Map.put(e, :sha256, Base.encode16(:crypto.hash_final(expected), case: :lower))

    :erlang.garbage_collect()
    before = :erlang.memory(:binary)
    Process.put(:peak, before)

    content =
      Stream.map(1..@chunks, fn _ ->
        Process.put(:peak, max(Process.get(:peak), :erlang.memory(:binary)))
        chunk
      end)

    assert AtlasChangeset.verify_blob(e, content) == :ok
    Process.put(:peak, max(Process.get(:peak), :erlang.memory(:binary)))
    assert Process.get(:peak) - before < 16 * 1024 * 1024
  end
end
