defmodule AtlasFlow.BasesTest do
  # Bases against FakeCode: the base and its manifest blob, reuse per revision, the names a
  # lease may read, blobs read through, and that no caller ever waits on Code.
  use ExUnit.Case, async: true

  alias AtlasFlow.{Bases, FakeCode, ManualClock}

  @repository "example.org/acme/app"
  @readme "hello\n"
  @run "#!/bin/sh\necho run\n"
  @large :binary.copy("0123456789abcdef", 10_000)

  setup do
    fake = start_supervised!({FakeCode, %{}}, id: :fake)
    FakeCode.put(fake, @repository, "develop", "rev_1", files())
    clock = start_supervised!({ManualClock, ~U[2026-11-17 12:00:00Z]}, id: :clock)
    name = :"bases_#{System.unique_integer([:positive])}"
    %{fake: fake, clock: clock, name: name}
  end

  defp files, do: %{"README.md" => @readme, "bin/run" => @run, "data/large.bin" => @large}

  defp start_bases(%{fake: fake, clock: clock, name: name}) do
    start_supervised!(
      {Bases, name: name, client: FakeCode.client(fake), clock: {ManualClock, clock}},
      id: name
    )
  end

  defp sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp ready(context, reference \\ "develop") do
    :ok = Bases.request(@repository, reference, {self(), {:ready, reference}}, context.name)
    # The base is resolved in Bases' own task: a loaded machine may take longer than 100 ms.
    assert_receive {:ready, ^reference}, 2_000
    {:ok, base} = Bases.cached(@repository, reference, context.name)
    base
  end

  defp count(fake, capability),
    do: fake |> FakeCode.calls() |> Enum.count(&(elem(&1, 0) == capability))

  # Waits until Bases has handled everything sent to it so far, and its task has answered.
  defp settle(context, until) do
    Enum.reduce_while(1..200, nil, fn _, _ ->
      :sys.get_state(context.name)

      if until.() do
        {:halt, :ok}
      else
        Process.sleep(5)
        {:cont, nil}
      end
    end)

    assert until.()
  end

  describe "a base" do
    test "is code-<snapshot hex> and the sha256 of the canonical manifest blob", context do
      start_bases(context)
      base = ready(context)

      assert %{base_id: "code-" <> hex, manifest: manifest, snapshot_id: "sha256:" <> hex} = base
      assert String.match?(hex, ~r/\A[0-9a-f]{64}\z/)

      expected =
        ~s({"format":"atlas-base","roots":[{"entries":[) <>
          ~s({"kind":"file","mode":"100644","op":"write","path":"README.md","sha256":"#{sha256(@readme)}","size":#{byte_size(@readme)}},) <>
          ~s({"kind":"file","mode":"100755","op":"write","path":"bin/run","sha256":"#{sha256(@run)}","size":#{byte_size(@run)}},) <>
          ~s({"kind":"file","mode":"100644","op":"write","path":"data/large.bin","sha256":"#{sha256(@large)}","size":#{byte_size(@large)}}) <>
          ~s(],"root":"app"}],"version":1}\n)

      assert {:ok, size, stream} = Bases.blob(manifest, base.snapshot_id, context.name)
      assert Enum.join(stream) == expected
      assert size == byte_size(expected)
      assert manifest == sha256(expected)
    end

    test "a symlink keeps its target, and strings are escaped as the change set escapes them",
         context do
      # Escaping only: Code's path rule never yields control characters, and W5's validator
      # refuses them (unsafe_path); the base W5 imports is pinned by the fixture test below.
      odd = "dir/a\tb\nc\u0001\"q\\"

      FakeCode.put(context.fake, @repository, "odd", "rev_odd", %{
        "README.md" => @readme,
        "link" => {:symlink, "README.md"},
        odd => @run
      })

      start_bases(context)
      base = ready(context, "odd")
      {:ok, _size, stream} = Bases.blob(base.manifest, base.snapshot_id, context.name)
      bytes = Enum.join(stream)
      document = JSON.decode!(bytes)

      # The entries are the change set's write entries (AtlasChangeset validates them) ...
      assert %{"format" => "atlas-base", "version" => 1} = document
      change_set = %{"base" => base.base_id, "roots" => document["roots"]}
      assert :ok = AtlasChangeset.validate(change_set)
      [%{"root" => "app", "entries" => entries}] = document["roots"]
      assert Enum.map(entries, & &1["path"]) == Enum.sort([odd, "README.md", "link"])

      assert %{"kind" => "symlink", "mode" => "120000", "target" => "README.md"} =
               Enum.find(entries, &(&1["path"] == "link"))

      # ... and the root's bytes are exactly the change set's canonical bytes for it.
      "{" <> canonical_rest =
        String.replace_prefix(
          AtlasChangeset.canonical(base.base_id, "app", entries),
          ~s({"base":#{Bases.canonical(base.base_id)},),
          "{"
        )

      assert bytes ==
               ~s({"format":"atlas-base","roots":[{) <> canonical_rest <> ~s(],"version":1}\n)
    end

    test "is deterministic: the same revision gives the same base, from any Bases", context do
      {:ok, first} = Bases.for(FakeCode.client(context.fake), @repository, "develop")

      other = start_supervised!({FakeCode, %{}}, id: :other)
      FakeCode.put(other, @repository, "main", "rev_1", files())
      assert {:ok, ^first} = Bases.for(FakeCode.client(other), @repository, "main")

      start_bases(context)
      assert ready(context) == first
    end

    test "is reused per revision: one snapshot, however many references or requests", context do
      FakeCode.put(context.fake, @repository, "main", "rev_1", files())
      start_bases(context)

      develop = ready(context, "develop")
      assert ready(context, "main") == develop
      assert ready(context, "develop") == develop
      assert count(context.fake, :create_snapshot) == 1
      # The cached reference answers at once: no third resolution.
      assert count(context.fake, :resolve_reference) == 2

      FakeCode.put(context.fake, @repository, "next", "rev_2", Map.put(files(), "NEW", "x"))
      assert ready(context, "next").base_id != develop.base_id
      assert count(context.fake, :create_snapshot) == 2
    end

    test "an unknown reference is unavailable, and the caller is not notified", context do
      start_bases(context)
      :ok = Bases.request(@repository, "nowhere", {self(), :ready}, context.name)

      settle(context, fn -> Bases.cached(@repository, "nowhere", context.name) == :unavailable end)

      refute_received :ready
    end
  end

  describe "the manifest W5's importer decodes (#311, Q4)" do
    # A shared fixture: test/fixtures/base_manifest/manifest is the manifest blob Bases writes
    # for @fixture_files under root "app", and blobs/<sha256> holds each file's content. Runtime's
    # counterpart (a follow-up; platform/atlas_runtime is not A1's) imports exactly these files
    # through W5's import (Import.base/5). The rules below are W5's, cited by line:
    # import.ex and store.ex of #311, and the validator they run, `workspace base-import`
    # (atlas_runtime/host/snapshot/base.go, compose.go, snapshot.go).
    @fixture Path.expand("fixtures/base_manifest", __DIR__)
    @fixture_files %{
      "README.md" => "hello\n",
      "bin/run" => "#!/bin/sh\necho run\n",
      "copy.txt" => "hello\n",
      "docs/link" => {:symlink, "../README.md"},
      "docs/say \"hi\".txt" => "quoted\n",
      "docs/ünïcode.md" => "utf-8\n",
      "empty" => "",
      "nested/deep/file.txt" => "deep\n"
    }
    @sha256 ~r/\A[0-9a-f]{64}\z/

    test "Bases writes the fixture byte for byte, and it decodes by W5's rules", context do
      FakeCode.put(context.fake, @repository, "fixture", "rev_fixture", @fixture_files)
      start_bases(context)
      base = ready(context, "fixture")
      {:ok, size, stream} = Bases.blob(base.manifest, base.snapshot_id, context.name)
      bytes = Enum.join(stream)

      # The shared fixture, exactly.
      assert bytes == File.read!(Path.join(@fixture, "manifest"))
      assert size == byte_size(bytes)

      # The reference: 64 lowercase hex, no prefix (import.ex:116, store.ex:32,44), and the
      # sha256 of the blob's bytes (store.ex:225-232), within the line cap (import.ex:44,77,
      # 155,173; base.go:26,330).
      assert base.manifest =~ @sha256
      assert base.manifest == sha256(bytes)
      assert byte_size(bytes) <= 64 * 1024 * 1024

      # One line, nothing after its newline (base.go:333); one object with exactly format,
      # version and roots, format "atlas-base", version 1 (base.go:336-351; import.ex:216).
      assert :binary.matches(bytes, "\n") == [{byte_size(bytes) - 1, 1}]
      assert {:ok, %{"roots" => roots} = document} = JSON.decode(bytes)
      assert Enum.sort(Map.keys(document)) == ["format", "roots", "version"]
      assert %{"format" => "atlas-base", "version" => 1} = document

      # Roots: unique, each one safe name without "/" (base.go:143,355), with a list of
      # entries (import.ex:217).
      assert [%{"root" => "app", "entries" => entries} = root] = roots
      assert Enum.sort(Map.keys(root)) == ["entries", "root"]
      assert safe?("app") and is_list(entries)

      # Entries: writes only (base.go:368), unique safe paths relative to the root
      # (base.go:371-377, snapshot.go:515-531), exactly the keys of their kind
      # (compose.go:214-246), and consistent (snapshot.go:489-511).
      paths = Enum.map(entries, & &1["path"])
      assert paths == Enum.sort(Map.keys(@fixture_files))
      assert paths == Enum.uniq(paths)

      for entry <- entries do
        assert entry["op"] == "write"
        assert safe?(entry["path"])
        assert entry["sha256"] =~ @sha256
        assert is_integer(entry["size"]) and entry["size"] >= 0

        case @fixture_files[entry["path"]] do
          {:symlink, target} ->
            assert Enum.sort(Map.keys(entry)) ==
                     ["kind", "mode", "op", "path", "sha256", "size", "target"]

            assert %{"kind" => "symlink", "mode" => "120000", "target" => ^target} = entry
            refute target == "" or String.starts_with?(target, "/")
            assert entry["size"] == byte_size(target) and entry["sha256"] == sha256(target)

          content ->
            assert Enum.sort(Map.keys(entry)) == ["kind", "mode", "op", "path", "sha256", "size"]
            assert entry["kind"] == "file" and entry["mode"] in ["100644", "100755"]
            assert entry["size"] == byte_size(content) and entry["sha256"] == sha256(content)
        end
      end

      # What the import fetches (import.ex:226-243): every file entry's blob with its declared
      # size, counted per entry; each is in the fixture, served by Bases and nameable by a lease.
      files =
        for %{"op" => "write", "kind" => "file", "sha256" => sha, "size" => size} <- entries,
            into: %{},
            do: {sha, size}

      file_bytes =
        for %{"op" => "write", "kind" => "file", "size" => size} <- entries, reduce: 0 do
          sum -> sum + size
        end

      assert {length(entries), file_bytes} == {8, 49}
      assert Enum.sort(Map.keys(files)) == Enum.sort(File.ls!(Path.join(@fixture, "blobs")))
      {:ok, names} = Bases.names(base.manifest, context.name)

      for {sha, size} <- files do
        assert {:ok, ^size, blob} = Bases.blob(sha, base.snapshot_id, context.name)
        assert Enum.join(blob) == File.read!(Path.join([@fixture, "blobs", sha]))
        assert sha in names
      end
    end
  end

  # The validator's path rule, its safe (snapshot.go:515-531): UTF-8, relative,
  # normalized, no backslash, DEL or control character, no ".git" segment in any case.
  defp safe?(path) do
    String.valid?(path) and not String.contains?(path, ["\\", "\x7f"]) and
      not Enum.any?(:binary.bin_to_list(path), &(&1 < 0x20)) and
      Enum.all?(
        String.split(path, "/"),
        &(&1 not in ["", ".", ".."] and String.downcase(&1) != ".git")
      )
  end

  describe "names and blobs" do
    test "names: the manifest blob and every write entry's sha256", context do
      start_bases(context)
      base = ready(context)

      assert Bases.names(base.manifest, context.name) ==
               {:ok, MapSet.new([base.manifest, sha256(@readme), sha256(@run), sha256(@large)])}

      assert Bases.names(sha256("no manifest"), context.name) == :not_found
    end

    test "names leave out every entry that is not a write" do
      document = %{
        "roots" => [
          %{
            "root" => "app",
            "entries" => [
              %{"op" => "write", "path" => "a", "sha256" => "aa"},
              %{"op" => "delete", "path" => "b", "sha256" => "bb"},
              %{"path" => "c", "sha256" => "cc"}
            ]
          }
        ]
      }

      assert Bases.names_of("mm", document) == MapSet.new(["mm", "aa"])
    end

    test "blobs are read through from Code, in chunks; an unknown sha is not_found", context do
      start_bases(context)
      base = ready(context)

      assert {:ok, size, stream} = Bases.blob(sha256(@large), base.snapshot_id, context.name)
      assert size == byte_size(@large)
      refute is_binary(stream) or is_list(stream)
      chunks = Enum.to_list(stream)
      assert length(chunks) > 1
      assert IO.iodata_to_binary(chunks) == @large

      assert {:ok, _, readme} = Bases.blob(sha256(@readme), base.snapshot_id, context.name)
      assert Enum.join(readme) == @readme

      assert Bases.blob(sha256("unknown"), base.snapshot_id, context.name) == :not_found

      # The manifest blob belongs to its own snapshot only.
      assert Bases.blob(base.manifest, "sha256:" <> String.duplicate("0", 64), context.name) ==
               :not_found
    end
  end

  describe "pinned by snapshot (M3 A4)" do
    defp bytes(context, sha, snapshot_id) do
      assert {:ok, size, stream} = Bases.blob(sha, snapshot_id, context.name)
      content = IO.iodata_to_binary(Enum.to_list(stream))
      assert byte_size(content) == size
      content
    end

    # The branch moves on: develop now names another revision with other files.
    defp move(fake),
      do:
        FakeCode.put(fake, @repository, "develop", "rev_2", %{
          "README.md" => "moved\n",
          "bin/run" => "#!/bin/sh\necho moved\n"
        })

    test "after a restart, a lease's base is restored from its snapshot id, byte for byte, the branch moved",
         context do
      start_bases(context)
      base = ready(context)
      manifest = bytes(context, base.manifest, base.snapshot_id)
      readme = bytes(context, sha256(@readme), base.snapshot_id)
      run = bytes(context, sha256(@run), base.snapshot_id)

      move(context.fake)
      stop_supervised!(context.name)
      start_bases(context)
      assert Bases.names(base.manifest, context.name) == :not_found
      resolved = count(context.fake, :resolve_reference)
      snapshotted = count(context.fake, :create_snapshot)

      assert :ok = Bases.restore(@repository, base.snapshot_id, base.manifest, context.name)
      settle(context, fn -> match?({:ok, _}, Bases.names(base.manifest, context.name)) end)

      # The same base: its manifest blob and its files, as they were before the move.
      assert {:ok, names} = Bases.names(base.manifest, context.name)
      assert names == Bases.names_of(base.manifest, JSON.decode!(manifest))
      assert bytes(context, base.manifest, base.snapshot_id) == manifest
      assert bytes(context, sha256(@readme), base.snapshot_id) == readme
      assert bytes(context, sha256(@run), base.snapshot_id) == run

      # From the snapshot id alone: no reference resolved, no snapshot made.
      assert count(context.fake, :resolve_reference) == resolved
      assert count(context.fake, :create_snapshot) == snapshotted
      assert Bases.cached(@repository, "develop", context.name) == :missing

      # The branch did move: a fresh request gives another base.
      assert ready(context).manifest != base.manifest

      # Restored again (it is held): nothing more is asked of Code.
      calls = length(FakeCode.calls(context.fake))
      assert :ok = Bases.restore(@repository, base.snapshot_id, base.manifest, context.name)
      :sys.get_state(context.name)
      assert length(FakeCode.calls(context.fake)) == calls
    end

    test "a snapshot that does not give the lease's manifest is not kept", context do
      start_bases(context)
      base = ready(context)
      stop_supervised!(context.name)
      start_bases(context)
      other = String.duplicate("0", 64)

      assert :ok = Bases.restore(@repository, base.snapshot_id, other, context.name)
      # Its task answered, and nothing waits for a retry.
      settle(context, fn -> :sys.get_state(context.name).pending == %{} end)
      assert Bases.names(other, context.name) == :not_found
      assert Bases.names(base.manifest, context.name) == :not_found
    end

    test "Code failing: the restore is tried again after 30 s", context do
      start_bases(context)
      base = ready(context)
      stop_supervised!(context.name)
      start_bases(context)
      FakeCode.mode(context.fake, :failing)

      assert :ok = Bases.restore(@repository, base.snapshot_id, base.manifest, context.name)
      # Its task answered: the restore waits for its retry.
      settle(context, fn ->
        match?([%{status: :waiting}], Map.values(:sys.get_state(context.name).pending))
      end)

      assert Bases.names(base.manifest, context.name) == :not_found

      FakeCode.mode(context.fake, :ok)
      ManualClock.advance(context.clock, 30_000)
      settle(context, fn -> match?({:ok, _}, Bases.names(base.manifest, context.name)) end)
      assert count(context.fake, :resolve_reference) == 1
    end

    test "with Bases not running, a restore is :ok and nothing raises", context do
      assert :ok =
               Bases.restore(
                 @repository,
                 "sha256:" <> String.duplicate("a", 64),
                 "x",
                 context.name
               )
    end
  end

  describe "no caller waits on Code" do
    test "with Code blocked, cached/3 and request/4 answer at once and never call Code",
         context do
      FakeCode.mode(context.fake, :blocked)
      start_bases(context)
      me = self()

      caller =
        Task.async(fn ->
          a = Bases.request(@repository, "develop", {me, :first}, context.name)
          b = Bases.request(@repository, "develop", {me, :second}, context.name)
          {self(), a, b, Bases.cached(@repository, "develop", context.name)}
        end)

      assert {:ok, {caller_pid, :ok, :ok, :missing}} = Task.yield(caller, 1_000)

      # One resolution for both requests, waiting on Code in a process of its own.
      settle(context, fn -> FakeCode.blocked(context.fake) == 1 end)
      assert Bases.cached(@repository, "develop", context.name) == :missing
      callers = context.fake |> FakeCode.calls() |> Enum.map(&elem(&1, 1))
      refute caller_pid in callers
      refute self() in callers
      refute Process.whereis(context.name) in callers

      FakeCode.mode(context.fake, :ok)
      FakeCode.release(context.fake)
      assert_receive :first, 2_000
      assert_receive :second, 2_000
      assert {:ok, _base} = Bases.cached(@repository, "develop", context.name)
      assert count(context.fake, :resolve_reference) == 1
      refute Enum.any?(FakeCode.calls(context.fake), &(elem(&1, 1) in [caller_pid, self()]))
    end

    test "Code slower than 15 s: unavailable, retried after 30 s, then notified", context do
      FakeCode.mode(context.fake, :blocked)
      start_bases(context)
      :ok = Bases.request(@repository, "develop", {self(), :ready}, context.name)
      settle(context, fn -> FakeCode.blocked(context.fake) == 1 end)

      ManualClock.advance(context.clock, 14_999)
      :sys.get_state(context.name)
      assert Bases.cached(@repository, "develop", context.name) == :missing

      ManualClock.advance(context.clock, 1)

      settle(context, fn -> Bases.cached(@repository, "develop", context.name) == :unavailable end)

      FakeCode.mode(context.fake, :ok)
      ManualClock.advance(context.clock, 30_000)
      assert_receive :ready, 2_000
      assert {:ok, _base} = Bases.cached(@repository, "develop", context.name)
    end

    test "Code failing: unavailable, retried after 30 s with every notify kept", context do
      FakeCode.mode(context.fake, :failing)
      start_bases(context)
      :ok = Bases.request(@repository, "develop", {self(), :first}, context.name)

      settle(context, fn -> Bases.cached(@repository, "develop", context.name) == :unavailable end)

      calls = length(FakeCode.calls(context.fake))

      # A request while waiting for the retry only waits too: Code is not asked again.
      :ok = Bases.request(@repository, "develop", {self(), :second}, context.name)
      :sys.get_state(context.name)
      assert length(FakeCode.calls(context.fake)) == calls

      FakeCode.mode(context.fake, :ok)
      ManualClock.advance(context.clock, 29_999)
      :sys.get_state(context.name)
      assert length(FakeCode.calls(context.fake)) == calls
      refute_received :first

      ManualClock.advance(context.clock, 1)
      assert_receive :first, 2_000
      assert_receive :second, 2_000
      assert {:ok, _base} = Bases.cached(@repository, "develop", context.name)
    end

    test "with Bases not running: unavailable, and nothing raises", context do
      assert Bases.cached(@repository, "develop", context.name) == :unavailable
      assert Bases.request(@repository, "develop", {self(), :ready}, context.name) == :ok
      assert Bases.names(sha256("x"), context.name) == :not_found
      assert Bases.blob(sha256("x"), "sha256:" <> sha256("y"), context.name) == :unavailable
      refute_received :ready
    end
  end
end
