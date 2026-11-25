defmodule AtlasRuntime.Sources.UploadTest do
  @moduledoc """
  M2 plan W6 (decision §5.2 "Result upload", §3 protection 6): `Sources.Upload` against a
  fake source that answers as the `work_source` contract (0.5.0) does: `report(ended)` →
  `recorded(missing)`. A result travels over Git (IS-Atlas-100): no change set is reported
  and no blob is ever uploaded, whatever `missing` the source names.

  - With a `result_ref`, the work's root is pushed to Code as a commit on the base first.
  - No string of the Runtime home path is in any report sent, whatever rights the caller's
    client holds; the agent's answer names its work folder `.` and any other home path
    `<runtime-home>`.
  - A repeat sends the same report; `lease_lost` stops at once; a source not reached is
    unreachable, not a stop.
  """
  use ExUnit.Case, async: false

  import AtlasRuntime.WorkHarness
  import AtlasRuntime.CodeStandIn, only: [base_request: 2, expected_folder: 2]

  alias AtlasRuntime.Boundary.Work, as: F
  alias AtlasRuntime.CodeStandIn
  alias AtlasRuntime.Sources.Upload
  alias AtlasRuntime.Test.GitBase
  alias AtlasRuntime.Work.Store

  @moduletag capture_log: true

  @files %{"README.md" => "base\n", "old.md" => "old\n"}
  # The source's fixed rights (M2 plan C1): no choose_path.
  @source_client {"source:fake", [:submit, :cancel, :read]}
  @lease "lease-0001"

  defmodule FakeSource do
    @moduledoc false
    @behaviour AtlasRuntime.Sources.Upload

    # options: also_missing (blobs it names missing anyway), report_answer (:lease_lost or
    # {:error, reason}), lease (its current lease_id).
    def start!(options \\ []) do
      {:ok, agent} =
        Agent.start_link(fn ->
          %{
            lease: Keyword.get(options, :lease, "lease-0001"),
            also_missing: Keyword.get(options, :also_missing, []),
            report_answer: Keyword.get(options, :report_answer),
            calls: []
          }
        end)

      agent
    end

    def calls(agent), do: agent |> Agent.get(& &1.calls) |> Enum.reverse()
    def reports(agent), do: for({:report, report} <- calls(agent), do: report)

    @impl true
    def report(agent, report) do
      Agent.get_and_update(agent, fn state ->
        state = %{state | calls: [{:report, report} | state.calls]}

        cond do
          state.report_answer == :lease_lost or report.lease_id != state.lease ->
            {:lease_lost, state}

          match?({:error, _}, state.report_answer) ->
            {state.report_answer, state}

          true ->
            {{:recorded, state.also_missing}, state}
        end
      end)
    end
  end

  setup do
    bench = start!()
    code = CodeStandIn.start!(bench.dir, @files)
    on_exit(fn -> CodeStandIn.stop(code, bench.dir) end)
    %{bench: bench, code: code}
  end

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

  @three "write a.txt alpha; write b.txt beta; write c.txt gamma; delete old.md"

  test "one report with the result and its provenance, no change set; nothing is uploaded",
       %{code: code} do
    work = ended!(code, @three)
    unknown = String.duplicate("e", 64)
    fake = FakeSource.start!(also_missing: [unknown])

    assert {:ok, %{uploaded: [], skipped: [^unknown]}} =
             Upload.run(@source_client, {FakeSource, fake}, @lease, work.work_id)

    assert [{:report, report}] = FakeSource.calls(fake)
    assert %{lease_id: @lease, revision: revision, state: :ended} = report
    assert revision == work.revision
    assert %{result: %{kind: :completed}, provenance: %{}} = report.result
    refute Map.has_key?(report.result, :manifest)
  end

  test "with a result_ref, the work's root is pushed to Code as a commit on the base, without the prepared base's dependencies, and the report carries no change set",
       %{bench: bench, code: code} do
    {dependency, _content} = GitBase.dependency()

    work =
      ended!(
        code,
        @three <>
          "; write .gitignore *.log; write build.log noise" <>
          "; write #{dependency} dependency"
      )

    served = GitBase.serve("b-1", @files)
    dir = Path.join(bench.dir, "git-cache")
    {_, 0} = System.cmd("git", ["init", "--bare", "--quiet", dir])
    ref = "refs/atlas/bases/b-1"
    url = served.url <> "/bases/b-1"

    {_, 0} =
      System.cmd("git", ["--git-dir", dir, "fetch", "-q", "--depth", "2", url, "+#{ref}:#{ref}"])

    git = %{
      url: url,
      env: served.env,
      dir: dir,
      base: ref,
      ref: "refs/atlas/results/TK-1",
      tree: Path.join(AtlasRuntime.Work.Folders.path(bench.dir, work.work_id), "atlas")
    }

    fake = FakeSource.start!()

    assert {:ok, %{uploaded: []}} =
             Upload.run(@source_client, {FakeSource, fake}, @lease, work.work_id, git: git)

    assert [%{result: %{result: %{kind: :completed}} = result}] = FakeSource.reports(fake)
    refute Map.has_key?(result, :manifest)

    {files, 0} =
      System.cmd("git", ["ls-tree", "-r", "--name-only", "refs/atlas/results/TK-1"], cd: url)

    # The base's own commit is the parent: the result diffs against it with the work's changes.
    assert String.split(files) == ~w(.gitignore README.md a.txt b.txt c.txt)

    {parent, 0} =
      System.cmd("git", ["rev-parse", "refs/atlas/results/TK-1^", ref <> "^"], cd: url)

    assert [same, same] = String.split(parent)
  end

  test "no Runtime home path in the report sent, whatever the caller's rights",
       %{bench: bench, code: code} do
    work = ended!(code, "write a.txt alpha")
    folder = expected_folder(bench.dir, work.work_id)
    home = Path.expand(bench.dir)
    real_home = Path.dirname(Path.dirname(folder))

    # The source's fixed rights, and a client that holds choose_path (the local source's).
    for client <- [@source_client, {"source:fake", [:submit, :cancel, :read, :choose_path]}] do
      fake = FakeSource.start!()
      assert {:ok, _} = Upload.run(client, {FakeSource, fake}, @lease, work.work_id)

      assert [{:report, report}] = FakeSource.calls(fake)
      assert %{result: %{work_product: %{}}} = report.result
      sent = inspect(FakeSource.calls(fake), limit: :infinity, printable_limit: :infinity)

      for path <- [home, real_home, folder] do
        refute String.contains?(sent, path)
      end
    end
  end

  # The fake agent answers "done: GOAL" and the goal is written before the work folder is
  # known, so the test writes the answer into the stored record, as restart_test does.
  test "the agent's answer is sent with the work folder as . and other home paths cut",
       %{bench: bench, code: code} do
    work = ended!(code, "write a.txt alpha")
    folder = expected_folder(bench.dir, work.work_id)
    home = Path.expand(bench.dir)
    real_home = Path.dirname(Path.dirname(folder))

    stop_work()
    stored = Store.read_work(bench.dir, work.work_id)
    [attempt] = stored.attempts
    answer = "wrote #{folder}/atlas/a.txt; notes in #{home}/scratch/n.txt and #{real_home}/x"
    attempt = %{attempt | result: %{attempt.result | answer: answer}}
    Store.put_work!(bench.dir, %{stored | attempts: [attempt]})
    start_work!(bench)

    for client <- [@source_client, {"source:fake", [:submit, :cancel, :read, :choose_path]}] do
      fake = FakeSource.start!()

      assert {:ok, _} = Upload.run(client, {FakeSource, fake}, @lease, work.work_id)
      assert [report] = FakeSource.reports(fake)

      assert report.result.result.answer ==
               "wrote ./atlas/a.txt; notes in <runtime-home>/scratch/n.txt and <runtime-home>/x"

      sent = inspect(FakeSource.calls(fake), limit: :infinity, printable_limit: :infinity)
      for path <- [home, real_home, folder], do: refute(String.contains?(sent, path))
    end
  end

  test "a repeat after a restart sends the same report again", %{bench: bench, code: code} do
    work = ended!(code, @three)
    fake = FakeSource.start!()
    assert {:ok, _} = Upload.run(@source_client, {FakeSource, fake}, @lease, work.work_id)

    stop_work()
    start_work!(bench)

    assert {:ok, %{uploaded: []}} =
             Upload.run(@source_client, {FakeSource, fake}, @lease, work.work_id)

    assert [first, second] = FakeSource.reports(fake)
    assert first == second
  end

  test "lease_lost stops at once; a source not reached is unreachable, and the repeat sends the same report",
       %{code: code} do
    work = ended!(code, @three)

    fake = FakeSource.start!(report_answer: :lease_lost)

    assert {:stopped, :lease_lost} =
             Upload.run(@source_client, {FakeSource, fake}, @lease, work.work_id)

    assert [{:report, _}] = FakeSource.calls(fake)

    fake = FakeSource.start!(report_answer: {:error, :unreachable})

    assert {:error, :unreachable} =
             Upload.run(@source_client, {FakeSource, fake}, @lease, work.work_id)

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
