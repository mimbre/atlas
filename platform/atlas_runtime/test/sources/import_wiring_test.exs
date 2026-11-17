defmodule AtlasRuntime.Sources.ImportWiringTest do
  @moduledoc """
  M2 A3, the base import's wiring (decision §3 "Inputs (F6)", §5.1; W5's
  `AtlasRuntime.Sources.Import` in the puller): before a lease is accepted, the puller
  imports its input from the source that offered it, every blob through that source's
  `get_blob`, into its own store, the base through the real `workspace base-import`. The
  work then runs on the imported tree, composed by the helper from the imported baseline
  plus exactly the imported change set, without Code (no Code stand-in runs here). An
  import the input is refused for (too large, invalid, over the source's quota) is reported
  `refused` and creates no work record.
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

  defp sources(max_store_bytes),
    do: %{
      "sources" => [
        %{
          "name" => @name,
          "kind" => "remote",
          "url" => "https://flow-test.example/",
          "credential_file" => "sources/flow-test/token",
          "priority" => 1,
          "max_slots" => 2,
          "max_store_bytes" => max_store_bytes
        }
      ]
    }

  setup context do
    bench = start!(sources(Map.get(context, :max_store_bytes, 2_147_483_648)))
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
         import: Map.get(context, :import, [])}
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

  defp assert_refused(ctx, reason) do
    assert :polled = Puller.poll_now(ctx.puller)
    assert [%S.Refused{reason: ^reason}] = reports(ctx.source, "task-1")
    assert Work.holdings(@name) == []
    assert works(ctx.bench) == []
    assert %B.Outcome.Works{works: []} = B.list_work(@client, %{})
  end

  test "a leased base work runs on the imported tree: its blobs from this source, no Code",
       ctx do
    {manifest, blobs} = Source.base(@files)
    Source.add_work(ctx.source, offered(%{base: %{base_id: "b-1", manifest: manifest}}), blobs)

    {work_id, record} = run!(ctx)

    # The baseline the input was imported into, never the source's own base_id.
    assert %M.Base{base_id: "sha256:" <> _ = baseline} = record.request.workspace
    assert %M.Imported{source: @name, change_set: nil} = record.imported
    assert tree(ctx.bench, work_id) == @files

    # Every blob came from this source, through this lease, into this source's store.
    lease_id = Source.current(ctx.source, "task-1")

    assert Enum.sort(Source.served(ctx.source)) ==
             Enum.sort(for sha <- Map.keys(blobs), do: {lease_id, sha})

    for sha <- Map.keys(blobs), do: assert(Store.has?(ctx.bench.dir, @name, sha))

    assert File.exists?(
             Path.join([ctx.bench.dir, "snapshots", String.trim_leading(baseline, "sha256:")])
           )

    assert [%S.Accepted{}, %S.Started{}, %S.Ended{result: %{kind: :completed}}] =
             reports(ctx.source, "task-1")
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

  describe "a refused import is reported refused and creates no work" do
    @tag import: [max_base_bytes: 4]
    test "too large: the base's declared bytes are past the cap", ctx do
      {manifest, blobs} = Source.base(@files)
      Source.add_work(ctx.source, offered(%{base: %{base_id: "b-1", manifest: manifest}}), blobs)
      assert_refused(ctx, :too_large)
    end

    test "invalid: the validator refuses the base (an unsafe path)", ctx do
      {manifest, blobs} = Source.base(%{"../escape" => "x\n"})
      Source.add_work(ctx.source, offered(%{base: %{base_id: "b-1", manifest: manifest}}), blobs)
      assert_refused(ctx, :invalid)
    end

    @tag max_store_bytes: 16
    test "quota: the source's store would pass max_store_bytes", ctx do
      {manifest, blobs} = Source.base(@files)
      Source.add_work(ctx.source, offered(%{base: %{base_id: "b-1", manifest: manifest}}), blobs)
      assert_refused(ctx, :too_large)
    end
  end
end
