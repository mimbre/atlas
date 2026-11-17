defmodule AtlasRuntime.Sources.StoreTest do
  @moduledoc """
  M2 plan W5 (decision §3 "Inputs (F6)", §5.5): the per-source blob store. A blob is renamed
  into place only after its sha256 matches; a source sees only its own blobs; the quota
  `max_store_bytes` refuses `too_large` before writing past it, and a stream that runs past
  its declared size is aborted while streaming. No refusal leaves anything behind.
  """
  use ExUnit.Case, async: true

  alias AtlasRuntime.Sources.Store

  @quota 1_000_000

  setup do
    home =
      Path.join(System.tmp_dir!(), "atlas-store-#{System.unique_integer([:positive])}")

    File.mkdir_p!(home)
    on_exit(fn -> File.rm_rf!(home) end)
    %{home: home}
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp blob(bytes, chunk \\ 4), do: %{size: byte_size(bytes), content: chunks(bytes, chunk)}

  defp chunks(bytes, size) do
    Stream.unfold(bytes, fn
      "" -> nil
      <<chunk::binary-size(size), rest::binary>> -> {chunk, rest}
      rest -> {rest, ""}
    end)
  end

  # A stream of n chunks of `size` bytes that counts every byte it hands out.
  defp counted(counter, n, size) do
    Stream.repeatedly(fn ->
      :counters.add(counter, 1, size)
      :binary.copy("x", size)
    end)
    |> Stream.take(n)
  end

  # The calls this process makes to File.ls/1 and File.lstat/1 while running fun: a count
  # of folder listings and stats, not of time. Only this process is traced; the patterns
  # are left on (they cost nothing for untraced processes, and switching them off could
  # break another async test that counts at the same time).
  defp calls(fun) do
    # A process cannot be its own tracer: a collector receives the trace messages.
    collector = spawn_link(fn -> collect([]) end)
    :erlang.trace_pattern({File, :ls, 1}, true, [])
    :erlang.trace_pattern({File, :lstat, 1}, true, [])
    :erlang.trace(self(), true, [:call, {:tracer, collector}])

    result =
      try do
        fun.()
      after
        :erlang.trace(self(), false, [:call])
      end

    ref = :erlang.trace_delivered(self())
    receive do: ({:trace_delivered, _, ^ref} -> :ok)
    send(collector, {:calls, self()})
    receive do: ({:calls, ^collector, calls} -> {result, calls})
  end

  defp collect(acc) do
    receive do
      {:trace, _pid, :call, {File, fun, [path]}} -> collect([{fun, path} | acc])
      {:calls, from} -> send(from, {:calls, self(), Enum.reverse(acc)})
    end
  end

  # Every file under the source's folder, temporary ones included.
  defp files(home, name) do
    Path.wildcard(Path.join([home, "sources", name, "**", "*"]), match_dot: true)
    |> Enum.filter(&File.regular?/1)
  end

  test "a matching blob is stored read-only under its sha256 in the source's folder", %{
    home: home
  } do
    bytes = "hello, base"
    sha = sha256(bytes)

    assert {:ok, path} = Store.put(home, "flow-prod", sha, blob(bytes), @quota)
    assert path == Path.join([home, "sources", "flow-prod", "blobs", sha])
    assert File.read!(path) == bytes
    assert %File.Stat{mode: mode} = File.stat!(path)
    assert Bitwise.band(mode, 0o777) == 0o444
    assert {:ok, ^path} = Store.get(home, "flow-prod", sha)
    assert Store.has?(home, "flow-prod", sha)
    assert files(home, "flow-prod") == [path]
  end

  test "a sha256 mismatch stores nothing", %{home: home} do
    sha = sha256("the bytes the entry names")
    # The same size, other content.
    other = "the bytes the entry nameZ"

    assert {:error, :mismatch} = Store.put(home, "flow-prod", sha, blob(other), @quota)
    refute Store.has?(home, "flow-prod", sha)
    assert files(home, "flow-prod") == []
  end

  test "fewer bytes than declared store nothing", %{home: home} do
    bytes = "short"
    sha = sha256(bytes)

    assert {:error, :mismatch} =
             Store.put(home, "flow-prod", sha, %{size: 10, content: chunks(bytes, 2)}, @quota)

    assert files(home, "flow-prod") == []
  end

  test "a source never sees another source's blob", %{home: home} do
    bytes = "only for a"
    sha = sha256(bytes)
    assert {:ok, _} = Store.put(home, "source-a", sha, blob(bytes), @quota)

    assert Store.has?(home, "source-a", sha)
    refute Store.has?(home, "source-b", sha)
    assert :not_found = Store.get(home, "source-b", sha)
    assert {:ok, 0} = Store.scan(home, "source-b")

    # B stores its own copy, read from its own stream.
    counter = :counters.new(1, [])
    content = Stream.map(chunks(bytes, 3), &(:counters.add(counter, 1, 1) && &1))
    assert {:ok, b_path} = Store.put(home, "source-b", sha, %{size: 10, content: content}, @quota)
    assert :counters.get(counter, 1) > 0
    assert {:ok, a_path} = Store.get(home, "source-a", sha)
    assert a_path != b_path
  end

  test "a blob the source already holds is not read again", %{home: home} do
    bytes = "kept"
    sha = sha256(bytes)
    assert {:ok, path} = Store.put(home, "flow-prod", sha, blob(bytes), @quota)

    untouched = Stream.map([bytes], fn _ -> flunk("read again") end)

    assert {:ok, ^path} =
             Store.put(home, "flow-prod", sha, %{size: 4, content: untouched}, @quota)
  end

  describe "max_store_bytes" do
    test "a blob past the quota is too_large, before a byte is read, and nothing partial is left",
         %{home: home} do
      first = :binary.copy("a", 60)
      assert {:ok, _} = Store.put(home, "flow-prod", sha256(first), blob(first), 100)
      before = files(home, "flow-prod")

      counter = :counters.new(1, [])
      second = :binary.copy("b", 50)

      assert {:error, :too_large} =
               Store.put(
                 home,
                 "flow-prod",
                 sha256(second),
                 %{size: 50, content: counted(counter, 5, 10)},
                 100
               )

      assert :counters.get(counter, 1) == 0
      assert files(home, "flow-prod") == before
      assert {:ok, 60} = Store.scan(home, "flow-prod")
    end

    test "the quota is per source", %{home: home} do
      a = :binary.copy("a", 80)
      assert {:ok, _} = Store.put(home, "source-a", sha256(a), blob(a), 100)
      b = :binary.copy("b", 80)
      assert {:ok, _} = Store.put(home, "source-b", sha256(b), blob(b), 100)
    end

    test "a blob exactly at the quota is stored", %{home: home} do
      bytes = :binary.copy("q", 100)
      assert {:ok, _} = Store.put(home, "flow-prod", sha256(bytes), blob(bytes), 100)
    end
  end

  describe "one listing per import (B1)" do
    test "put/6 keeps the running total and never lists the folder", %{home: home} do
      dir = Store.blobs_dir(home, "flow-prod")
      blobs = for i <- 1..50, do: "blob #{i}"

      {{:ok, used}, calls} =
        calls(fn ->
          {:ok, used} = Store.scan(home, "flow-prod")

          Enum.reduce(blobs, {:ok, used}, fn bytes, {:ok, used} ->
            {:ok, _path, used} =
              Store.put(home, "flow-prod", sha256(bytes), blob(bytes), @quota, used)

            {:ok, used}
          end)
        end)

      # The folder is listed once, by the scan, however many blobs are stored.
      assert for({:ls, ^dir} <- calls, do: dir) == [dir]
      # The running total is exactly what a fresh scan counts.
      assert used == blobs |> Enum.map(&byte_size/1) |> Enum.sum()
      assert {:ok, ^used} = Store.scan(home, "flow-prod")
    end

    test "the quota is checked against the running total it is given", %{home: home} do
      bytes = :binary.copy("t", 10)
      untouched = Stream.map([bytes], fn _ -> flunk("read") end)

      assert {:error, :too_large} =
               Store.put(
                 home,
                 "flow-prod",
                 sha256(bytes),
                 %{size: 10, content: untouched},
                 100,
                 91
               )

      assert {:ok, _path, 100} =
               Store.put(home, "flow-prod", sha256(bytes), blob(bytes), 100, 90)

      assert {:error, :invalid} =
               Store.put(home, "flow-prod", sha256(bytes), blob(bytes), 100, -1)
    end

    test "a blob the source holds is answered from one lookup, its total unchanged", %{home: home} do
      bytes = "held"
      sha = sha256(bytes)
      assert {:ok, path, 4} = Store.put(home, "flow-prod", sha, blob(bytes), @quota, 0)

      {result, calls} = calls(fn -> Store.put(home, "flow-prod", sha, blob(bytes), @quota, 4) end)
      assert {:ok, ^path, 4} = result
      assert calls == [{:lstat, path}]
    end

    test "a store that cannot be listed fails closed", %{home: home} do
      bytes = "x"
      assert {:ok, _} = Store.put(home, "flow-prod", sha256(bytes), blob(bytes), @quota)
      dir = Store.blobs_dir(home, "flow-prod")
      File.chmod!(dir, 0o000)
      on_exit(fn -> File.chmod(dir, 0o700) end)

      case File.ls(dir) do
        # Running with privileges that ignore modes: nothing to check here.
        {:ok, _} ->
          :ok

        {:error, _} ->
          assert {:error, {:io, _}} = Store.scan(home, "flow-prod")
          other = "y"

          assert {:error, {:io, _}} =
                   Store.put(home, "flow-prod", sha256(other), blob(other), @quota)
      end
    end
  end

  test "a writer killed while streaming leaves a temporary file the next scan removes", %{
    home: home
  } do
    test = self()
    bytes = :binary.copy("k", 100)

    # A stream that hands out one chunk, then waits forever: the writer is killed there.
    stuck =
      Stream.concat(
        [binary_part(bytes, 0, 10)],
        Stream.map([1], fn _ ->
          send(test, :streaming)
          Process.sleep(:infinity)
        end)
      )

    writer =
      spawn(fn ->
        Store.put(home, "flow-prod", sha256(bytes), %{size: 100, content: stuck}, @quota)
      end)

    assert_receive :streaming, 5_000
    Process.exit(writer, :kill)
    ref = Process.monitor(writer)
    assert_receive {:DOWN, ^ref, _, _, _}

    dir = Store.blobs_dir(home, "flow-prod")
    assert [".partial-" <> _] = File.ls!(dir)

    # Not counted, and gone after the next start.
    assert {:ok, 0} = Store.scan(home, "flow-prod")
    assert File.ls!(dir) == []
    assert {:ok, path} = Store.put(home, "flow-prod", sha256(bytes), blob(bytes), @quota)
    assert files(home, "flow-prod") == [path]
  end

  test "a stream past its declared size is aborted while streaming, and nothing is left", %{
    home: home
  } do
    counter = :counters.new(1, [])
    chunk = 1024

    assert {:error, :too_long} =
             Store.put(
               home,
               "flow-prod",
               String.duplicate("0", 64),
               %{size: 4096, content: counted(counter, 1000, chunk)},
               @quota
             )

    assert :counters.get(counter, 1) <= 4096 + chunk
    assert files(home, "flow-prod") == []
  end

  test "a stream that raises leaves nothing behind", %{home: home} do
    content = Stream.concat(["abc"], Stream.map([1], fn _ -> raise "transport closed" end))

    assert {:error, {:io, _}} =
             Store.put(
               home,
               "flow-prod",
               String.duplicate("1", 64),
               %{size: 6, content: content},
               @quota
             )

    assert files(home, "flow-prod") == []
  end

  test "malformed names and sizes are refused without touching the home", %{home: home} do
    sha = sha256("x")
    assert {:error, :invalid} = Store.put(home, "../escape", sha, blob("x"), @quota)
    assert {:error, :invalid} = Store.put(home, "flow-prod", "../" <> sha, blob("x"), @quota)

    assert {:error, :invalid} =
             Store.put(home, "flow-prod", String.upcase(sha), blob("x"), @quota)

    assert {:error, :invalid} =
             Store.put(home, "flow-prod", sha, %{size: -1, content: []}, @quota)

    assert :not_found = Store.get(home, "flow-prod", "../../policy.json")
    assert File.ls!(home) == []
  end
end
