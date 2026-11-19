defmodule AtlasRuntime.Work.FrozenTest do
  @moduledoc """
  S5a P7b (s5a-plan B8–B11; design §3.9 "Freezing"): a `completed` attempt of a `base` work,
  or of a socket client's `folder{materialized-folder}` with a materialization record, is
  frozen as part of the `completed` write. The change set comes from the real helper
  (`snapshot changes`) and its fingerprints from `AtlasChangeset` only. A freeze that is
  refused ends the attempt `failed: workspace`.
  """
  use ExUnit.Case, async: false

  import AtlasRuntime.WorkHarness

  import AtlasRuntime.CodeStandIn,
    only: [base_request: 2, submit_base!: 2, submit_base!: 3, expected_folder: 2]

  alias AtlasRuntime.Boundary.Work, as: F
  alias AtlasRuntime.CodeStandIn
  alias AtlasRuntime.Model.Work, as: M
  alias AtlasRuntime.Work.{Folders, Frozen, FrozenStore, Store}

  @moduletag capture_log: true

  @files %{"README.md" => "base\n", "run.sh" => "echo run\n", "old.md" => "old\n"}

  setup do
    bench = start!()
    code = CodeStandIn.start!(bench.dir, @files)
    on_exit(fn -> CodeStandIn.stop(code, bench.dir) end)
    %{bench: bench, code: code}
  end

  defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  # A folder for a socket client's materialized folder: outside the Runtime home, as the
  # helper requires.
  defp outside_home do
    folder =
      Path.join(
        System.tmp_dir!(),
        "p7b-#{Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)}"
      )

    File.mkdir_p!(folder)
    on_exit(fn -> System.cmd("/bin/chmod", ["-R", "u+w", folder]) && File.rm_rf!(folder) end)
    Folders.real(folder)
  end

  defp frozen_files(bench), do: Path.wildcard(Path.join([bench.dir, "frozen", "*.json"]))

  defp record_path(dir, folder),
    do: Path.join([dir, "materializations", "#{sha(folder)}.json"])

  # The fingerprints AtlasChangeset gives the stored change set, as the boundary lists them.
  defp library_fingerprints(frozen) do
    for %{root: root, fingerprint: fingerprint} <-
          AtlasChangeset.fingerprints(Frozen.change_set(frozen)),
        do: %F.RootFingerprint{root: root, fingerprint: fingerprint}
  end

  test "a completed base work is frozen: its writes, mode change, symlink and delete, relative to base_id",
       %{bench: bench, code: code} do
    work =
      submit_base!(
        code,
        "write docs/é.txt hello world; chmod run.sh 755; " <>
          "symlink link README.md; delete old.md"
      )

    [attempt] = await_state(work.work_id, :completed).attempts
    folder = expected_folder(bench.dir, work.work_id)

    assert %F.WorkProduct{workspace: workspace, frozen: frozen_ref} = attempt.result.work_product
    assert %{path: ^folder, changed: true} = workspace
    assert frozen_ref.base == code.id

    frozen = FrozenStore.get(bench.dir, work.work_id, 1)
    assert %{base: base, work_id: id, attempt: 1, pruned: false} = frozen
    assert base == code.id and id == work.work_id
    assert frozen_ref.fingerprints == library_fingerprints(frozen)

    assert [%{root: "atlas", entries: entries, fingerprint: "csf_" <> hex}] = frozen.roots
    assert hex =~ ~r/\A[0-9a-f]{64}\z/
    text = "hello world\n"
    run = "echo run\n"

    assert [
             %{path: "docs/é.txt", op: :write, kind: :file, mode: "100644", size: 12} = written,
             %{path: "link", op: :write, kind: :symlink, mode: "120000", target: "README.md"} =
               link,
             %{path: "old.md", op: :delete, kind: nil, sha256: nil},
             %{path: "run.sh", op: :write, kind: :file, mode: "100755"} = executable
           ] = entries

    assert byte_size(text) == written.size
    assert written.sha256 == sha(text)
    assert link.sha256 == sha("README.md") and link.size == 9
    assert executable.sha256 == sha(run)

    # Each file's blob is in the store under its sha256, read-only, with that content.
    for {entry, content} <- [{written, text}, {executable, run}] do
      blob = FrozenStore.blob_path(bench.dir, entry.sha256)
      assert File.read!(blob) == content
      assert sha(File.read!(blob)) == entry.sha256
      assert {:ok, %{mode: mode}} = File.stat(blob)
      assert Bitwise.band(mode, 0o777) == 0o444
    end

    # The private record is never projected; only base and fingerprints are public.
    refute Map.has_key?(Map.from_struct(frozen_ref), :roots)
  end

  test "each attempt has its own frozen result; a fresh retry's rebuild leaves attempt 1's unchanged",
       %{bench: bench, code: code} do
    work = submit_base!(code, "write first.txt one")
    await_state(work.work_id, :completed)
    first = File.read!(FrozenStore.path(bench.dir, work.work_id, 1))

    assert %F.Outcome.Accepted{} = F.retry(client(), %{work_id: work.work_id})
    done = await_work(work.work_id, &match?([_, %{state: :completed}], &1.attempts))
    [one, two] = done.attempts
    assert File.read!(FrozenStore.path(bench.dir, work.work_id, 1)) == first
    assert one.result.work_product.frozen == two.result.work_product.frozen
    assert %{attempt: 2, frozen_id: frozen_id} = FrozenStore.get(bench.dir, work.work_id, 2)
    assert frozen_id == work.work_id <> ".2"
    assert CodeStandIn.archives(code) == ["atlas", "atlas"]
  end

  test "a read-only base work is frozen too: every baseline root, with entries [] when unchanged",
       %{bench: bench, code: code} do
    work = submit_base!(code, "complete read only", "read-only")
    [attempt] = await_state(work.work_id, :completed).attempts
    assert %F.WorkProduct{workspace: %{changed: false}, frozen: ref} = attempt.result.work_product

    assert [%{root: "atlas", entries: [], fingerprint: fingerprint}] =
             FrozenStore.get(bench.dir, work.work_id, 1).roots

    assert ref.fingerprints == [%F.RootFingerprint{root: "atlas", fingerprint: fingerprint}]
    assert fingerprint == AtlasChangeset.fingerprint(code.id, "atlas", [])
  end

  test "the completed commit is written only once the frozen record is on disk", %{
    bench: bench,
    code: code
  } do
    test = self()
    dir = bench.dir

    hook = fn record ->
      for %{state: :completed, attempt: n} <- record.attempts,
          do: send(test, {:completed, n, File.exists?(FrozenStore.path(dir, record.work_id, n))})
    end

    stop_work()
    start_work!(bench, after_write: hook)
    work = submit_base!(code, "write ordered.txt first")
    await_state(work.work_id, :completed)
    assert_received {:completed, 1, true}
    refute_received {:completed, 1, false}
  end

  test "a crash between the frozen write and the commit: after restart the attempt is interrupted and the orphan is gone",
       %{bench: bench, code: code} do
    test = self()

    stop_work()

    start_work!(bench,
      freeze_hook: fn frozen ->
        send(test, {:frozen, frozen.frozen_id, self()})
        Process.exit(self(), :kill)
      end
    )

    work = submit_base!(code, "write crash.txt cut off")
    assert_receive {:frozen, frozen_id, core}, 10_000
    orphan = Path.join([bench.dir, "frozen", frozen_id <> ".json"])
    assert File.exists?(orphan)
    # The crash came before the commit: the record never said completed.
    assert AtlasTestAwait.down(core) in [:killed, :noproc]
    assert [%{state: :running}] = Store.read_work(bench.dir, work.work_id).attempts

    start_work!(bench)
    [attempt] = await_state(work.work_id, :interrupted).attempts
    assert attempt.result.retryable
    assert attempt.result.work_product == nil
    refute File.exists?(orphan)
    assert frozen_files(bench) == []
  end

  test "a change outside every root fails the attempt (workspace), with its answer and no frozen result",
       %{bench: bench, code: code} do
    work = submit_base!(code, "write ../outside.txt not in a root")
    [attempt] = await_state(work.work_id, :failed).attempts
    assert %{kind: :failed, reason: :workspace, retryable: false} = attempt.result
    assert attempt.result.answer == "done: write ../outside.txt not in a root"
    assert attempt.result.log.ref == attempt.turn_id
    assert attempt.result.work_product == nil
    assert frozen_files(bench) == []
  end

  test "a base folder whose materialization record is gone before the turn ends fails (workspace)",
       %{bench: bench, code: code} do
    gate = Path.join(bench.dir, "gate-base")
    File.write!(gate, "")
    work = submit_base!(code, "wait gate-base")
    await_launch(bench, work)
    File.rm!(record_path(bench.dir, expected_folder(bench.dir, work.work_id)))
    File.rm!(gate)

    [attempt] = await_state(work.work_id, :failed).attempts
    assert %{kind: :failed, reason: :workspace, retryable: false} = attempt.result
    assert attempt.result.work_product == nil
    assert frozen_files(bench) == []
  end

  test "the socket form: a folder{materialized-folder} that snapshot materialize made is frozen against its record",
       %{bench: bench, code: code} do
    dest = Path.join(outside_home(), "materialized")

    assert {_, 0} =
             System.cmd(
               System.fetch_env!("ATLAS_RUNTIME_EXECUTABLE"),
               ["snapshot", "materialize", "--snapshot", code.id, "--dest", dest],
               env: [{"ATLAS_RUNTIME_HOME", bench.dir}],
               stderr_to_stdout: true
             )

    request =
      base_request(code, "write socket.txt from a socket client")
      |> Map.put(:workspace, %{kind: "folder", path: dest, permissions: "materialized-folder"})

    assert %F.Outcome.Accepted{work: work} = F.submit(client(), request)
    [attempt] = await_state(work.work_id, :completed).attempts
    assert %F.WorkProduct{workspace: %{path: ^dest}, frozen: ref} = attempt.result.work_product
    assert ref.base == code.id
    frozen = FrozenStore.get(bench.dir, work.work_id, 1)
    assert [%{root: "atlas", entries: [%{path: "socket.txt", op: :write}]}] = frozen.roots
    assert ref.fingerprints == library_fingerprints(frozen)
  end

  test "a socket folder whose record is gone completes without frozen", %{
    bench: bench,
    code: code
  } do
    dest = Path.join(outside_home(), "unrecorded")

    assert {_, 0} =
             System.cmd(
               System.fetch_env!("ATLAS_RUNTIME_EXECUTABLE"),
               ["snapshot", "materialize", "--snapshot", code.id, "--dest", dest],
               env: [{"ATLAS_RUNTIME_HOME", bench.dir}],
               stderr_to_stdout: true
             )

    gate = Path.join(bench.dir, "gate-socket")
    File.write!(gate, "")

    request =
      base_request(code, "wait gate-socket")
      |> Map.put(:workspace, %{kind: "folder", path: dest, permissions: "materialized-folder"})

    assert %F.Outcome.Accepted{work: work} = F.submit(client(), request)
    await_launch(bench, work)
    File.rm!(record_path(bench.dir, dest))
    File.rm!(gate)
    [attempt] = await_state(work.work_id, :completed).attempts
    assert attempt.result.work_product == nil
    assert frozen_files(bench) == []
  end

  test "a plain folder{workspace-write} work completes without frozen; a repository work is never frozen",
       %{bench: bench} do
    File.mkdir_p!(Path.join(bench.workspace, "plain"))

    work =
      submit!(bench, "complete plain", %{
        workspace: %{
          kind: "folder",
          path: Path.join(bench.workspace, "plain"),
          permissions: "workspace-write"
        }
      })

    [attempt] = await_state(work.work_id, :completed).attempts
    assert attempt.result.work_product == nil
    assert frozen_files(bench) == []

    # The core refuses a repository work at submit today (unsupported_workspace), so this is
    # the freeze rule itself: never frozen, and the helper is never asked.
    repository =
      M.WorkRecord.new!(
        work_id: "work-0123456789abcdef",
        client: "c1",
        idempotency_key: "k",
        revision: 1,
        sequence: 1,
        request:
          M.Request.new!(
            title: "r",
            instructions: "r",
            profile: "light_work",
            cost_class: :standard,
            workspace: M.Repository.new!(url: "https://example.invalid/r.git", branch: "b")
          ),
        attempts: []
      )

    assert Frozen.kind(repository) == :never

    assert Frozen.freeze(bench.dir, repository, %{attempt: 1, folder: "/x"}, "/x",
             changes: fn _, _ -> flunk("the helper was asked") end
           ) == :not_frozen

    for permissions <- [:read_only, :workspace_write],
        do: assert(Frozen.kind(M.Folder.new!(path: "/x", permissions: permissions)) == :never)
  end

  test "failed, crashed and cancelled attempts are not frozen", %{bench: bench, code: code} do
    failed = submit_base!(code, "write failed.txt x; fail")
    [attempt] = await_state(failed.work_id, :failed).attempts
    assert attempt.result.work_product == nil

    cancelled = submit_base!(code, "write cancelled.txt x; hang")
    await_launch(bench, cancelled)

    await(fn ->
      File.exists?(
        Path.join(expected_folder(bench.dir, cancelled.work_id), "atlas/cancelled.txt")
      )
    end)

    assert %F.Outcome.Cancelling{} =
             F.cancel(client(), %{work_id: cancelled.work_id, mode: "force"})

    [attempt] = await_state(cancelled.work_id, :cancelled).attempts
    assert attempt.result.work_product == nil

    # The Service's native process dies under the turn: the attempt is crashed.
    crashed = submit_base!(code, "write crashed.txt x; hang")
    await_launch(bench, crashed)
    folder = expected_folder(bench.dir, crashed.work_id)
    await(fn -> File.exists?(Path.join(folder, "atlas/crashed.txt")) end)

    for pid <- Process.list(),
        {:dictionary, dictionary} <- [Process.info(pid, :dictionary)],
        dictionary[:"$initial_call"] == {AtlasRuntime.Agent.Native, :init, 1},
        do: Process.exit(pid, :kill)

    [attempt] = await_state(crashed.work_id, :crashed).attempts
    assert attempt.result.work_product == nil

    assert frozen_files(bench) == []
  end

  describe "the change set from the helper's output" do
    @base "sha256:" <> String.duplicate("0", 64)
    @blob String.duplicate("a", 64)

    defp record do
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
            workspace: M.Base.new!(base_id: @base, permissions: :workspace_write)
          ),
        attempts: []
      )
    end

    test "the fingerprint is AtlasChangeset's over the entries sorted by path, whatever order the helper gives" do
      write = %{
        "path" => "a.txt",
        "op" => "write",
        "kind" => "file",
        "mode" => "100644",
        "size" => 3,
        "sha256" => @blob
      }

      delete = %{"path" => "b.md", "op" => "delete"}

      output = %{
        "snapshot_id" => @base,
        "roots" => [%{"root" => "atlas", "entries" => [delete, write]}],
        "outside" => []
      }

      assert {:ok, frozen} = Frozen.build(output, record(), 1, ~U[2026-11-17 09:00:00.000Z])
      [%{fingerprint: fingerprint, entries: [%{path: "a.txt"}, %{path: "b.md"}]}] = frozen.roots

      # §3.9's canonical form, written out by hand: keys and entries in byte order.
      canonical =
        ~s({"base":"#{@base}","entries":[{"kind":"file","mode":"100644","op":"write","path":"a.txt",) <>
          ~s("sha256":"#{@blob}","size":3},{"op":"delete","path":"b.md"}],"root":"atlas"})

      assert fingerprint == "csf_" <> sha(canonical)
      assert fingerprint == AtlasChangeset.fingerprint(@base, "atlas", [write, delete])
    end

    test "outside changes, an invalid entry and another base are refused" do
      at = ~U[2026-11-17 09:00:00.000Z]

      ok = %{
        "snapshot_id" => @base,
        "roots" => [%{"root" => "atlas", "entries" => []}],
        "outside" => []
      }

      assert {:error, "changes outside every root" <> _} =
               Frozen.build(%{ok | "outside" => ["x.txt"]}, record(), 1, at)

      bad = %{"path" => "../x", "op" => "delete"}

      assert {:error, "invalid change set" <> _} =
               Frozen.build(
                 %{ok | "roots" => [%{"root" => "atlas", "entries" => [bad]}]},
                 record(),
                 1,
                 at
               )

      other = "sha256:" <> String.duplicate("1", 64)

      assert {:error, "the folder is recorded as" <> _} =
               Frozen.build(%{ok | "snapshot_id" => other}, record(), 1, at)
    end
  end
end
