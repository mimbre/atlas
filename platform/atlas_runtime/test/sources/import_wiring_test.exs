defmodule AtlasRuntime.Sources.ImportWiringTest do
  @moduledoc """
  M2 A3, the base import's wiring (decision §3 "Inputs (F6)", §5.1; W5's
  `AtlasRuntime.Sources.Import` in the puller): once a lease is accepted and that accept
  recorded (accept first, Main's #330 F5 (b)), the puller imports its input from the source
  that offered it, every blob through that source's `get_blob`, into its own store, the base
  through the real `workspace base-import`. The work then runs on the imported tree,
  composed by the helper from the imported baseline plus exactly the imported change set,
  without Code (no Code stand-in runs here). An import the input is refused for (too
  large, invalid, over the source's quota) ends the accepted attempt `failed` (never
  started, reason `workspace`), reported `ended`; nothing is materialized or launched.
  """
  use ExUnit.Case, async: false

  import AtlasRuntime.WorkHarness

  alias AtlasRuntime.Boundary.Work, as: B
  alias AtlasRuntime.Model.Work, as: M
  alias AtlasRuntime.Sources.{Puller, Rights, Store}
  alias AtlasRuntime.Test.{FakeSourceTarget, ImportedBase}
  alias AtlasRuntime.Test.FakeWorkSource, as: Source
  alias AtlasRuntime.Test.WorkSourceFacade, as: S
  alias AtlasRuntime.Work
  alias AtlasRuntime.Work.Folders

  @moduletag capture_log: true

  @name "flow-test"
  @client Rights.client(@name)
  @files %{"README.md" => "imported base\n", "lib/a.ex" => "defmodule A, do: nil\n"}

  defp sources(max_store_bytes, extra),
    do: %{
      "sources" => [
        Map.merge(
          %{
            "name" => @name,
            "kind" => "remote",
            "url" => "https://flow-test.example/",
            "credential_file" => "sources/flow-test/token",
            "priority" => 1,
            "max_slots" => 2,
            "max_store_bytes" => max_store_bytes
          },
          extra
        )
      ]
    }

  setup context do
    bench =
      start!(sources(Map.get(context, :max_store_bytes, 2_147_483_648), context[:source] || %{}))

    source = Source.start(name: @name)
    Source.use(source)
    target = FakeSourceTarget.new(source)

    puller =
      start_supervised!(
        {Puller,
         name: @name,
         target: target,
         tick: :manual,
         polling: :manual,
         import: [git: Source.git(source)] ++ Map.get(context, :import, [])}
      )

    %{bench: bench, source: source, target: target, puller: puller}
  end

  defp offered(input, instructions \\ "complete"),
    do: %{
      work_key: "task-1",
      title: "task-1",
      instructions: instructions,
      profile: "light_work",
      cost_class: :standard,
      input: Map.put(input, :permissions, :"workspace-write")
    }

  defp reports(source, key) do
    case Source.current(source, key) do
      nil -> []
      id -> Agent.get(source, & &1.leases[id].reports)
    end
  end

  defp works(bench), do: Path.wildcard(Path.join(bench.dir, "work/work-*.json"))

  # The run's work: polled, accepted, recorded, released, run to its quiescent end.
  defp run!(ctx) do
    assert :polled = Puller.poll_now(ctx.puller)
    assert [%{work_id: work_id}] = Work.holdings(@name)
    await_work(work_id, &(&1.state == :completed and hd(&1.attempts).quiescent), @client)
    # Reported started and ended, the result uploaded.
    assert :ok = Puller.check_now(ctx.puller)
    {work_id, AtlasRuntime.Work.Store.read_work(ctx.bench.dir, work_id)}
  end

  defp tree(bench, work_id) do
    folder = Folders.path(bench.dir, work_id)

    for path <- Path.wildcard(Path.join(folder, "atlas/**"), match_dot: true),
        File.regular?(path),
        into: %{},
        do: {Path.relative_to(path, Path.join(folder, "atlas")), File.read!(path)}
  end

  # Accepted first, then the import refused: the attempt ends failed, never started, and
  # that end is reported; nothing was materialized or launched.
  defp assert_import_refused(ctx) do
    assert :polled = Puller.poll_now(ctx.puller)

    assert [
             %S.Accepted{},
             %S.Ended{result: %{kind: :failed, reason: :workspace, never_started: true}}
           ] = reports(ctx.source, "task-1")

    assert [%{work_id: work_id, state: :failed, held: false, ran: false}] = Work.holdings(@name)
    assert [_one] = works(ctx.bench)

    assert [%{result: %{kind: :failed, never_started: true}} = attempt] =
             AtlasRuntime.Work.Store.read_work(ctx.bench.dir, work_id).attempts

    assert is_nil(attempt.timestamps.running_at)
    refute File.exists?(Folders.path(ctx.bench.dir, work_id))
    assert launches(ctx.bench) == []
  end

  test "a leased base work runs on the imported tree: its blobs from this source",
       ctx do
    {manifest, blobs} = Source.base(@files)
    Source.add_work(ctx.source, offered(%{base: %{base_id: "b-1", manifest: manifest}}), blobs)

    {work_id, record} = run!(ctx)

    # The baseline the input was imported into, never the source's own base_id.
    assert %M.Base{base_id: "sha256:" <> _ = baseline} = record.request.workspace
    assert %M.Imported{source: @name, change_set: nil} = record.imported
    assert tree(ctx.bench, work_id) == @files

    # The manifest came from this source through this lease, the files over Git from its Code;
    # every blob is in this source's store.
    lease_id = Source.current(ctx.source, "task-1")
    assert Source.served(ctx.source) == [{lease_id, manifest}]

    for sha <- Map.keys(blobs), do: assert(Store.has?(ctx.bench.dir, @name, sha))

    assert File.exists?(
             Path.join([ctx.bench.dir, "snapshots", String.trim_leading(baseline, "sha256:")])
           )

    assert [%S.Accepted{}, %S.Started{}, %S.Ended{result: %{kind: :completed}}] =
             reports(ctx.source, "task-1")
  end

  # K1 (work_source 0.2.0, change_set.base required): the ended report's change set names
  # the base its roots were frozen on, which is the baseline this lease's input was imported
  # into (the attempt's frozen base), and the source records it (not Rejected(:invalid)).
  test "a pulled work's ended change set carries the lease's frozen base", ctx do
    {manifest, blobs} = Source.base(@files)

    Source.add_work(
      ctx.source,
      offered(%{base: %{base_id: "b-1", manifest: manifest}}, "write a.txt alpha"),
      blobs
    )

    {work_id, record} = run!(ctx)
    assert %M.Base{base_id: "sha256:" <> _ = baseline} = record.request.workspace

    assert %B.Outcome.Frozen{base: ^baseline} =
             B.get_frozen(@client, %{work_id: work_id, attempt: 1})

    assert [%S.Accepted{}, %S.Started{}, %S.Ended{change_set: %S.ChangeSet{} = set}] =
             reports(ctx.source, "task-1")

    assert set.base == baseline
    assert [%S.ChangeRoot{root: "atlas", entries: [_ | _]}] = set.roots
  end

  test "base + change_set starts from exactly the base plus the change set", ctx do
    {manifest, blobs} = Source.base(@files)

    # The baseline the base imports into, as a source knows it from an earlier result.
    probe = Path.join(System.tmp_dir!(), "a3-probe-#{System.unique_integer([:positive])}")
    File.mkdir_p!(probe)

    on_exit(fn ->
      System.cmd("/bin/chmod", ["-R", "u+w", probe])
      File.rm_rf!(probe)
    end)

    %{baseline_id: baseline} = ImportedBase.import!(probe, "probe", @files)

    new = "new file\n"

    set = %{
      "base" => baseline,
      "roots" => [
        %{
          "root" => "atlas",
          "entries" => [
            %{
              "path" => "lib/b.ex",
              "op" => "write",
              "kind" => "file",
              "mode" => "100644",
              "size" => byte_size(new),
              "sha256" => Source.sha256(new)
            },
            %{"path" => "README.md", "op" => "delete"}
          ]
        }
      ]
    }

    bytes = JSON.encode!(set)
    cs = Source.sha256(bytes)
    fingerprints = AtlasChangeset.fingerprints(set)

    input = %{
      base: %{base_id: "b-1", manifest: manifest},
      change_set: %{manifest: cs, fingerprints: fingerprints}
    }

    Source.add_work(
      ctx.source,
      offered(input),
      blobs |> Map.put(cs, bytes) |> Map.put(Source.sha256(new), new)
    )

    {work_id, record} = run!(ctx)

    assert %M.Base{base_id: ^baseline} = record.request.workspace
    assert %M.Imported{source: @name, change_set: ^cs} = record.imported

    assert tree(ctx.bench, work_id) ==
             @files |> Map.delete("README.md") |> Map.put("lib/b.ex", new)
  end

  describe "a refused import ends the accepted lease failed, never started" do
    @tag import: [max_base_bytes: 4]
    test "too large: the base's declared bytes are past the cap", ctx do
      {manifest, blobs} = Source.base(@files)
      Source.add_work(ctx.source, offered(%{base: %{base_id: "b-1", manifest: manifest}}), blobs)
      assert_import_refused(ctx)
    end

    test "invalid: the validator refuses the base (an unsafe path)", ctx do
      {manifest, blobs} = Source.base(%{"../escape" => "x\n"})
      Source.add_work(ctx.source, offered(%{base: %{base_id: "b-1", manifest: manifest}}), blobs)
      assert_import_refused(ctx)
    end

    @tag max_store_bytes: 16
    test "quota: the source's store would pass max_store_bytes", ctx do
      {manifest, blobs} = Source.base(@files)
      Source.add_work(ctx.source, offered(%{base: %{base_id: "b-1", manifest: manifest}}), blobs)
      assert_import_refused(ctx)
    end

    # IS-Atlas-08: a job's lease (its result goes back over Git) that never started is
    # reported ended without a result, and the lease is done: nothing is pushed from the
    # work folder it never had.
    @tag import: [max_base_bytes: 4], source: %{"git_url" => "https://flow-test.example/code"}
    test "with a result_ref: reported ended without a result, the lease done", ctx do
      {manifest, blobs} = Source.base(@files)
      base = %{base_id: "b-1", manifest: manifest}

      Source.add_work(
        ctx.source,
        offered(%{base: base, result_ref: "refs/atlas/results/task-1"}),
        blobs
      )

      assert_import_refused(ctx)
      assert [%S.Accepted{}, %S.Ended{change_set: nil}] = reports(ctx.source, "task-1")
      assert [:done] = ctx.puller |> Puller.leases() |> Map.values() |> Enum.map(& &1.phase)
    end
  end
end
