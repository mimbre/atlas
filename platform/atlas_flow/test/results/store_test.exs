defmodule AtlasFlow.Results.StoreTest do
  use ExUnit.Case, async: true

  alias AtlasFlow.Results.Store

  setup do
    dir = Path.join(System.tmp_dir!(), "results-store-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  # One-byte chunks that tell the test each time one is read.
  defp reporting(bytes) do
    test = self()

    bytes
    |> :binary.bin_to_list()
    |> Stream.map(fn byte ->
      send(test, :chunk_read)
      <<byte>>
    end)
  end

  defp reads, do: reads(0)

  defp reads(n) do
    receive do
      :chunk_read -> reads(n + 1)
    after
      0 -> n
    end
  end

  defp ok(_bytes), do: :ok

  defp write(dir, bytes, opts \\ []) do
    sha = Keyword.get(opts, :sha, Store.sha256(bytes))
    size = Keyword.get(opts, :size, byte_size(bytes))
    room = Keyword.get(opts, :room, 1_000)
    take = Keyword.get(opts, :take, &ok/1)
    content = Keyword.get(opts, :content, reporting(bytes))

    {Store.write(
       Store.tmp_path(dir, "t"),
       Store.blob_path(dir, sha),
       sha,
       size,
       content,
       room,
       take
     ), sha}
  end

  defp visible(dir), do: Store.scan(dir).blobs
  defp leftovers(dir), do: Path.wildcard(Path.join(Store.tmp_dir(dir), "*"))

  test "a whole, right blob is renamed into its content address", %{dir: dir} do
    assert {:stored, sha} = write(dir, "hello")
    assert visible(dir) == %{sha => 5}
    assert File.read!(Store.blob_path(dir, sha)) == "hello"
    assert leftovers(dir) == []
  end

  test "exactly the room is stored; room + 1 stops at that byte and leaves nothing", %{dir: dir} do
    assert {:stored, _} = write(dir, "12345", room: 5)
    assert reads() == 5

    assert {:too_large, _} = write(dir, "abcdefghij", size: 5, room: 5)
    assert reads() == 6
    assert map_size(visible(dir)) == 1
    assert leftovers(dir) == []
  end

  test "the live store-cap count stops the stream at the chunk it refuses", %{dir: dir} do
    budget = :counters.new(1, [])

    take = fn bytes ->
      :counters.add(budget, 1, bytes)
      if :counters.get(budget, 1) > 3, do: :full, else: :ok
    end

    assert {:too_large, _} = write(dir, "abcdefgh", room: 100, take: take)
    assert reads() == 4
    assert visible(dir) == %{}
    assert leftovers(dir) == []
  end

  test "a digest or size mismatch stores nothing", %{dir: dir} do
    other = Store.sha256("other")
    assert {{:rejected, :digest_mismatch}, ^other} = write(dir, "hello", sha: other)
    assert {{:rejected, :digest_mismatch}, _} = write(dir, "hello", size: 6)
    assert {{:rejected, :digest_mismatch}, _} = write(dir, "hello", size: 4)
    assert visible(dir) == %{}
    assert leftovers(dir) == []
  end

  test "only lowercase sha256 hex is a name" do
    assert Store.sha?(Store.sha256("x"))
    refute Store.sha?(String.upcase(Store.sha256("x")))
    refute Store.sha?("../" <> binary_part(Store.sha256("x"), 0, 61))
    refute Store.sha?(nil)
  end

  test "a scan sees blobs and manifests apart and nothing in tmp", %{dir: dir} do
    {:stored, sha} = write(dir, "blob")
    manifest = Store.sha256("{}")
    Store.put_bytes(Store.tmp_path(dir, "m"), Store.manifest_path(dir, manifest), "{}")
    File.write!(Store.tmp_path(dir, "partial"), "half")
    File.write!(Path.join(dir, "stray"), "x")

    assert Store.scan(dir) == %{blobs: %{sha => 4}, manifests: %{manifest => 2}}

    Store.clean_tmp(dir)
    assert leftovers(dir) == []
  end
end
