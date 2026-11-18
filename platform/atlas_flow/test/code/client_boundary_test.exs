defmodule AtlasFlow.Code.ClientBoundaryTest do
  # The adapter on Code's facade against a real Code: a home of its own with a local bare
  # repository, registered in this BEAM. Flow depends on Code with `runtime: false`, so the
  # test starts Code itself. Not async: one Code instance holds the registered name.
  use ExUnit.Case, async: false

  alias AtlasFlow.{Bases, ManualClock, Publish, Results}
  alias AtlasFlow.Code.Client

  @client {AtlasFlow.Code.Client.Boundary, {"flow", [:snapshot]}}
  @repository "github.com/test/app"
  @chunk 64 * 1024
  @large_size 3 * @chunk + 4_321

  setup_all do
    # Git here reads no configuration of the user's or the system's, as in Code's tests.
    dir = Path.join(System.tmp_dir!(), "atlas-flow-code-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "gitconfig"), "[init]\n\ttemplateDir =\n")
    keys = ~w(GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM XDG_CONFIG_HOME)
    saved = Map.new(keys, &{&1, System.get_env(&1)})

    System.put_env(%{
      "GIT_CONFIG_GLOBAL" => Path.join(dir, "gitconfig"),
      "GIT_CONFIG_NOSYSTEM" => "1",
      "XDG_CONFIG_HOME" => dir
    })

    {:ok, _} = Application.ensure_all_started(:atlas_code)

    on_exit(fn ->
      for {key, value} <- saved,
          do: if(value, do: System.put_env(key, value), else: System.delete_env(key))

      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  setup %{dir: dir} do
    dir = Path.join(dir, "case-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    large = :crypto.strong_rand_bytes(@large_size)
    remote = bare(dir, %{"README.md" => "hello\n", "data/large.bin" => large})

    home = Path.join(dir, "home")
    File.mkdir_p!(home)
    # Code's HTTP routes need a token; this test calls only the facade.
    File.write!(Path.join(home, "runtime.token"), "token\n")
    File.chmod!(Path.join(home, "runtime.token"), 0o600)
    config = %{"port" => 0, "repositories" => %{@repository => "file://" <> remote}}
    File.write!(Path.join(home, "config.json"), JSON.encode!(config))
    {:ok, pid, _port} = AtlasCode.start(home, register: true)
    on_exit(fn -> AtlasCode.stop(pid) end)

    %{large: large, code: pid, remote: remote, dir: dir}
  end

  test "resolve, snapshot, manifest, and a blob streamed in chunks", %{large: large} do
    assert {:ok, revision} = Client.resolve_reference(@client, @repository, "develop")
    assert {:error, :unknown_reference} = Client.resolve_reference(@client, @repository, "none")

    placement = %{repository: @repository, revision: revision, path: "app"}
    assert {:ok, "sha256:" <> _ = snapshot_id} = Client.create_snapshot(@client, [placement])
    assert {:ok, ^snapshot_id} = Client.create_snapshot(@client, [placement])

    assert {:ok, entries} = Client.get_manifest(@client, snapshot_id)
    assert Enum.map(entries, & &1.path) == ["app/README.md", "app/data/large.bin"]

    assert Enum.all?(
             entries,
             &match?(%{repository: @repository, kind: "file", mode: "100644"}, &1)
           )

    entry = Enum.find(entries, &(&1.path == "app/data/large.bin"))
    assert {:ok, @large_size, content} = Client.get_blob(@client, snapshot_id, entry.sha256)
    refute is_binary(content) or is_list(content)
    sizes = content |> Enum.map(&byte_size/1)
    assert length(sizes) > 1 and Enum.max(sizes) <= @chunk
    assert Enum.join(content) == large

    unknown = String.duplicate("0", 64)
    assert {:error, :not_found} = Client.get_blob(@client, snapshot_id, unknown)
    assert {:error, :not_found} = Client.get_manifest(@client, "sha256:" <> unknown)

    assert {:error, :not_permitted} =
             Client.get_manifest({AtlasFlow.Code.Client.Boundary, {"flow", []}}, snapshot_id)
  end

  test "a base from the real Code: its names and its blobs", %{large: large} do
    assert {:ok, %{base_id: "code-" <> hex, manifest: manifest, snapshot_id: snapshot_id}} =
             Bases.for(@client, @repository, "develop")

    assert snapshot_id == "sha256:" <> hex
    {:ok, entries} = Client.get_manifest(@client, snapshot_id)

    name = :"bases_#{System.unique_integer([:positive])}"
    start_supervised!({Bases, name: name, client: @client})
    :ok = Bases.request(@repository, "develop", {self(), :ready}, name)
    assert_receive :ready, 10_000
    assert {:ok, %{manifest: ^manifest}} = Bases.cached(@repository, "develop", name)

    assert Bases.names(manifest, name) ==
             {:ok, MapSet.new([manifest | Enum.map(entries, & &1.sha256)])}

    large_entry = Enum.find(entries, &(&1.path == "app/data/large.bin"))
    assert {:ok, @large_size, stream} = Bases.blob(large_entry.sha256, snapshot_id, name)
    assert Enum.join(stream) == large
  end

  test "no Code registered: unavailable", %{code: pid} do
    :ok = AtlasCode.stop(pid)
    assert {:error, :unavailable} = Client.resolve_reference(@client, @repository, "develop")
  end

  describe "Publish on the real Code (F3-P)" do
    setup %{dir: dir} do
      {:ok, clock} = ManualClock.start_link(~U[2026-11-17 12:00:00Z])

      results =
        start_supervised!(
          {Results,
           name: nil,
           dir: Path.join(dir, "results"),
           clock: {ManualClock, clock},
           pins: fn -> [] end}
        )

      {:ok, revision} = Client.resolve_reference(@client, @repository, "develop")
      placement = %{repository: @repository, revision: revision, path: "app"}
      {:ok, snapshot_id} = Client.create_snapshot(@client, [placement])
      %{results: results, snapshot_id: snapshot_id}
    end

    test "a draft at Flow's location; a fix moves it to Code's commit on its head (N1)",
         %{remote: remote} = c do
      author = result(c, "TK-C-1", %{"README.md" => "published\n", "new/file.txt" => "new\n"})

      # The default client of Publish is the publishing one.
      assert {:ok, first} = Publish.publish(request("TK-C-1", author), results: c.results)
      assert %{kind: :created, review_id: review_id} = first
      assert ref?(remote, "refs/heads/work/flow-review-" <> review_id)
      refute ref?(remote, "refs/heads/work/review-" <> review_id)
      assert first.published_revision == first.sealed_revision

      assert {:ok, %{draft: true, state: :open, at_revision: true, revision: at}} =
               Client.review_status(Client.publishing(), review_id)

      assert at == first.published_revision

      # A repeat is the same review.
      assert Publish.publish(request("TK-C-1", author), results: c.results) == {:ok, first}

      fix = result(c, "TK-C-2", %{"README.md" => "fixed\n"}, "fix")
      open = %{review_id: review_id, revision: first.published_revision}

      assert {:ok, second} =
               Publish.publish(%{request("TK-C-2", fix) | review: open}, results: c.results)

      assert %{kind: :updated, review_id: ^review_id} = second
      assert second.published_revision != second.sealed_revision
      assert {:ok, %{revision: now}} = Client.review_status(Client.publishing(), review_id)
      assert now == second.published_revision

      branch = "refs/heads/work/flow-review-" <> review_id
      assert git(remote, ["show", branch <> ":README.md"]) == "fixed\n"
    end

    test "Bases' default client may not open a review", c do
      assert {:error, :not_permitted} =
               Client.create_review(Client.default(), %{
                 review_id: Publish.id("review", "TK-C-3"),
                 change_id: Publish.id("change", "TK-C-3"),
                 target: "develop",
                 title: "t",
                 body: "b"
               })

      assert {:error, :not_permitted} =
               Client.create_change(Client.default(), %{
                 change_id: Publish.id("change", "TK-C-3"),
                 snapshot_id: c.snapshot_id,
                 repository: @repository,
                 base_revision: "rev_" <> String.duplicate("0", 64),
                 entries: [%{path: "x", op: "delete"}]
               })
    end
  end

  # A task's complete result of `files` (path => bytes) on root `app`, as Delivery stores it:
  # blobs and change set in the store, pinned for `key`. No base_revision: Publish reads it
  # from Code's record of the snapshot.
  defp result(c, key, files, kind \\ "author") do
    base = "code-" <> String.duplicate("c", 64)

    entries =
      for {path, bytes} <- files do
        sha = sha256(bytes)

        :stored =
          Results.put(sha, byte_size(bytes), [bytes], Results.room(0, c.results), c.results)

        %{
          "path" => path,
          "op" => "write",
          "kind" => "file",
          "mode" => "100644",
          "size" => byte_size(bytes),
          "sha256" => sha
        }
      end

    fingerprint = AtlasChangeset.fingerprint(base, "app", entries)
    roots = [%{"root" => "app", "entries" => entries, "fingerprint" => fingerprint}]
    {:ok, manifest} = Results.put_manifest(%{"base" => base, "roots" => roots}, c.results)
    :ok = Results.pin(key, manifest, c.results)

    %{
      "kind" => kind,
      "result_state" => "complete",
      "check_exit_status" => 0,
      "base_id" => base,
      "base_snapshot" => c.snapshot_id,
      "result_fingerprints" => JSON.encode!([%{"root" => "app", "fingerprint" => fingerprint}])
    }
  end

  defp request(key, task),
    do: %{
      task_key: key,
      task: task,
      repository: @repository,
      target: "develop",
      title: "Package C",
      why_now: "test",
      provenance: %{},
      review: nil
    }

  defp ref?(remote, ref) do
    {_, status} =
      System.cmd("git", ["rev-parse", "--verify", "--quiet", ref],
        cd: remote,
        stderr_to_stdout: true
      )

    status == 0
  end

  defp sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  # A local bare repository with one commit of `files` on develop: Code's remote.
  defp bare(dir, files) do
    source = Path.join(dir, "source")
    git(dir, ["init", "-q", "-b", "develop", source])

    for {path, content} <- files do
      File.mkdir_p!(Path.dirname(Path.join(source, path)))
      File.write!(Path.join(source, path), content)
    end

    git(source, ["add", "-A"])
    git(source, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "base"])
    remote = Path.join(dir, "app.git")
    git(dir, ["clone", "-q", "--bare", source, remote])
    remote
  end

  defp git(dir, args) do
    {output, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    output
  end
end
