defmodule AtlasRuntime.Sources.ImportTest do
  @moduledoc """
  M2 plan W5 (decision §3 "Inputs (F6)", §5.1, §6.6 M2): a leased work's base, and its
  optional change set, are imported from the source that offered it, through that source's
  own blob store, with the caps checked while streaming, and the base validated by the S5c P6
  validator (the real helper, `workspace base-import`). A blob another source supplied is
  never reused; a change set's `csf_` fingerprints must be the request's.
  """
  use ExUnit.Case, async: true

  alias AtlasRuntime.Sources.{Import, Store}
  alias AtlasRuntime.Workspaces

  @quota 10_000_000

  setup do
    home =
      Path.join(System.tmp_dir!(), "atlas-import-#{System.unique_integer([:positive])}")

    File.mkdir_p!(home)

    on_exit(fn ->
      # Baselines are sealed read-only.
      System.cmd("chmod", ["-R", "u+w", home])
      File.rm_rf!(home)
    end)

    %{home: home}
  end

  ## A fake source: its blobs, every fetch counted.

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp source(blobs) do
    {:ok, pid} = Agent.start_link(fn -> %{blobs: blobs, fetched: []} end)
    pid
  end

  defp fetch(source, chunk \\ 4096) do
    fn sha ->
      Agent.get_and_update(source, fn s ->
        s = %{s | fetched: [sha | s.fetched]}

        case Map.fetch(s.blobs, sha) do
          {:ok, {:stream, size, content}} ->
            {{:ok, %{sha256: sha, size: size, content: content}}, s}

          {:ok, bytes} ->
            {{:ok, %{sha256: sha, size: byte_size(bytes), content: chunks(bytes, chunk)}}, s}

          :error ->
            {:not_found, s}
        end
      end)
    end
  end

  defp fetched(source), do: Agent.get(source, &Enum.reverse(&1.fetched))

  defp chunks(bytes, size) do
    Stream.unfold(bytes, fn
      "" -> nil
      <<chunk::binary-size(size), rest::binary>> -> {chunk, rest}
      rest -> {rest, ""}
    end)
  end

  # The calls this process makes to File.ls/1 and File.lstat/1 while running fun (the import
  # runs in the caller; the fake source is another process). Patterns are left on: they cost
  # nothing for untraced processes, and switching them off could break a concurrent count.
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

  defp policy(name, max \\ @quota), do: %{"name" => name, "max_store_bytes" => max}

  ## Bases and change sets

  defp file(path, content, mode \\ "100644"),
    do: %{
      "path" => path,
      "op" => "write",
      "kind" => "file",
      "mode" => mode,
      "size" => byte_size(content),
      "sha256" => sha256(content)
    }

  defp symlink(path, target),
    do: %{
      "path" => path,
      "op" => "write",
      "kind" => "symlink",
      "mode" => "120000",
      "size" => byte_size(target),
      "sha256" => sha256(target),
      "target" => target
    }

  # A base of one root: its line 1 and the blobs (manifest and contents) by sha256.
  defp base(files, extra \\ []) do
    entries = for {path, content} <- files, do: file(path, content)

    line =
      JSON.encode!(%{
        "format" => "atlas-base",
        "version" => 1,
        "roots" => [%{"root" => "atlas", "entries" => entries ++ extra}]
      }) <> "\n"

    blobs = Map.new(files, fn {_path, content} -> {sha256(content), content} end)
    {sha256(line), Map.put(blobs, sha256(line), line)}
  end

  defp lease(manifest, change_set \\ nil),
    do: %{
      lease_id: "lease-1",
      work: %{
        work_key: "task-1",
        input: %{base: %{base_id: "b-1", manifest: manifest}, change_set: change_set}
      }
    }

  defp change_set(baseline_id, entries) do
    set = %{"base" => baseline_id, "roots" => [%{"root" => "atlas", "entries" => entries}]}
    bytes = JSON.encode!(set)
    {sha256(bytes), bytes, AtlasChangeset.fingerprints(set)}
  end

  @files %{"README.md" => "hello\n", "lib/a.ex" => "defmodule A, do: nil\n"}

  test "a base is imported into a read-only baseline, its blobs into the source's store", %{
    home: home
  } do
    {manifest, blobs} = base(@files)
    src = source(blobs)

    assert {:ok, %{baseline_id: "sha256:" <> hex, change_set: nil}} =
             Import.base(home, policy("flow-prod"), lease(manifest), fetch(src))

    assert File.read!(Path.join([home, "snapshots", hex, "complete"])) == "sha256:#{hex}\n"

    assert File.read!(Path.join([home, "snapshots", hex, "tree", "atlas", "lib", "a.ex"])) ==
             @files["lib/a.ex"]

    for sha <- Map.keys(blobs), do: assert(Store.has?(home, "flow-prod", sha))
    # The staging folder is gone.
    assert File.ls!(Path.join(home, "bases")) == []
  end

  test "a source's own blobs are not downloaded again", %{home: home} do
    {manifest, blobs} = base(@files)
    src = source(blobs)

    assert {:ok, %{baseline_id: id}} =
             Import.base(home, policy("flow-prod"), lease(manifest), fetch(src))

    first = length(fetched(src))

    assert {:ok, %{baseline_id: ^id}} =
             Import.base(home, policy("flow-prod"), lease(manifest), fetch(src))

    assert length(fetched(src)) == first
  end

  test "source B never sees A's blobs: B downloads its own copy of each", %{home: home} do
    {manifest, blobs} = base(@files)
    a = source(blobs)
    b = source(blobs)

    assert {:ok, %{baseline_id: id}} =
             Import.base(home, policy("source-a"), lease(manifest), fetch(a))

    assert {:ok, %{baseline_id: ^id}} =
             Import.base(home, policy("source-b"), lease(manifest), fetch(b))

    assert Enum.sort(fetched(b)) == Enum.sort(Map.keys(blobs))
    for sha <- Map.keys(blobs), do: assert(Store.has?(home, "source-b", sha))
  end

  test "B's import fails when B does not serve a blob, though A holds it", %{home: home} do
    {manifest, blobs} = base(@files)
    a = source(blobs)
    assert {:ok, _} = Import.base(home, policy("source-a"), lease(manifest), fetch(a))

    {content_sha, _} = Enum.find(blobs, fn {sha, _} -> sha != manifest end)
    b = source(Map.delete(blobs, content_sha))
    assert {:error, _} = Import.base(home, policy("source-b"), lease(manifest), fetch(b))
    assert content_sha in fetched(b)
  end

  describe "caps" do
    test "max_base_bytes: a base declaring more is too_large before its content is fetched", %{
      home: home
    } do
      {manifest, blobs} = base(%{"big" => :binary.copy("b", 5000)})
      src = source(blobs)

      assert {:refused, :too_large, "max_base_bytes"} =
               Import.base(home, policy("flow-prod"), lease(manifest), fetch(src),
                 max_base_bytes: 4096
               )

      assert fetched(src) == [manifest]
      refute File.exists?(Path.join(home, "snapshots"))
    end

    test "import_deadline: past the import's deadline nothing is fetched, and it is too_large",
         %{home: home} do
      {manifest, blobs} = base(%{"a" => "1"})
      src = source(blobs)

      assert {:refused, :too_large, "import_deadline"} =
               Import.base(home, policy("flow-prod"), lease(manifest), fetch(src),
                 deadline_at: System.monotonic_time(:millisecond) - 1
               )

      assert fetched(src) == []
      refute File.exists?(Path.join(home, "snapshots"))
    end

    test "max_base_bytes counts every file entry, repeated contents included", %{home: home} do
      same = :binary.copy("r", 1000)
      {manifest, blobs} = base(%{"a" => same, "b" => same, "c" => same})
      src = source(blobs)

      assert {:refused, :too_large, "max_base_bytes"} =
               Import.base(home, policy("flow-prod"), lease(manifest), fetch(src),
                 max_base_bytes: 2500
               )

      assert fetched(src) == [manifest]
    end

    test "max_base_entries: a base with more entries is too_large before its content is fetched",
         %{home: home} do
      {manifest, blobs} = base(%{"a" => "1", "b" => "2", "c" => "3"})
      src = source(blobs)

      assert {:refused, :too_large, "max_base_entries"} =
               Import.base(home, policy("flow-prod"), lease(manifest), fetch(src),
                 max_base_entries: 2
               )

      assert fetched(src) == [manifest]
    end

    test "an oversized stream is aborted while streaming: at most the cap plus one chunk is read",
         %{home: home} do
      declared = 4096
      chunk = 1024
      entry = %{file("big", "") | "size" => declared, "sha256" => String.duplicate("a", 64)}

      line =
        JSON.encode!(%{
          "format" => "atlas-base",
          "version" => 1,
          "roots" => [%{"root" => "atlas", "entries" => [entry]}]
        }) <> "\n"

      manifest = sha256(line)
      counter = :counters.new(1, [])

      endless =
        Stream.repeatedly(fn ->
          :counters.add(counter, 1, chunk)
          :binary.copy("x", chunk)
        end)
        |> Stream.take(1000)

      src = source(%{manifest => line, entry["sha256"] => {:stream, declared, endless}})

      assert {:refused, :too_large, "stream_too_long"} =
               Import.base(home, policy("flow-prod"), lease(manifest), fetch(src),
                 max_base_bytes: declared
               )

      assert :counters.get(counter, 1) <= declared + chunk
      refute Store.has?(home, "flow-prod", entry["sha256"])
    end

    test "a blob served with another size than its entry's is refused unread", %{home: home} do
      {manifest, blobs} = base(%{"a.txt" => "abc"})
      sha = sha256("abc")
      src = source(Map.put(blobs, sha, {:stream, 2, Stream.map([1], fn _ -> flunk("read") end)}))

      assert {:refused, :invalid, "blob_size"} =
               Import.base(home, policy("flow-prod"), lease(manifest), fetch(src))
    end

    test "max_store_bytes: a base past the source's quota is too_large and leaves nothing partial",
         %{home: home} do
      {manifest, blobs} = base(%{"big" => :binary.copy("q", 3000)})
      src = source(blobs)

      assert {:refused, :too_large, "max_store_bytes"} =
               Import.base(home, policy("flow-prod", 2000), lease(manifest), fetch(src))

      dir = Store.blobs_dir(home, "flow-prod")
      assert File.ls!(dir) == [manifest]
      refute File.exists?(Path.join(home, "snapshots"))
    end

    test "a content blob whose sha256 does not match is refused and not stored", %{home: home} do
      {manifest, blobs} = base(%{"a.txt" => "abc"})
      sha = sha256("abc")
      src = source(Map.put(blobs, sha, "abd"))

      assert {:refused, :invalid, "blob_mismatch"} =
               Import.base(home, policy("flow-prod"), lease(manifest), fetch(src))

      refute Store.has?(home, "flow-prod", sha)
    end
  end

  describe "the store quota costs one listing per import (B1)" do
    test "an import of many blobs lists the source's folder once and stats each blob a bounded number of times",
         %{home: home} do
      n = 300
      files = Map.new(1..n, fn i -> {"f/#{i}.txt", "content #{i}\n"} end)
      {manifest, blobs} = base(files)
      src = source(blobs)
      dir = Store.blobs_dir(home, "flow-prod")

      {result, calls} =
        calls(fn -> Import.base(home, policy("flow-prod"), lease(manifest), fetch(src)) end)

      assert {:ok, %{baseline_id: "sha256:" <> _}} = result
      assert length(fetched(src)) == n + 1

      # One listing, not one per blob.
      assert for({:ls, ^dir} <- calls, do: dir) == [dir]
      # Stats grow with the blob count, not its square (n²/2 = 45000 before the fix).
      stats = for {:lstat, path} <- calls, Path.dirname(path) == dir, do: path
      assert length(stats) <= 3 * (n + 1)

      # The running total ended exactly where a fresh count is.
      assert {:ok, used} = Store.scan(home, "flow-prod")
      assert used == blobs |> Map.values() |> Enum.map(&byte_size/1) |> Enum.sum()
    end

    test "the running total still refuses at the quota, mid-import", %{home: home} do
      # Four blobs of 1000 bytes and a manifest: the quota is crossed by the last blobs.
      files = Map.new(1..4, fn i -> {"#{i}", :binary.copy(Integer.to_string(i), 1000)} end)
      {manifest, blobs} = base(files)
      src = source(blobs)

      assert {:refused, :too_large, "max_store_bytes"} =
               Import.base(home, policy("flow-prod", 2500), lease(manifest), fetch(src))

      assert {:ok, used} = Store.scan(home, "flow-prod")
      assert used <= 2500
      refute File.exists?(Path.join(home, "snapshots"))
    end

    test "an orphan temporary file from a killed import is removed by the next import", %{
      home: home
    } do
      dir = Store.blobs_dir(home, "flow-prod")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, ".partial-12345"), :binary.copy("o", 5000))

      {manifest, blobs} = base(@files)

      # Not counted against the quota (the base needs far less than 5000 bytes) and removed.
      assert {:ok, _} =
               Import.base(home, policy("flow-prod", 1000), lease(manifest), fetch(source(blobs)))

      refute Enum.any?(File.ls!(dir), &String.starts_with?(&1, ".partial-"))
    end

    test "a store that cannot be read fails the import before anything is fetched", %{home: home} do
      dir = Store.blobs_dir(home, "flow-prod")
      File.mkdir_p!(dir)
      File.chmod!(dir, 0o000)
      on_exit(fn -> File.chmod(dir, 0o700) end)

      case File.ls(dir) do
        {:ok, _} ->
          :ok

        {:error, _} ->
          {manifest, blobs} = base(@files)
          src = source(blobs)
          assert {:error, _} = Import.base(home, policy("flow-prod"), lease(manifest), fetch(src))
          assert fetched(src) == []
      end
    end
  end

  describe "the validator's refusals" do
    test "a symlink leaving its root", %{home: home} do
      {manifest, blobs} = base(@files, [symlink("escape", "../../outside")])

      assert {:refused, :invalid, "unsafe_tree"} =
               Import.base(home, policy("flow-prod"), lease(manifest), fetch(source(blobs)))

      refute File.exists?(Path.join(home, "snapshots"))
      assert File.ls!(Path.join(home, "bases")) == []
    end

    test "an absolute symlink", %{home: home} do
      {manifest, blobs} = base(@files, [symlink("abs", "/etc/passwd")])

      assert {:refused, :invalid, "unsafe_entry"} =
               Import.base(home, policy("flow-prod"), lease(manifest), fetch(source(blobs)))
    end

    test "a mode a base may not hold", %{home: home} do
      {manifest, blobs} = base(%{}, [file("setuid", "x", "104755")])
      blobs = Map.put(blobs, sha256("x"), "x")

      assert {:refused, :invalid, "unsafe_entry"} =
               Import.base(home, policy("flow-prod"), lease(manifest), fetch(source(blobs)))
    end

    test "a manifest that is no base line", %{home: home} do
      line = ~s({"format":"other"}\n)
      manifest = sha256(line)

      assert {:refused, :invalid, "wrong_format"} =
               Import.base(
                 home,
                 policy("flow-prod"),
                 lease(manifest),
                 fetch(source(%{manifest => line}))
               )
    end
  end

  describe "a change set on top of the base" do
    setup %{home: home} do
      {manifest, blobs} = base(@files)
      src = source(blobs)

      {:ok, %{baseline_id: id}} =
        Import.base(home, policy("flow-prod"), lease(manifest), fetch(src))

      %{manifest: manifest, blobs: blobs, baseline_id: id}
    end

    test "its blobs come from the source and the change set composes onto the base",
         %{home: home} = c do
      new = "new file\n"
      entries = [file("lib/b.ex", new), %{"path" => "README.md", "op" => "delete"}]
      {cs_sha, cs_bytes, fingerprints} = change_set(c.baseline_id, entries)
      src = source(c.blobs |> Map.put(cs_sha, cs_bytes) |> Map.put(sha256(new), new))
      ref = %{manifest: cs_sha, fingerprints: fingerprints}

      assert {:ok, %{baseline_id: id, change_set: %{file: file, blobs: blobs_dir}}} =
               Import.base(home, policy("flow-prod"), lease(c.manifest, ref), fetch(src))

      assert id == c.baseline_id
      assert Enum.sort(fetched(src)) == Enum.sort([cs_sha, sha256(new)])

      dest = Path.join([home, "workers", "work-w-1"])
      File.mkdir_p!(Path.dirname(dest))
      assert {:ok, _} = Workspaces.compose(home, id, file, blobs_dir, dest, timeout_ms: 60_000)
      assert File.read!(Path.join([dest, "atlas", "lib", "b.ex"])) == new
      refute File.exists?(Path.join([dest, "atlas", "README.md"]))
    end

    test "fingerprint mismatch refused, before its content blobs are fetched",
         %{home: home} = c do
      new = "new file\n"
      {cs_sha, cs_bytes, _} = change_set(c.baseline_id, [file("lib/b.ex", new)])
      {_, _, other} = change_set(c.baseline_id, [file("lib/b.ex", "other\n")])
      src = source(c.blobs |> Map.put(cs_sha, cs_bytes) |> Map.put(sha256(new), new))

      assert {:refused, :invalid, "change_set_fingerprint"} =
               Import.base(
                 home,
                 policy("flow-prod"),
                 lease(c.manifest, %{manifest: cs_sha, fingerprints: other}),
                 fetch(src)
               )

      refute sha256(new) in fetched(src)
    end

    test "a missing root's fingerprint is a mismatch", %{home: home} = c do
      {cs_sha, cs_bytes, _} = change_set(c.baseline_id, [])
      src = source(Map.put(c.blobs, cs_sha, cs_bytes))

      assert {:refused, :invalid, "change_set_fingerprint"} =
               Import.base(
                 home,
                 policy("flow-prod"),
                 lease(c.manifest, %{manifest: cs_sha, fingerprints: []}),
                 fetch(src)
               )
    end

    test "a change set on another base is refused", %{home: home} = c do
      other = "sha256:" <> String.duplicate("0", 64)
      {cs_sha, cs_bytes, fingerprints} = change_set(other, [])
      src = source(Map.put(c.blobs, cs_sha, cs_bytes))

      assert {:refused, :invalid, "change_set_base"} =
               Import.base(
                 home,
                 policy("flow-prod"),
                 lease(c.manifest, %{manifest: cs_sha, fingerprints: fingerprints}),
                 fetch(src)
               )
    end

    test "a change set that is not one is refused", %{home: home} = c do
      bytes = ~s({"base":"x","roots":[{"root":"atlas","entries":[{"path":"a","op":"move"}]}]})
      src = source(Map.put(c.blobs, sha256(bytes), bytes))

      assert {:refused, :invalid, "change_set_invalid"} =
               Import.base(
                 home,
                 policy("flow-prod"),
                 lease(c.manifest, %{manifest: sha256(bytes), fingerprints: []}),
                 fetch(src)
               )
    end
  end

  test "an input without a usable base reference is refused", %{home: home} do
    src = source(%{})

    assert {:refused, :invalid, "input_ref"} =
             Import.base(home, policy("flow-prod"), lease("../x"), fetch(src))

    assert {:refused, :invalid, "no_base"} =
             Import.base(home, policy("flow-prod"), %{work: %{}}, fetch(src))

    assert fetched(src) == []
  end
end
