defmodule AtlasRuntime.Work.GitCheckoutTest do
  @moduledoc """
  A job's lease (its input names a `result_ref`): the work folder's repository is an ordinary
  Git checkout of Code's prepared base, the base's files and their dependencies, so the agent
  can use Git; the work completes without a frozen change set, as its result goes back over
  Git. An agent that stages and commits there (IS-Atlas-14) has its commit's files in the
  result the Runtime pushes from its own Git directory.

  A review's lease (IS-Atlas-19, IS-Atlas-20): read-only, with `checkout` and no `result_ref`.
  Its folder is the same Git checkout, and its turn runs as a read-only materialized folder:
  Bash reads it, its build goes to its scratch, and nothing is pushed.
  """
  use ExUnit.Case, async: false

  import AtlasRuntime.WorkHarness

  alias AtlasRuntime.Sources.{Import, Rights, Upload}
  alias AtlasRuntime.Test.{FakeWorkSource, GitBase}
  alias AtlasRuntime.Test.WorkSourceFacade, as: S
  alias AtlasRuntime.Work
  alias AtlasRuntime.Work.{Folders, FrozenStore}

  @moduletag capture_log: true

  @source "flow-prod"
  @client Rights.client(@source)
  @files %{"README.md" => "base\n"}

  defmodule Reports do
    @moduledoc false
    @behaviour AtlasRuntime.Sources.Upload
    @impl true
    def report(_ref, _report), do: {:recorded, []}
  end

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

    # The agent stages and commits in its checkout, with the identity the checkout names.
    File.write!(Path.join(repo, "b.txt"), "committed\n")
    assert {_, 0} = System.cmd("git", ["-C", repo, "add", "a.txt", "b.txt"])
    assert {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "agent's commit"])
    assert git.(["log", "-1", "--format=%an %s"]) == "Atlas agent agent's commit\n"
    assert git.(["status", "--porcelain"]) == ""

    # The Runtime still pushes the result itself, from its source's Git cache: the commit's
    # files are in it, on the base's own commit, without the dependencies.
    cache = Path.join(bench.dir, "git-cache")
    {_, 0} = System.cmd("git", ["init", "--bare", "--quiet", cache])
    ref = "refs/atlas/bases/base-1"
    url = served.url <> "/bases/base-1"
    {_, 0} = System.cmd("git", ["--git-dir", cache, "fetch", "-q", url, "+#{ref}:#{ref}"])
    result = "refs/atlas/results/TK-1"
    push = %{url: url, env: served.env, dir: cache, base: ref, ref: result, tree: repo}

    assert {:ok, _} = Upload.run(@client, {Reports, nil}, "lease-1", id, git: push)
    pushed = fn args -> elem(System.cmd("git", args, cd: url), 0) end
    assert pushed.(["ls-tree", "-r", "--name-only", result]) == "README.md\na.txt\nb.txt\n"
    assert pushed.(["show", result <> ":b.txt"]) == "committed\n"
    assert pushed.(["rev-parse", result <> "^"]) == pushed.(["rev-parse", ref <> "^"])
  end

  test "a review's checkout without a result ref is a Git checkout its turn only reads" do
    bench = start!(%{}, local: false)
    {manifest, blobs} = FakeWorkSource.base(@files)
    served = GitBase.serve("base-2", @files)

    fetch = fn sha ->
      {:ok, %{sha256: sha, size: byte_size(blobs[sha]), content: [blobs[sha]]}}
    end

    lease = %{work: %{input: %{base: %{base_id: "base-2", manifest: manifest}}}}
    policy = %{"name" => @source, "max_store_bytes" => 2_147_483_648}
    {:ok, imported} = Import.base(bench.dir, policy, lease, fetch, git: served)

    lease = %S.Lease{
      lease_id: "lease-2",
      expires_at: ~U[2026-11-17 13:00:00Z],
      work: %S.OfferedWork{
        work_key: "TK-2",
        title: "review",
        instructions: "complete the review",
        profile: "light_work",
        cost_class: :standard,
        input: %S.WorkInput{
          base: %S.BaseRef{base_id: "base-2", manifest: manifest},
          permissions: :"read-only",
          checkout: true
        }
      }
    }

    assert {:accepted, id} = Work.accept_lease(@source, lease, imported)
    assert :released = Work.release_lease(id)
    await_work(id, &(&1.state == :completed and hd(&1.attempts).quiescent), @client)

    # A Git checkout of the prepared base, as a writable job's, and not sealed: the sandbox,
    # not the file modes, keeps the turn from writing it.
    repo = Path.join(Folders.path(bench.dir, id), "atlas")

    {prepared, 0} =
      System.cmd("git", ["rev-parse", "refs/atlas/bases/base-2"],
        cd: served.url <> "/bases/base-2"
      )

    assert elem(System.cmd("git", ["-C", repo, "rev-parse", "HEAD"]), 0) == prepared
    assert {:ok, %{access: :read_write}} = File.stat(repo)
    refute match?({:ok, _}, FrozenStore.read(bench.dir, id, 1))

    # Its turn ran as a read-only folder: the folder read, only the scratch written.
    [launch] = Enum.filter(launches(bench), &(&1["goal"] =~ "complete the review"))
    assert ~s(default_permissions="atlas_read_only_folder") in launch["argv"]
    refute ~s(default_permissions="atlas_folder") in launch["argv"]
  end
end
