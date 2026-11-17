defmodule AtlasRuntime.Sources.UploadTest do
  @moduledoc """
  M2 plan W6 (decision §5.2 "Result upload", §3 protection 6): `Sources.Upload` against a
  fake source that answers as the `work_source` contract does: `report(ended)` →
  `recorded(missing)` with the manifest's blobs it does not hold yet; `put_blob` fenced by
  the lease and limited to the manifest.

  - Exactly the missing blobs are uploaded, each once; an unreferenced "missing" is never
    sent.
  - No string of the Runtime home path is in any report or blob sent, whatever rights the
    caller's client holds.
  - A repeat after a restart sends the same report and uploads nothing twice.
  - `lease_lost` stops at once; `too_large` and the byte cap stop before more is sent.
  """
  use ExUnit.Case, async: false

  import AtlasRuntime.WorkHarness
  import AtlasRuntime.CodeStandIn, only: [base_request: 2, expected_folder: 2]

  alias AtlasRuntime.Boundary.Work, as: F
  alias AtlasRuntime.CodeStandIn
  alias AtlasRuntime.Sources.Upload
  alias AtlasRuntime.Work.FrozenStore

  @moduletag capture_log: true

  @files %{"README.md" => "base\n", "old.md" => "old\n"}
  # The source's fixed rights (M2 plan C1): no choose_path.
  @source_client {"source:fake", [:submit, :cancel, :read]}
  @lease "lease-0001"

  defmodule FakeSource do
    @moduledoc false
    @behaviour AtlasRuntime.Sources.Upload

    # options: stored (sha256s it holds already), also_missing (named missing although no
    # manifest entry), script (put_blob call number => :lease_lost | :too_large |
    # :crash_after_store), lease (its current lease_id).
    def start!(options \\ []) do
      {:ok, agent} =
        Agent.start_link(fn ->
          %{
            lease: Keyword.get(options, :lease, "lease-0001"),
            lost: false,
            stored: MapSet.new(Keyword.get(options, :stored, [])),
            also_missing: Keyword.get(options, :also_missing, []),
            script: Keyword.get(options, :script, %{}),
            report_answer: Keyword.get(options, :report_answer),
            referenced: MapSet.new(),
            calls: []
          }
        end)

      agent
    end

    def calls(agent), do: agent |> Agent.get(& &1.calls) |> Enum.reverse()
    def puts(agent), do: for({:put_blob, blob} <- calls(agent), do: blob)
    def reports(agent), do: for({:report, report} <- calls(agent), do: report)
    def stored(agent), do: Agent.get(agent, & &1.stored)

    @impl true
    def report(agent, report) do
      Agent.get_and_update(agent, fn state ->
        state = %{state | calls: [{:report, report} | state.calls]}

        cond do
          state.report_answer == :lease_lost or state.lost or report.lease_id != state.lease ->
            {:lease_lost, state}

          true ->
            referenced = referenced(report.result.manifest)
            missing = MapSet.difference(referenced, state.stored) |> Enum.sort()
            {{:recorded, missing ++ state.also_missing}, %{state | referenced: referenced}}
        end
      end)
    end

    @impl true
    def put_blob(agent, blob) do
      # The stream is read as a source would read the request body.
      bytes = blob.content |> Enum.to_list() |> IO.iodata_to_binary()
      sent = Map.merge(Map.delete(blob, :content), %{bytes: bytes})

      answer =
        Agent.get_and_update(agent, fn state ->
          state = %{state | calls: [{:put_blob, sent} | state.calls]}
          n = Enum.count(state.calls, &match?({:put_blob, _}, &1))

          cond do
            state.lost or blob.lease_id != state.lease ->
              {:lease_lost, state}

            state.script[n] == :lease_lost ->
              {:lease_lost, %{state | lost: true}}

            state.script[n] == :too_large ->
              {:too_large, state}

            not MapSet.member?(state.referenced, blob.sha256) ->
              {:not_referenced, state}

            sha(bytes) != blob.sha256 ->
              {:not_referenced, state}

            true ->
              {state.script[n] || :stored,
               %{state | stored: MapSet.put(state.stored, blob.sha256)}}
          end
        end)

      # A crash once the blob is stored: the Runtime dies before it sees the answer.
      if answer == :crash_after_store, do: raise("runtime stopped"), else: answer
    end

    defp referenced(nil), do: MapSet.new()

    defp referenced(%{roots: roots}),
      do: for(%{entries: es} <- roots, %{sha256: s} <- es, into: MapSet.new(), do: s)

    defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  end

  setup do
    bench = start!()
    code = CodeStandIn.start!(bench.dir, @files)
    on_exit(fn -> CodeStandIn.stop(code, bench.dir) end)
    %{bench: bench, code: code}
  end

  defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  # A base work of the source's client, completed and quiescent.
  defp ended!(code, instructions) do
    assert %F.Outcome.Accepted{work: work} =
             F.submit(@source_client, base_request(code, instructions))

    await_work(
      work.work_id,
      &(&1.state == :completed and hd(&1.attempts).quiescent),
      @source_client
    )
  end

  defp manifest_shas(fake) do
    [report | _] = FakeSource.reports(fake)
    for %{entries: es} <- report.result.manifest.roots, %{sha256: s} <- es, do: s
  end

  @three "write atlas/a.txt alpha; write atlas/b.txt beta; write atlas/c.txt gamma; delete atlas/old.md"

  test "uploads exactly the missing blobs, each once, and never an unreferenced one", %{
    code: code
  } do
    work = ended!(code, @three)
    unknown = String.duplicate("e", 64)
    fake = FakeSource.start!(stored: [sha("alpha\n")], also_missing: [unknown])

    assert {:ok, %{uploaded: uploaded, skipped: [^unknown]}} =
             Upload.run(@source_client, {FakeSource, fake}, @lease, work.work_id)

    assert [report] = FakeSource.reports(fake)
    assert %{lease_id: @lease, revision: revision, state: :ended} = report
    assert revision == work.revision

    assert %{result: %{kind: :completed}, provenance: %{}, manifest: %{roots: [_]}} =
             report.result

    expected = Enum.sort([sha("beta\n"), sha("gamma\n")])
    assert Enum.sort(manifest_shas(fake)) == Enum.sort([sha("alpha\n") | expected])
    puts = FakeSource.puts(fake)
    assert Enum.sort(for p <- puts, do: p.sha256) == expected
    assert Enum.sort(uploaded) == expected
    assert Enum.all?(puts, &(&1.lease_id == @lease and sha(&1.bytes) == &1.sha256))
    assert Enum.all?(puts, &(&1.size == byte_size(&1.bytes)))
    assert MapSet.subset?(MapSet.new(expected), FakeSource.stored(fake))
  end

  # The helper refuses absolute or escaping symlink targets, so the test writes Runtime
  # paths into the stored record itself (as frozen_read_test does) to have something to cut.
  test "no Runtime home path in the report or any blob sent, whatever the caller's rights",
       %{bench: bench, code: code} do
    work =
      ended!(
        code,
        "write atlas/a.txt alpha; symlink atlas/self README.md; symlink atlas/home README.md"
      )

    folder = expected_folder(bench.dir, work.work_id)
    home = Path.expand(bench.dir)
    real_home = Path.dirname(Path.dirname(folder))

    links = %{
      "self" => Path.join(folder, "README.md"),
      "home" => Path.join(real_home, "backend.sock")
    }

    stored = FrozenStore.get(bench.dir, work.work_id, 1)

    roots =
      for root <- stored.roots do
        entries =
          for e <- root.entries do
            case links[e.path] do
              nil -> e
              target -> %{e | target: target, sha256: sha(target), size: byte_size(target)}
            end
          end

        %{root | entries: entries}
      end

    FrozenStore.put!(bench.dir, %{stored | roots: roots})

    # The source's fixed rights, and a client that holds choose_path (the local source's).
    # The projection keeps a redacted target's stored sha256 (D44, the core's), so a real
    # source refuses that blob; the upload then stops. What was sent must hold no path,
    # whatever the outcome.
    for client <- [@source_client, {"source:fake", [:submit, :cancel, :read, :choose_path]}] do
      fake = FakeSource.start!()
      Upload.run(client, {FakeSource, fake}, @lease, work.work_id)

      assert [{:report, report} | _] = FakeSource.calls(fake)
      assert %{manifest: %{roots: [_]}, result: %{work_product: %{}}} = report.result
      sent = inspect(FakeSource.calls(fake), limit: :infinity, printable_limit: :infinity)

      for path <- [home, real_home, folder] do
        refute String.contains?(sent, path)
      end
    end
  end

  test "a repeat after a restart sends the same report and uploads nothing twice",
       %{bench: bench, code: code} do
    work = ended!(code, @three)
    fake = FakeSource.start!(script: %{1 => :crash_after_store})

    assert_raise RuntimeError, fn ->
      Upload.run(@source_client, {FakeSource, fake}, @lease, work.work_id)
    end

    assert [_] = FakeSource.puts(fake)

    stop_work()
    start_work!(bench)

    assert {:ok, %{uploaded: [_, _]}} =
             Upload.run(@source_client, {FakeSource, fake}, @lease, work.work_id)

    assert [first, second] = FakeSource.reports(fake)
    assert first == second

    shas = for p <- FakeSource.puts(fake), do: p.sha256
    assert length(shas) == 3
    assert shas == Enum.uniq(shas)
    assert MapSet.new(shas) == MapSet.new(manifest_shas(fake))

    # Once complete, a further repeat reports again and uploads nothing.
    assert {:ok, %{uploaded: []}} =
             Upload.run(@source_client, {FakeSource, fake}, @lease, work.work_id)

    assert length(FakeSource.puts(fake)) == 3
  end

  test "lease_lost stops at once: on the report nothing is put, on a put_blob nothing more",
       %{code: code} do
    work = ended!(code, @three)

    fake = FakeSource.start!(report_answer: :lease_lost)

    assert {:stopped, :lease_lost} =
             Upload.run(@source_client, {FakeSource, fake}, @lease, work.work_id)

    assert [{:report, _}] = FakeSource.calls(fake)

    fake = FakeSource.start!(script: %{1 => :lease_lost})

    assert {:stopped, :lease_lost} =
             Upload.run(@source_client, {FakeSource, fake}, @lease, work.work_id)

    assert [{:report, _}, {:put_blob, _}] = FakeSource.calls(fake)
  end

  test "too_large from the source, or missing bytes over the cap, stops before more is sent",
       %{code: code} do
    work = ended!(code, @three)

    fake = FakeSource.start!(script: %{1 => :too_large})

    assert {:stopped, :too_large} =
             Upload.run(@source_client, {FakeSource, fake}, @lease, work.work_id)

    assert [{:report, _}, {:put_blob, _}] = FakeSource.calls(fake)

    fake = FakeSource.start!()

    assert {:stopped, :too_large} =
             Upload.run(@source_client, {FakeSource, fake}, @lease, work.work_id,
               max_result_bytes: 10
             )

    assert [{:report, _}] = FakeSource.calls(fake)
  end

  test "a work that has not ended, or is not the client's, sends nothing", %{
    bench: bench,
    code: code
  } do
    gate = Path.join(bench.dir, "gate-upload")
    File.write!(gate, "")

    assert %F.Outcome.Accepted{work: work} =
             F.submit(@source_client, base_request(code, "wait gate-upload"))

    await_state(work.work_id, :running, @source_client)
    fake = FakeSource.start!()

    assert {:error, :not_ended} =
             Upload.run(@source_client, {FakeSource, fake}, @lease, work.work_id)

    assert {:error, :not_found} =
             Upload.run({"source:other", [:read]}, {FakeSource, fake}, @lease, work.work_id)

    assert [] = FakeSource.calls(fake)
    File.rm!(gate)
  end
end
