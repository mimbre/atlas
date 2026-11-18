defmodule AtlasRuntime.Sources.ImportTest do
  @moduledoc """
  M2 plan W5 (decision §3 "Inputs (F6)", §5.1, §6.6 M2): a leased work's base, and its
  optional change set, are imported from the source that offered it, through that source's
  own blob store (the base's files over Git, as Code serves them), with the caps checked, and
  the base validated by the S5c P6
  validator (the real helper, `workspace base-import`). A blob another source supplied is
  never reused; a change set's `csf_` fingerprints must be the request's.
  """
  use ExUnit.Case, async: true

  alias AtlasRuntime.Model.Work, as: M
  alias AtlasRuntime.Sources.{Import, Store, StoreLock}
  alias AtlasTestAwait, as: Await
  alias AtlasRuntime.Work.Frozen
  alias AtlasRuntime.Workspaces
  alias AtlasRuntime.Test.GitBase

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

  # Import.base/5 as the puller calls it, with the lease's base served over Git (as Code serves
  # it) from what `source` holds: each file entry of the manifest whose bytes it has.
  defp import_base(home, policy, lease, source, opts \\ []) do
    blobs = Agent.get(source, & &1.blobs)
    base = get_in(lease, [:work, :input, :base]) || %{base_id: "none", manifest: nil}

    files =
      case blobs[{:bytes, base.manifest}] || blobs[base.manifest] do
        line when is_binary(line) ->
          for %{"entries" => entries} <- Map.get(JSON.decode!(line), "roots", []),
              %{"kind" => "file", "path" => path, "sha256" => sha} <- entries,
              is_binary(blobs[sha]),
              do: {path, blobs[sha]}

        _ ->
          []
      end

    git = GitBase.serve(base.base_id, files)
    Import.base(home, policy, lease, fetch(source), [git: git] ++ opts)
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
             import_base(home, policy("flow-prod"), lease(manifest), src)

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
             import_base(home, policy("flow-prod"), lease(manifest), src)

    first = length(fetched(src))

    assert {:ok, %{baseline_id: ^id}} =
             import_base(home, policy("flow-prod"), lease(manifest), src)

    assert length(fetched(src)) == first
  end

  test "source B never sees A's blobs: B downloads its own copy of each", %{home: home} do
    {manifest, blobs} = base(@files)
    a = source(blobs)
    b = source(blobs)

    assert {:ok, %{baseline_id: id}} =
             import_base(home, policy("source-a"), lease(manifest), a)

    assert {:ok, %{baseline_id: ^id}} =
             import_base(home, policy("source-b"), lease(manifest), b)

    assert fetched(b) == [manifest]
    for sha <- Map.keys(blobs), do: assert(Store.has?(home, "source-b", sha))
  end

  describe "caps" do
    test "max_base_bytes: a base declaring more is too_large before its content is fetched", %{
      home: home
    } do
      {manifest, blobs} = base(%{"big" => :binary.copy("b", 5000)})
      src = source(blobs)

      assert {:refused, :too_large, "max_base_bytes"} =
               import_base(home, policy("flow-prod"), lease(manifest), src, max_base_bytes: 4096)

      assert fetched(src) == [manifest]
      refute File.exists?(Path.join(home, "snapshots"))
    end

    test "import_deadline: past the import's deadline nothing is fetched, and it is too_large",
         %{home: home} do
      {manifest, blobs} = base(%{"a" => "1"})
      src = source(blobs)

      assert {:refused, :too_large, "import_deadline"} =
               import_base(home, policy("flow-prod"), lease(manifest), src,
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
               import_base(home, policy("flow-prod"), lease(manifest), src, max_base_bytes: 2500)

      assert fetched(src) == [manifest]
    end

    test "max_base_entries: a base with more entries is too_large before its content is fetched",
         %{home: home} do
      {manifest, blobs} = base(%{"a" => "1", "b" => "2", "c" => "3"})
      src = source(blobs)

      assert {:refused, :too_large, "max_base_entries"} =
               import_base(home, policy("flow-prod"), lease(manifest), src, max_base_entries: 2)

      assert fetched(src) == [manifest]
    end

    test "max_store_bytes: a base past the source's quota is too_large and leaves nothing partial",
         %{home: home} do
      {manifest, blobs} = base(%{"big" => :binary.copy("q", 3000)})
      src = source(blobs)

      assert {:refused, :too_large, "max_store_bytes"} =
               import_base(home, policy("flow-prod", 2000), lease(manifest), src)

      dir = Store.blobs_dir(home, "flow-prod")
      assert File.ls!(dir) == [manifest]
      refute File.exists?(Path.join(home, "snapshots"))
    end

    test "a content blob whose sha256 does not match is refused and not stored", %{home: home} do
      {manifest, blobs} = base(%{"a.txt" => "abc"})
      sha = sha256("abc")
      src = source(Map.put(blobs, sha, "abd"))

      assert {:refused, :invalid, "blob_mismatch"} =
               import_base(home, policy("flow-prod"), lease(manifest), src)

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
        calls(fn -> import_base(home, policy("flow-prod"), lease(manifest), src) end)

      assert {:ok, %{baseline_id: "sha256:" <> _}} = result
      assert fetched(src) == [manifest]

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
               import_base(home, policy("flow-prod", 2500), lease(manifest), src)

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
               import_base(home, policy("flow-prod", 1000), lease(manifest), source(blobs))

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
          assert {:error, _} = import_base(home, policy("flow-prod"), lease(manifest), src)
          assert fetched(src) == []
      end
    end
  end

  describe "the validator's refusals" do
    test "a symlink leaving its root", %{home: home} do
      {manifest, blobs} = base(@files, [symlink("escape", "../../outside")])

      assert {:refused, :invalid, "unsafe_tree"} =
               import_base(home, policy("flow-prod"), lease(manifest), source(blobs))

      refute File.exists?(Path.join(home, "snapshots"))
      assert File.ls!(Path.join(home, "bases")) == []
    end

    test "an absolute symlink", %{home: home} do
      {manifest, blobs} = base(@files, [symlink("abs", "/etc/passwd")])

      assert {:refused, :invalid, "unsafe_entry"} =
               import_base(home, policy("flow-prod"), lease(manifest), source(blobs))
    end

    test "a mode a base may not hold", %{home: home} do
      {manifest, blobs} = base(%{}, [file("setuid", "x", "104755")])
      blobs = Map.put(blobs, sha256("x"), "x")

      assert {:refused, :invalid, "unsafe_entry"} =
               import_base(home, policy("flow-prod"), lease(manifest), source(blobs))
    end

    test "a manifest that is no base line", %{home: home} do
      line = ~s({"format":"other"}\n)
      manifest = sha256(line)

      assert {:refused, :invalid, "wrong_format"} =
               import_base(
                 home,
                 policy("flow-prod"),
                 lease(manifest),
                 source(%{manifest => line})
               )
    end
  end

  describe "a change set on top of the base" do
    setup %{home: home} do
      {manifest, blobs} = base(@files)
      src = source(blobs)

      {:ok, %{baseline_id: id}} =
        import_base(home, policy("flow-prod"), lease(manifest), src)

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
               import_base(home, policy("flow-prod"), lease(c.manifest, ref), src)

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
               import_base(
                 home,
                 policy("flow-prod"),
                 lease(c.manifest, %{manifest: cs_sha, fingerprints: other}),
                 src
               )

      refute sha256(new) in fetched(src)
    end

    test "a missing root's fingerprint is a mismatch", %{home: home} = c do
      {cs_sha, cs_bytes, _} = change_set(c.baseline_id, [])
      src = source(Map.put(c.blobs, cs_sha, cs_bytes))

      assert {:refused, :invalid, "change_set_fingerprint"} =
               import_base(
                 home,
                 policy("flow-prod"),
                 lease(c.manifest, %{manifest: cs_sha, fingerprints: []}),
                 src
               )
    end

    test "a change set on another base is refused", %{home: home} = c do
      other = "sha256:" <> String.duplicate("0", 64)
      {cs_sha, cs_bytes, fingerprints} = change_set(other, [])
      src = source(Map.put(c.blobs, cs_sha, cs_bytes))

      assert {:refused, :invalid, "change_set_base"} =
               import_base(
                 home,
                 policy("flow-prod"),
                 lease(c.manifest, %{manifest: cs_sha, fingerprints: fingerprints}),
                 src
               )
    end

    test "a change set that is not one is refused", %{home: home} = c do
      bytes = ~s({"base":"x","roots":[{"root":"atlas","entries":[{"path":"a","op":"move"}]}]})
      src = source(Map.put(c.blobs, sha256(bytes), bytes))

      assert {:refused, :invalid, "change_set_invalid"} =
               import_base(
                 home,
                 policy("flow-prod"),
                 lease(c.manifest, %{manifest: sha256(bytes), fingerprints: []}),
                 src
               )
    end

    # The lock lasts to the import's last write: the change set's blobs, after the helper.
    test "a second import of the same source waits while the first writes its change set's blobs",
         %{home: home} = c do
      new = "new file\n"
      {cs_sha, cs_bytes, fingerprints} = change_set(c.baseline_id, [file("lib/b.ex", new)])
      blobs = c.blobs |> Map.put(cs_sha, cs_bytes) |> Map.put(sha256(new), new)
      ref = %{manifest: cs_sha, fingerprints: fingerprints}
      first = source(gated(blobs, sha256(new)))
      second = source(blobs)

      a =
        Task.async(fn ->
          import_base(home, policy("flow-prod"), lease(c.manifest, ref), first)
        end)

      assert_receive {:writing, writer}
      assert writer == a.pid

      b =
        Task.async(fn ->
          import_base(home, policy("flow-prod"), lease(c.manifest, ref), second)
        end)

      Await.until(
        fn -> StoreLock.waiting(home, "flow-prod") == [b.pid] or fetched(second) != [] end,
        wake: [{:trace, StoreLock}, {:trace, second}]
      )

      send(a.pid, :go)
      Await.down(a.pid)
      Await.down(b.pid)

      assert {:ok, %{baseline_id: id, change_set: %{}}} = Task.await(a)
      assert {:ok, %{baseline_id: ^id, change_set: %{}}} = Task.await(b)
      assert id == c.baseline_id
      assert fetched(second) == []
    end
  end

  # The shared base fixture (work acquisition M3, #317 Q4): Flow's Bases writes an atlas-base
  # v1 line, and Flow's own test pins those bytes to this folder. Here the same files, read in
  # place, go through this importer and the helper's base reader: a change to the rules goes
  # red here, a change to the bytes goes red there.
  describe "the shared base fixture, as Flow's Bases writes it" do
    @fixture Path.expand("../../../atlas_flow/test/fixtures/base_manifest", __DIR__)
    # The baseline the fixture imports to (the A1 fix report's and its re-review's id).
    @fixture_baseline "sha256:f195116376d779057f050c6ccc1adcd46f21254da13bb220c4c81ca0d92e4a46"
    # The fixture manifest's own sha256: the importer canonicalizes, so this pins its bytes.
    @fixture_manifest "ae6a4f2efc53a1e72b99a85dedc8320cec8c245e118170011fb6e4cd959b2006"

    # The fixture's manifest line and its blobs by name, read in place.
    defp shared_fixture do
      line = File.read!(Path.join(@fixture, "manifest"))

      blobs =
        for name <- File.ls!(Path.join(@fixture, "blobs")),
            into: %{},
            do: {name, File.read!(Path.join([@fixture, "blobs", name]))}

      {line, blobs}
    end

    # line with old replaced by new exactly once: a changed fixture cannot make a case a no-op.
    defp replace_once(line, old, new) do
      assert length(String.split(line, old)) == 2, "#{inspect(old)} is not in the fixture once"
      String.replace(line, old, new)
    end

    test "imports, served by its manifest sha256, to the pinned baseline", %{home: home} do
      {line, blobs} = shared_fixture()
      manifest = sha256(line)
      assert manifest == @fixture_manifest
      for {name, bytes} <- blobs, do: assert(sha256(bytes) == name)

      src = source(Map.put(blobs, manifest, line))

      assert {:ok, %{baseline_id: @fixture_baseline, change_set: nil}} =
               import_base(home, policy("flow-prod"), lease(manifest), src)

      # Only the manifest is fetched as a blob: the files come over Git.
      assert fetched(src) == [manifest]

      "sha256:" <> hex = @fixture_baseline
      snapshot = Path.join([home, "snapshots", hex])

      assert "sha256:" <> sha256(File.read!(Path.join(snapshot, "manifest.json"))) ==
               @fixture_baseline

      tree = Path.join([snapshot, "tree", "app"])
      assert {:ok, "../README.md"} = File.read_link(Path.join([tree, "docs", "link"]))
      assert File.read!(Path.join([tree, "docs", "ünïcode.md"])) == "utf-8\n"
      assert File.read!(Path.join([tree, "docs", ~s(say "hi".txt)])) == "quoted\n"
      assert File.read!(Path.join(tree, "empty")) == ""
      assert Bitwise.band(File.stat!(Path.join([tree, "bin", "run"])).mode, 0o111) != 0
      assert File.ls!(Path.join(home, "bases")) == []
    end

    for {name, old, new, rule} <- [
          {"no format", ~s("format":"atlas-base",), "", "wrong_format"},
          {"version 2", ~s("version":1}), ~s("version":2}), "wrong_format"},
          {"an extra top-level key", ~s("version":1}), ~s("version":1,"base_id":"x"}),
           "not_a_base_object"},
          {"a symlink without its target", ~s(,"target":"../README.md"), "", "entry_shape"},
          {"a mode a base may not hold", ~s("mode":"100755"), ~s("mode":"100775"),
           "unsafe_entry"},
          {"an unsafe path", ~s("path":"empty"), ~s("path":"em\\tpty"), "unsafe_path"}
        ] do
      test "one changed field is refused: #{name}", %{home: home} do
        {line, blobs} = shared_fixture()
        line = replace_once(line, unquote(old), unquote(new))
        manifest = sha256(line)
        src = source(Map.put(blobs, manifest, line))

        assert {:refused, :invalid, unquote(rule)} =
                 import_base(home, policy("flow-prod"), lease(manifest), src)

        refute File.exists?(Path.join(home, "snapshots"))
      end
    end

    test "one changed blob byte is refused and not stored", %{home: home} do
      {line, blobs} = shared_fixture()
      manifest = sha256(line)
      readme = sha256("hello\n")
      assert Map.has_key?(blobs, readme)
      src = source(blobs |> Map.put(manifest, line) |> Map.put(readme, "hellO\n"))

      assert {:refused, :invalid, "blob_mismatch"} =
               import_base(home, policy("flow-prod"), lease(manifest), src)

      refute Store.has?(home, "flow-prod", readme)
      refute File.exists?(Path.join(home, "snapshots"))
    end
  end

  # The base a Runtime reports (the frozen change set's `base`, which Flow stores as reported
  # and later serves back as an input's change set base) is the id of the baseline it
  # imported: sha256 of the canonical version 3 manifest of the served entries, nothing of the
  # Runtime in it. So two Runtimes that import one served base agree on it, and a change set
  # one Runtime froze imports on any other (work-source-base-meaning, Main's option A).
  describe "the imported base id: content-derived, equal on every Runtime" do
    # A second, independent Runtime home: another path (another length, a space in it).
    defp other_home do
      parent =
        Path.join(System.tmp_dir!(), "atlas-import-other-#{System.unique_integer([:positive])}")

      home = Path.join([parent, "a Runtime", "home"])
      File.mkdir_p!(home)

      on_exit(fn ->
        System.cmd("chmod", ["-R", "u+w", parent])
        File.rm_rf!(parent)
      end)

      home
    end

    defp snapshot_manifest(home, "sha256:" <> hex),
      do: File.read!(Path.join([home, "snapshots", hex, "manifest.json"]))

    test "one served base imports to the identical id in two Runtime homes", %{home: home} do
      {line, blobs} = shared_fixture()
      manifest = sha256(line)
      served = Map.put(blobs, manifest, line)
      other = other_home()

      # Other homes, sources, lease base_ids and chunkings: none of it is in the id.
      assert {:ok, %{baseline_id: id}} =
               import_base(home, policy("flow-prod"), lease(manifest), source(served))

      assert {:ok, %{baseline_id: ^id}} =
               import_base(
                 other,
                 policy("flow-other"),
                 put_in(lease(manifest), [:work, :input, :base, :base_id], "b-other"),
                 source(served)
               )

      assert id == @fixture_baseline
      assert snapshot_manifest(home, id) == snapshot_manifest(other, id)
      assert id == "sha256:" <> sha256(snapshot_manifest(other, id))
    end

    test "the same files served in another entry order import to the same id", %{home: home} do
      {line, blobs} = shared_fixture()
      %{"roots" => [root]} = decoded = JSON.decode!(line)

      reordered =
        JSON.encode!(%{
          decoded
          | "roots" => [%{root | "entries" => Enum.reverse(root["entries"])}]
        }) <>
          "\n"

      assert reordered != line

      assert {:ok, %{baseline_id: id}} =
               import_base(
                 other_home(),
                 policy("flow-prod"),
                 lease(sha256(reordered)),
                 source(Map.put(blobs, sha256(reordered), reordered))
               )

      assert {:ok, %{baseline_id: ^id}} =
               import_base(
                 home,
                 policy("flow-prod"),
                 lease(sha256(line)),
                 source(Map.put(blobs, sha256(line), line))
               )
    end

    test "a change set frozen on one Runtime imports, on its reported base, into a fresh one",
         %{home: home} do
      {line, blobs} = shared_fixture()
      manifest = sha256(line)
      served = Map.put(blobs, manifest, line)

      # Runtime A, as its executor does: import, compose the folder (the base and an empty
      # change set), change it, freeze it.
      assert {:ok, %{baseline_id: id, change_set: nil}} =
               import_base(home, policy("flow-prod"), lease(manifest), source(served))

      empty = Path.join(home, "empty-change-set.json")
      File.write!(empty, JSON.encode!(%{"base" => id, "roots" => []}))
      dest = Path.join([home, "workers", "work-w-1"])
      File.mkdir_p!(Path.dirname(dest))

      assert {:ok, _} =
               Workspaces.compose(home, id, empty, Store.blobs_dir(home, "flow-prod"), dest,
                 timeout_ms: 60_000
               )

      new = "frozen on A\n"
      File.write!(Path.join([dest, "app", "new.txt"]), new)
      File.rm!(Path.join([dest, "app", "empty"]))

      frozen_blobs = Path.join(home, "frozen-blobs")
      File.mkdir_p!(frozen_blobs)
      assert {:ok, output} = Workspaces.changes(home, dest, frozen_blobs, timeout_ms: 60_000)

      assert {:ok, frozen} =
               Frozen.build(output, work_record(id), 1, ~U[2026-11-17 09:00:00.000Z])

      # The base A reports is the id it imported.
      assert frozen.base == id

      set = Frozen.change_set(frozen)
      cs_bytes = JSON.encode!(set)
      ref = %{manifest: sha256(cs_bytes), fingerprints: AtlasChangeset.fingerprints(set)}

      # Runtime B: a fresh home, the same base served afresh, and A's change set on it.
      b = other_home()

      src =
        served
        |> Map.put(ref.manifest, cs_bytes)
        |> Map.put(sha256(new), File.read!(Path.join(frozen_blobs, sha256(new))))

      assert {:ok, %{baseline_id: ^id, change_set: %{file: file, blobs: blobs_dir}}} =
               import_base(b, policy("flow-prod"), lease(manifest, ref), source(src))

      b_dest = Path.join([b, "workers", "work-w-2"])
      File.mkdir_p!(Path.dirname(b_dest))
      assert {:ok, _} = Workspaces.compose(b, id, file, blobs_dir, b_dest, timeout_ms: 60_000)
      assert File.read!(Path.join([b_dest, "app", "new.txt"])) == new
      refute File.exists?(Path.join([b_dest, "app", "empty"]))
    end

    defp work_record(base_id) do
      M.WorkRecord.new!(
        work_id: "work-0123456789abcdef",
        client: "c1",
        idempotency_key: "k",
        revision: 1,
        sequence: 1,
        request:
          M.Request.new!(
            title: "t",
            instructions: "t",
            profile: "light_work",
            cost_class: :standard,
            workspace: M.Base.new!(base_id: base_id, permissions: :workspace_write)
          ),
        attempts: []
      )
    end
  end

  test "an input without a usable base reference is refused", %{home: home} do
    src = source(%{})

    assert {:refused, :invalid, "input_ref"} =
             import_base(home, policy("flow-prod"), lease("../x"), src)

    assert {:refused, :invalid, "no_base"} =
             import_base(home, policy("flow-prod"), %{work: %{}}, src)

    assert fetched(src) == []
  end

  ## One import per source store at a time (StoreLock; CI end_to_end_test "local works next
  ## to leases": two leases on one base imported at once, one failed "cannot store blob")

  # The source's blobs, with `gated` streamed in full and then held before its end until
  # the test sends `:go`: the import that streams it is in the middle of its write, with its
  # `.partial-*` file open. It tells the test `{:writing, pid}` first.
  defp gated(blobs, gated) do
    test = self()
    bytes = Map.fetch!(blobs, gated)

    hold =
      Stream.flat_map([nil], fn _ ->
        send(test, {:writing, self()})
        receive do: (:go -> [])
      end)

    blobs
    |> Map.put(gated, {:stream, byte_size(bytes), Stream.concat([bytes], hold)})
    |> Map.put({:bytes, gated}, bytes)
  end

  test "a second import of the same source waits for the first one's last write; both succeed",
       %{home: home} do
    {manifest, blobs} = base(@files)
    first = source(gated(blobs, manifest))
    second = source(blobs)

    a =
      Task.async(fn -> import_base(home, policy("flow-prod"), lease(manifest), first) end)

    assert_receive {:writing, writer}
    assert writer == a.pid

    b =
      Task.async(fn -> import_base(home, policy("flow-prod"), lease(manifest), second) end)

    # The second import has either queued for the store's lock, or (with no lock) listed
    # the store, removing the first one's temporary file, and fetched.
    Await.until(
      fn -> StoreLock.waiting(home, "flow-prod") == [b.pid] or fetched(second) != [] end,
      wake: [{:trace, StoreLock}, {:trace, second}]
    )

    send(a.pid, :go)
    Await.down(a.pid)
    Await.down(b.pid)

    assert {:ok, %{baseline_id: id}} = Task.await(a)
    assert {:ok, %{baseline_id: ^id}} = Task.await(b)
    # It ran after the first one: every blob was in the store already.
    assert fetched(second) == []
    assert StoreLock.holder(home, "flow-prod") == nil
  end

  test "an import killed while it holds its source's lock releases it: the waiting one goes on",
       %{home: home} do
    {manifest, blobs} = base(@files)
    first = source(gated(blobs, manifest))
    second = source(blobs)

    # Not linked to the test: it is killed, as the puller kills an import past its deadline.
    a = spawn(fn -> import_base(home, policy("flow-prod"), lease(manifest), first) end)
    assert_receive {:writing, ^a}
    assert StoreLock.holder(home, "flow-prod") == a

    b =
      Task.async(fn -> import_base(home, policy("flow-prod"), lease(manifest), second) end)

    Await.until(fn -> StoreLock.waiting(home, "flow-prod") == [b.pid] end,
      wake: {:trace, StoreLock}
    )

    Process.exit(a, :kill)
    Await.down(b.pid)

    assert {:ok, %{baseline_id: "sha256:" <> _}} = Task.await(b)
    # The killed import stored nothing: the second one fetched the manifest again.
    assert fetched(second) == [manifest]
    assert StoreLock.holder(home, "flow-prod") == nil
    assert StoreLock.waiting(home, "flow-prod") == []
    # Nothing partial is left: the killed writer's temporary file was removed by the scan.
    assert {:ok, names} = File.ls(Store.blobs_dir(home, "flow-prod"))
    assert Enum.sort(names) == Enum.sort(Map.keys(blobs))
  end
end
