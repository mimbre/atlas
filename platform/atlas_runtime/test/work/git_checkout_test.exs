defmodule AtlasRuntime.Work.GitCheckoutTest do
  @moduledoc """
  A job's lease (its input names a `result_ref`): the work folder's repository is an ordinary
  Git checkout of Code's prepared base, the base's files and their dependencies, so the agent
  can use Git; the work completes without a frozen change set, as its result goes back over
  Git.
  """
  use ExUnit.Case, async: false

  import AtlasRuntime.WorkHarness

  alias AtlasRuntime.Sources.{Import, Rights}
  alias AtlasRuntime.Test.{FakeWorkSource, GitBase}
  alias AtlasRuntime.Test.WorkSourceFacade, as: S
  alias AtlasRuntime.Work
  alias AtlasRuntime.Work.{Folders, FrozenStore}

  @moduletag capture_log: true

  @source "flow-prod"
  @client Rights.client(@source)
  @files %{"README.md" => "base\n"}

  test "the folder is a Git checkout of the prepared base, and nothing is frozen" do
    bench = start!(%{}, local: false)
    {manifest, blobs} = FakeWorkSource.base(@files)
    served = GitBase.serve("base-1", @files)

    fetch = fn sha ->
      {:ok, %{sha256: sha, size: byte_size(blobs[sha]), content: [blobs[sha]]}}
    end

    lease = %{work: %{input: %{base: %{base_id: "base-1", manifest: manifest}}}}
    policy = %{"name" => @source, "max_store_bytes" => 2_147_483_648}
    {:ok, imported} = Import.base(bench.dir, policy, lease, fetch, git: served)

    lease = %S.Lease{
      lease_id: "lease-1",
      expires_at: ~U[2026-11-17 13:00:00Z],
      work: %S.OfferedWork{
        work_key: "TK-1",
        title: "job",
        instructions: "write a.txt alpha",
        profile: "light_work",
        cost_class: :standard,
        input: %S.WorkInput{
          base: %S.BaseRef{base_id: "base-1", manifest: manifest},
          permissions: :"workspace-write",
          result_ref: "refs/atlas/results/TK-1"
        }
      }
    }

    assert {:accepted, id} = Work.accept_lease(@source, lease, imported)
    assert :released = Work.release_lease(id)
    await_work(id, &(&1.state == :completed and hd(&1.attempts).quiescent), @client)

    repo = Path.join(Folders.path(bench.dir, id), "atlas")
    git = fn args -> elem(System.cmd("git", ["-C", repo | args]), 0) end

    {prepared, 0} =
      System.cmd("git", ["rev-parse", "refs/atlas/bases/base-1"],
        cd: served.url <> "/bases/base-1"
      )

    {dependency, content} = GitBase.dependency()

    assert git.(["rev-parse", "HEAD"]) == prepared
    assert File.read!(Path.join(repo, dependency)) == content
    assert git.(["status", "--porcelain"]) == "?? a.txt\n"
    refute match?({:ok, _}, FrozenStore.read(bench.dir, id, 1))
  end
end
