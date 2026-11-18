defmodule AtlasRuntime.Work.FrozenReadTest do
  @moduledoc """
  S5a P8 (design §3.9 "Reading a frozen result"; s5a-plan B1, B13): `get_frozen` and
  `get_frozen_blob` on P7b's `base` works, through the real facade and the core.

  - `get_frozen` answers the change set with each root's fingerprint; without `attempt` the
    latest `completed` attempt; a `fingerprint` must be one root's (else
    `fingerprint_mismatch`).
  - `get_frozen_blob` streams exactly a write entry's content of that frozen result, lazily,
    in chunks of at most 64 KiB; any other sha256 is `not_found` (B13).
  - Visibility as `get_work`: another client's work is `not_found` without `read_all`.
  - D44 (designer's open item): a client without `choose_path` sees no Runtime path in a
    symlink target.
  - The reads write nothing.
  """
  use ExUnit.Case, async: false

  import AtlasRuntime.WorkHarness
  import AtlasRuntime.CodeStandIn, only: [submit_base!: 2, expected_folder: 2]

  alias AtlasRuntime.Boundary.Work, as: F
  alias AtlasRuntime.CodeStandIn
  alias AtlasRuntime.Sources.{Local, Puller}
  alias AtlasRuntime.Work.FrozenStore
  alias AtlasTestAwait, as: Await

  @moduletag capture_log: true

  @files %{"README.md" => "base\n", "old.md" => "old\n"}

  setup do
    bench = start!()
    code = CodeStandIn.start!(bench.dir, @files)
    on_exit(fn -> CodeStandIn.stop(code, bench.dir) end)
    %{bench: bench, code: code}
  end

  defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp entry(%F.Outcome.Frozen{roots: [root]}, path),
    do: Enum.find(root.entries, &(&1.path == path))

  defp bytes(%F.Outcome.Blob{content: content}),
    do: content |> Enum.to_list() |> IO.iodata_to_binary()

  # A base work whose turn waits on a gate file, so the test can edit its folder first.
  defp held!(bench, code, name) do
    gate = Path.join(bench.dir, name)
    File.write!(gate, "")
    work = submit_base!(code, "wait " <> name)
    await_launch(bench, work)
    {work, expected_folder(bench.dir, work.work_id), gate}
  end

  test "get_frozen answers the change set with each root's fingerprint, as work_product.frozen names it",
       %{code: code} do
    work =
      submit_base!(code, "write atlas/a.txt one; symlink atlas/l README.md; delete atlas/old.md")

    [attempt] = await_state(work.work_id, :completed).attempts
    %F.WorkProduct{frozen: ref} = attempt.result.work_product

    assert %F.Outcome.Frozen{work_id: id, attempt: 1, base: base, roots: [root]} =
             frozen = F.get_frozen(client(), %{work_id: work.work_id})

    assert id == work.work_id and base == code.id
    assert [%F.RootFingerprint{root: "atlas", fingerprint: fingerprint}] = ref.fingerprints
    assert %F.FrozenRoot{root: "atlas", fingerprint: ^fingerprint, entries: entries} = root

    assert [
             %F.ChangeEntry{path: "a.txt", op: :write, kind: :file, mode: :"100644", size: 4},
             %F.ChangeEntry{path: "l", op: :write, kind: :symlink, target: "README.md"},
             %F.ChangeEntry{path: "old.md", op: :delete, kind: nil, sha256: nil}
           ] = entries

    assert entry(frozen, "a.txt").sha256 == sha("one\n")

    # The fingerprint is AtlasChangeset's over exactly the entries the client reads.
    plain =
      for e <- entries do
        %{"path" => e.path, "op" => Atom.to_string(e.op)}
        |> then(fn m ->
          if e.op == :write,
            do:
              Map.merge(m, %{
                "kind" => Atom.to_string(e.kind),
                "mode" => Atom.to_string(e.mode),
                "size" => e.size,
                "sha256" => e.sha256
              }),
            else: m
        end)
        |> then(fn m -> if e.target, do: Map.put(m, "target", e.target), else: m end)
      end

    assert AtlasChangeset.fingerprint(code.id, "atlas", plain) == fingerprint

    # The same with the attempt named, and with the root's fingerprint given.
    assert ^frozen = F.get_frozen(client(), %{work_id: work.work_id, attempt: 1})

    assert ^frozen =
             F.get_frozen(client(), %{work_id: work.work_id, attempt: 1, fingerprint: fingerprint})

    assert %F.Outcome.FingerprintMismatch{} =
             F.get_frozen(client(), %{
               work_id: work.work_id,
               fingerprint: "csf_" <> String.duplicate("0", 64)
             })

    # No such attempt, no such work.
    assert %F.Outcome.NotFound{} = F.get_frozen(client(), %{work_id: work.work_id, attempt: 2})

    assert %F.Outcome.NotFound{} =
             F.get_frozen(client(), %{work_id: "work-" <> String.duplicate("0", 16)})
  end

  test "without attempt, the latest completed attempt; a live attempt has no frozen result yet",
       %{bench: bench, code: code} do
    {work, _folder, gate} = held!(bench, code, "gate-latest")
    File.rm!(gate)
    await_state(work.work_id, :completed)

    # Attempt 2 waits on the gate again: while it runs, attempt 1 is the default.
    File.write!(gate, "")
    assert %F.Outcome.Accepted{} = F.retry(client(), %{work_id: work.work_id})
    await_launch(bench, work, 2)

    assert %F.Outcome.Frozen{attempt: 1} = F.get_frozen(client(), %{work_id: work.work_id})
    assert %F.Outcome.NotFound{} = F.get_frozen(client(), %{work_id: work.work_id, attempt: 2})

    # Once it completes, it is the default; attempt 1 stays readable by number.
    File.rm!(gate)
    await_work(work.work_id, &match?([_, %{state: :completed}], &1.attempts))
    assert %F.Outcome.Frozen{attempt: 2} = F.get_frozen(client(), %{work_id: work.work_id})

    assert %F.Outcome.Frozen{attempt: 1} =
             F.get_frozen(client(), %{work_id: work.work_id, attempt: 1})
  end

  test "a work that is never frozen (a plain folder) answers not_found", %{bench: bench} do
    work = submit!(bench, "complete unfrozen")
    await_state(work.work_id, :completed)
    assert %F.Outcome.NotFound{} = F.get_frozen(client(), %{work_id: work.work_id})

    assert %F.Outcome.NotFound{} =
             F.get_frozen_blob(client(), %{work_id: work.work_id, attempt: 1, sha256: sha("x")})
  end

  test "get_frozen_blob streams a write entry's bytes; another work's blob is not_found (B13)", %{
    bench: bench,
    code: code
  } do
    one = submit_base!(code, "write atlas/one.txt first file; symlink atlas/l README.md")
    two = submit_base!(code, "write atlas/two.txt second file")
    await_state(one.work_id, :completed)
    await_state(two.work_id, :completed)

    first = F.get_frozen(client(), %{work_id: one.work_id})
    second = F.get_frozen(client(), %{work_id: two.work_id})
    written = entry(first, "one.txt")
    other = entry(second, "two.txt")

    assert %F.Outcome.Blob{sha256: sha256, size: size} =
             blob =
             F.get_frozen_blob(client(), %{
               work_id: one.work_id,
               attempt: 1,
               sha256: written.sha256
             })

    assert sha256 == written.sha256 and size == written.size
    assert bytes(blob) == "first file\n"
    assert sha(bytes(blob)) == written.sha256

    # A symlink's content is its target.
    link = entry(first, "l")
    blob = F.get_frozen_blob(client(), %{work_id: one.work_id, attempt: 1, sha256: link.sha256})
    assert bytes(blob) == "README.md" and blob.size == 9

    # The other work's blob is in the store, but it is no entry of work one.
    assert File.regular?(FrozenStore.blob_path(bench.dir, other.sha256))

    assert %F.Outcome.NotFound{} =
             F.get_frozen_blob(client(), %{work_id: one.work_id, attempt: 1, sha256: other.sha256})

    assert %F.Outcome.Blob{} =
             F.get_frozen_blob(client(), %{work_id: two.work_id, attempt: 1, sha256: other.sha256})

    for {id, n, sha256} <- [
          {one.work_id, 2, written.sha256},
          {one.work_id, 1, String.duplicate("0", 64)},
          {"work-" <> String.duplicate("0", 16), 1, written.sha256}
        ],
        do:
          assert(
            %F.Outcome.NotFound{} =
              F.get_frozen_blob(client(), %{work_id: id, attempt: n, sha256: sha256})
          )
  end

  test "without read_all, another client's frozen result is not_found; read_all widens it", %{
    code: code
  } do
    work = submit_base!(code, "write atlas/mine.txt mine")
    await_state(work.work_id, :completed)
    %F.Outcome.Frozen{} = frozen = F.get_frozen(client(), %{work_id: work.work_id})
    sha256 = entry(frozen, "mine.txt").sha256
    input = %{work_id: work.work_id, attempt: 1, sha256: sha256}

    assert %F.Outcome.NotFound{} = F.get_frozen(client("c2"), %{work_id: work.work_id})
    assert %F.Outcome.NotFound{} = F.get_frozen_blob(client("c2"), input)
    assert ^frozen = F.get_frozen(client("admin", [:read_all]), %{work_id: work.work_id})
    assert %F.Outcome.Blob{} = F.get_frozen_blob(client("admin", [:read_all]), input)
  end

  test "a 64 MiB blob is streamed in chunks of at most 64 KiB, never as one binary", %{
    bench: bench,
    code: code
  } do
    {work, folder, gate} = held!(bench, code, "gate-big")
    chunk = :crypto.strong_rand_bytes(1024 * 1024)
    big = Path.join([folder, "atlas", "big.bin"])
    File.write!(big, List.duplicate(chunk, 64))
    expected = sha(File.read!(big))
    File.rm!(gate)
    await_state(work.work_id, :completed)

    assert %F.ChangeEntry{sha256: ^expected, size: 67_108_864} =
             entry(F.get_frozen(client(), %{work_id: work.work_id}), "big.bin")

    blob = F.get_frozen_blob(client(), %{work_id: work.work_id, attempt: 1, sha256: expected})
    assert %F.Outcome.Blob{size: 67_108_864} = blob

    # The answer that crossed from the core is small: the content is read later, lazily.
    assert :erlang.external_size(blob) < 64 * 1024
    refute is_binary(blob.content)

    {digest, total, largest} =
      Enum.reduce(blob.content, {:crypto.hash_init(:sha256), 0, 0}, fn part,
                                                                       {d, total, largest} ->
        {:crypto.hash_update(d, part), total + byte_size(part), max(largest, byte_size(part))}
      end)

    assert total == 67_108_864
    assert largest <= 65_536
    assert Base.encode16(:crypto.hash_final(digest), case: :lower) == expected
  end

  # The helper refuses an absolute symlink target and one that leaves its root (P5,
  # `unsupported_entry`), so a frozen result holds no Runtime path today. The redaction is
  # the second line: the test writes absolute targets into the stored record itself.
  test "a client without choose_path sees no Runtime path in a symlink target; one with it sees the target",
       %{bench: bench, code: code} do
    names = ~w(self home alias plain elsewhere)
    work = submit_base!(code, Enum.map_join(names, "; ", &"symlink atlas/#{&1} README.md"))
    await_state(work.work_id, :completed)
    folder = expected_folder(bench.dir, work.work_id)
    home = Path.expand(bench.dir)
    real_home = Path.dirname(Path.dirname(folder))

    links = %{
      "self" => Path.join(folder, "README.md"),
      "home" => Path.join(real_home, "backend.sock"),
      "alias" => Path.join(home, "frozen/blobs"),
      "plain" => "README.md",
      "elsewhere" => "/usr/bin/env"
    }

    stored = FrozenStore.get(bench.dir, work.work_id, 1)

    roots =
      for root <- stored.roots do
        entries =
          for e <- root.entries do
            target = links[e.path]
            %{e | target: target, sha256: sha(target), size: byte_size(target)}
          end

        %{root | entries: entries}
      end

    FrozenStore.put!(bench.dir, %{stored | roots: roots})

    targets = fn client ->
      frozen = F.get_frozen(client, %{work_id: work.work_id})

      for name <- names, into: %{} do
        e = entry(frozen, name)

        content =
          bytes(F.get_frozen_blob(client, %{work_id: work.work_id, attempt: 1, sha256: e.sha256}))

        {name, {e.target, content}}
      end
    end

    # The owner without choose_path (the harness client holds it on develop, D44).
    redacted = targets.({"c1", [:submit, :cancel, :read]})
    assert redacted["self"] == {"./README.md", "./README.md"}
    assert redacted["home"] == {"<runtime-home>/backend.sock", "<runtime-home>/backend.sock"}
    assert redacted["alias"] == {"<runtime-home>/frozen/blobs", "<runtime-home>/frozen/blobs"}
    assert redacted["plain"] == {"README.md", "README.md"}
    assert redacted["elsewhere"] == {"/usr/bin/env", "/usr/bin/env"}

    for {_name, {target, content}} <- redacted do
      refute String.contains?(target, real_home) or String.contains?(target, home)
      refute String.contains?(content, real_home) or String.contains?(content, home)
    end

    # A socket client (choose_path, D44) sees the targets as stored.
    raw = targets.({"c1", [:submit, :cancel, :read, :choose_path]})
    for {name, target} <- links, do: assert(raw[name] == {target, target})
  end

  test "the reads change nothing on disk", %{bench: bench, code: code} do
    work = submit_base!(code, "write atlas/r.txt read me")
    await_work(work.work_id, &(&1.state == :completed and hd(&1.attempts).quiescent))
    # The core no longer moves: no heartbeat writes while the reads run.
    stop_work()
    start_work!(bench, heartbeat_ms: 600_000)
    await_work(work.work_id, &(&1.state == :completed))

    # Nor does the local source: its work has ended there, and its puller is idle. After the
    # core's restart the puller resends the attempt's `ended`, so the source may still hold
    # the work leased for a moment. Neither is a core notification (and the heartbeat is
    # off), so the wait wakes on what the source and its puller receive.
    Await.until(
      fn ->
        match?({:ok, %{state: :ended}}, Local.get(work.work_id)) and
          Puller.jobs(Local.puller_name()) == []
      end,
      wake: [{:trace, Local}, {:trace, Local.puller_name()}],
      label: "the local work ended at the source, its puller idle"
    )

    frozen = F.get_frozen(client(), %{work_id: work.work_id})
    sha256 = entry(frozen, "r.txt").sha256
    before = tree(bench.dir)

    for _ <- 1..5 do
      F.get_frozen(client(), %{work_id: work.work_id})

      F.get_frozen(client(), %{
        work_id: work.work_id,
        fingerprint: "csf_" <> String.duplicate("1", 64)
      })

      F.get_frozen(client("c2"), %{work_id: work.work_id})
      bytes(F.get_frozen_blob(client(), %{work_id: work.work_id, attempt: 1, sha256: sha256}))

      F.get_frozen_blob(client(), %{
        work_id: work.work_id,
        attempt: 1,
        sha256: String.duplicate("0", 64)
      })
    end

    assert tree(bench.dir) == before
  end

  test "without the core, both reads answer not_found", %{code: code} do
    work = submit_base!(code, "write atlas/s.txt stop")
    await_state(work.work_id, :completed)
    stop_work()
    assert %F.Outcome.NotFound{} = F.get_frozen(client(), %{work_id: work.work_id})

    assert %F.Outcome.NotFound{} =
             F.get_frozen_blob(client(), %{
               work_id: work.work_id,
               attempt: 1,
               sha256: String.duplicate("0", 64)
             })
  end

  # Every path under the home with its type, mode, size and content hash (files only).
  defp tree(dir) do
    for path <- Path.wildcard(Path.join(dir, "**"), match_dot: true), into: %{} do
      {:ok, stat} = File.lstat(path)

      content =
        if stat.type == :regular, do: sha(File.read!(path)), else: nil

      {Path.relative_to(path, dir), {stat.type, stat.mode, stat.size, stat.mtime, content}}
    end
  end
end
