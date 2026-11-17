defmodule AtlasCode.SnapshotReadingTest do
  # C1a: reading a snapshot through the facade AtlasCode.Boundary (get_manifest, get_blob)
  # on a running Code: a temporary home with local bare repositories, started with
  # register: true. Not async: one instance holds the registered name at a time, and the
  # tests count git ports.
  use ExUnit.Case, async: false

  alias AtlasCode.{Boundary, Service}
  alias AtlasCode.Boundary.{ManifestEntry, Outcome, SnapshotRepository}
  alias AtlasCodeBoundary.Generator.{InvalidInput, NotPermitted}

  setup {AtlasCode.TestDir, :tmp_dir}

  @token "runtime-secret-token"
  @client {"test:flow", [:snapshot]}
  @chunk 64 * 1024
  # Larger than many chunks; not a multiple of one.
  @large_size 3 * @chunk * 2 + 12_345

  setup %{tmp_dir: dir} do
    large = :crypto.strong_rand_bytes(@large_size)

    {app, _} =
      bare(dir, "app", %{"README.md" => "hello\n", "data/large.bin" => large}, fn source ->
        File.write!(Path.join(source, "bin/run"), "#!/bin/sh\necho run\n")
        File.chmod!(Path.join(source, "bin/run"), 0o755)
        File.ln_s!("../README.md", Path.join(source, "bin/readme"))
      end)

    {docs, _} = bare(dir, "docs", %{"guide.md" => "a guide\n", "copy.md" => "hello\n"})

    repositories = %{
      "github.com/test/app" => "file://" <> app,
      "github.com/test/docs" => "file://" <> docs
    }

    {home, pid, port} = start(dir, "home", repositories)

    %{home: home, pid: pid, port: port, app: app, large: large, repositories: repositories}
  end

  describe "get_manifest" do
    test "gives each snapshot its own manifest, whose canonical JSON its ID is the digest of",
         %{home: home, port: port} do
      app = snapshot([{"github.com/test/app", "app"}])
      both = snapshot([{"github.com/test/app", "src"}, {"github.com/test/docs", "docs"}])
      assert app != both

      for {id, paths} <- [
            {app, ["app/README.md", "app/bin/readme", "app/bin/run", "app/data/large.bin"]},
            {both,
             [
               "docs/copy.md",
               "docs/guide.md",
               "src/README.md",
               "src/bin/readme",
               "src/bin/run",
               "src/data/large.bin"
             ]}
          ] do
        "sha256:" <> hex = id

        assert %Outcome.Manifest{snapshot_id: ^id, version: 2, entries: entries} =
                 manifest = Boundary.get_manifest(@client, %{"snapshot_id" => id})

        assert Enum.map(entries, & &1.path) == paths

        # Without its ID the manifest is the stored document, and that hashes to the ID.
        canonical =
          manifest |> Outcome.Manifest.dump() |> Map.delete("snapshot_id") |> JSON.encode!()

        assert canonical == File.read!(Path.join([home, "snapshots", hex <> ".json"]))
        assert hex == Base.encode16(:crypto.hash(:sha256, canonical), case: :lower)

        # The HTTP route goes through the facade and answers what the Service answers.
        response = get(port, "/v1/snapshots/#{id}/manifest")
        assert response == {200, Outcome.Manifest.dump(manifest)}
        assert response == Service.get_manifest(AtlasCode.settings(), id)
      end

      assert %Outcome.Manifest{
               repositories: [
                 %SnapshotRepository{repository: "github.com/test/docs", path: "docs"},
                 %SnapshotRepository{repository: "github.com/test/app", path: "src"}
               ]
             } = Boundary.get_manifest(@client, %{snapshot_id: both})
    end

    test "entries are typed: files with their mode, symlinks with their target", %{large: large} do
      id = snapshot([{"github.com/test/app", "app"}])
      %Outcome.Manifest{entries: entries} = Boundary.get_manifest(@client, %{snapshot_id: id})
      by_path = Map.new(entries, &{&1.path, &1})

      assert %ManifestEntry{kind: :file, mode: "100755", target: nil} = by_path["app/bin/run"]

      assert %ManifestEntry{kind: :symlink, mode: "120000", target: "../README.md", size: 12} =
               by_path["app/bin/readme"]

      assert %ManifestEntry{kind: :file, mode: "100644", size: @large_size, sha256: digest} =
               by_path["app/data/large.bin"]

      assert digest == sha256(large)
    end

    test "answers each refusal as its outcome, as the HTTP route does", %{home: home, port: port} do
      unknown = "sha256:" <> String.duplicate("0", 64)
      old = String.duplicate("a", 64)
      lost = String.duplicate("b", 64)
      successor = snapshot([{"github.com/test/app", "app"}])

      # Manifests from before revision handles: one with a recorded successor, one without.
      for hex <- [old, lost],
          do: File.write!(Path.join([home, "snapshots", hex <> ".json"]), ~s({"version":1}))

      File.write!(Path.join([home, "snapshots", old <> ".successor"]), successor)

      cases = [
        {unknown, Outcome.NotFound, snapshot_id: unknown},
        {"sha256:..", Outcome.InvalidRequest, []},
        {"abc", Outcome.InvalidRequest, []},
        {"sha256:" <> old, Outcome.SnapshotSuperseded,
         snapshot_id: "sha256:" <> old, successor: successor},
        {"sha256:" <> lost, Outcome.SnapshotSuperseded,
         snapshot_id: "sha256:" <> lost, successor: nil}
      ]

      for {id, outcome, fields} <- cases do
        assert %^outcome{} = answer = Boundary.get_manifest(@client, %{snapshot_id: id})

        for {field, value} <- fields,
            do: assert(Map.fetch!(answer, field) == value, "#{id} #{field}")

        response = get(port, "/v1/snapshots/#{URI.encode(id)}/manifest")
        assert response == Service.get_manifest(AtlasCode.settings(), id), id
      end

      # The wire still names a missing successor as null.
      assert {409, %{"error" => %{"details" => %{"successor" => nil}}}} =
               get(port, "/v1/snapshots/sha256:#{lost}/manifest")
    end

    test "refuses what the contract does not allow before it reaches Code" do
      id = snapshot([{"github.com/test/app", "app"}])

      assert %NotPermitted{right: :snapshot} =
               Boundary.get_manifest({"test:other", []}, %{snapshot_id: id})

      assert %InvalidInput{capability: :get_manifest} = Boundary.get_manifest(@client, %{})
      assert %InvalidInput{} = Boundary.get_manifest(@client, %{snapshot_id: 1})
    end
  end

  describe "get_blob" do
    test "streams every entry's bytes, chunk by chunk, read only as they are enumerated",
         %{app: app, large: large} do
      id = snapshot([{"github.com/test/app", "app"}])
      %Outcome.Manifest{entries: entries} = Boundary.get_manifest(@client, %{snapshot_id: id})

      expected = %{
        "app/README.md" => "hello\n",
        "app/bin/run" => "#!/bin/sh\necho run\n",
        "app/bin/readme" => "../README.md",
        "app/data/large.bin" => large
      }

      for entry <- entries do
        ports = git_ports()

        assert %Outcome.Blob{sha256: digest, size: size, content: content} =
                 Boundary.get_blob(@client, %{snapshot_id: id, sha256: entry.sha256})

        assert {digest, size} == {entry.sha256, entry.size}
        # Answering read no byte: no git is left running and the bytes are not in the answer.
        assert git_ports() == ports
        refute is_list(content) or is_binary(content)

        # Enumerating reads from a git of its own, while the chunks come.
        chunks =
          Enum.map(content, fn chunk ->
            assert length(git_ports()) == length(ports) + 1
            chunk
          end)

        assert git_ports() == ports
        assert IO.iodata_to_binary(chunks) == expected[entry.path]
        assert Enum.all?(chunks, &(is_binary(&1) and byte_size(&1) in 1..@chunk))
      end

      # The large file is many chunks, never one whole binary.
      large_entry = Enum.find(entries, &(&1.path == "app/data/large.bin"))

      %Outcome.Blob{content: content} =
        Boundary.get_blob(@client, %{snapshot_id: id, sha256: large_entry.sha256})

      sizes = Enum.map(content, &byte_size/1)
      assert length(sizes) >= div(@large_size, @chunk) + 1
      assert Enum.sum(sizes) == @large_size
      assert Enum.max(sizes) <= @chunk

      # The source moving on changes nothing: the snapshot's bytes are its revision's.
      File.write!(Path.join(app, "README.md"), "changed\n")
      readme = Enum.find(entries, &(&1.path == "app/README.md"))

      %Outcome.Blob{content: content} =
        Boundary.get_blob(@client, %{snapshot_id: id, sha256: readme.sha256})

      assert Enum.join(content) == "hello\n"
    end

    test "a stream can be read again, in another process, and stopped early", %{large: large} do
      %Outcome.Blob{content: content} = large_blob()

      assert Enum.join(content) == large
      assert Task.await(Task.async(fn -> Enum.join(content) end)) == large

      ports = git_ports()
      assert [first] = Enum.take(content, 1)
      assert first == binary_part(large, 0, byte_size(first))
      # Halting stops its git and leaves none of its messages behind.
      assert git_ports() == ports
      {:messages, messages} = Process.info(self(), :messages)
      refute Enum.any?(messages, &match?({port, _} when is_port(port), &1))
    end

    test "the repository is fetched again when Code's cache lost it", %{home: home, large: large} do
      id = snapshot([{"github.com/test/app", "app"}])
      %Outcome.Blob{content: content} = large_blob(id)
      File.rm_rf!(Path.join(home, "cache"))
      # The stream was made for the cache it found; it cannot read what is gone.
      assert_raise RuntimeError, ~r/cache does not hold the blob/, fn -> Enum.to_list(content) end

      # Asking again, for the same snapshot, fetches the revision again.
      %Outcome.Blob{content: content} = large_blob(id)
      assert [_cached] = File.ls!(Path.join(home, "cache"))
      assert Enum.join(content) == large
    end

    test "an unknown sha256 is not_found; what the contract refuses never reaches Code" do
      id = snapshot([{"github.com/test/app", "app"}])
      unknown = String.duplicate("0", 64)

      assert %Outcome.NotFound{snapshot_id: ^id, sha256: ^unknown} =
               Boundary.get_blob(@client, %{snapshot_id: id, sha256: unknown})

      # A digest of another snapshot's entry is unknown in this one.
      docs = snapshot([{"github.com/test/docs", "docs"}])

      %Outcome.Manifest{entries: [_copy, guide]} =
        Boundary.get_manifest(@client, %{snapshot_id: docs})

      assert %Outcome.NotFound{sha256: digest} =
               Boundary.get_blob(@client, %{snapshot_id: id, sha256: guide.sha256})

      assert digest == guide.sha256

      missing = "sha256:" <> String.duplicate("0", 64)

      assert %Outcome.NotFound{snapshot_id: ^missing, sha256: nil} =
               Boundary.get_blob(@client, %{snapshot_id: missing, sha256: unknown})

      for digest <- ["abc", String.upcase(guide.sha256), "sha256:" <> guide.sha256] do
        assert %Outcome.InvalidRequest{message: "sha256 must be" <> _} =
                 Boundary.get_blob(@client, %{snapshot_id: id, sha256: digest})
      end

      assert %Outcome.InvalidRequest{} =
               Boundary.get_blob(@client, %{snapshot_id: "abc", sha256: unknown})

      assert %NotPermitted{capability: :get_blob, right: :snapshot} =
               Boundary.get_blob({"test:other", [:read]}, %{snapshot_id: id, sha256: unknown})

      assert %InvalidInput{capability: :get_blob} = Boundary.get_blob(@client, %{snapshot_id: id})
    end

    test "the refusals of reaching the repository",
         %{tmp_dir: dir, home: home, pid: pid, repositories: repositories} do
      id = snapshot([{"github.com/test/app", "app"}])

      %Outcome.Manifest{entries: [entry | _], repositories: [%{revision: revision}]} =
        Boundary.get_manifest(@client, %{snapshot_id: id})

      input = %{snapshot_id: id, sha256: entry.sha256}
      :ok = AtlasCode.stop(pid)

      # The repository is no longer allowed.
      {_, pid, _} =
        restart(home, %{"github.com/test/docs" => repositories["github.com/test/docs"]})

      assert %Outcome.Forbidden{repository: "github.com/test/app"} =
               Boundary.get_blob(@client, input)

      :ok = AtlasCode.stop(pid)

      # Its remote is gone (and with another remote, so is its cache).
      {_, pid, _} =
        restart(home, %{"github.com/test/app" => "file://" <> Path.join(dir, "nowhere.git")})

      assert %Outcome.ProviderUnavailable{message: "git fetch failed" <> _} =
               Boundary.get_blob(@client, input)

      :ok = AtlasCode.stop(pid)

      # The revision's record is gone.
      File.rm!(Path.join([home, "revisions", revision <> ".json"]))
      restart(home, repositories)

      assert %Outcome.UnknownRevision{repository: "github.com/test/app", revision: ^revision} =
               Boundary.get_blob(@client, input)
    end
  end

  defp large_blob(id \\ snapshot([{"github.com/test/app", "app"}])) do
    %Outcome.Manifest{entries: entries} = Boundary.get_manifest(@client, %{snapshot_id: id})
    entry = Enum.find(entries, &(&1.path == "app/data/large.bin"))
    Boundary.get_blob(@client, %{snapshot_id: id, sha256: entry.sha256})
  end

  # Resolves each repository's develop and snapshots it at its path; the snapshot's ID.
  defp snapshot(placements) do
    repositories =
      for {repository, path} <- placements do
        %Outcome.Resolved{revision: revision} =
          Boundary.resolve_reference(@client, %{
            "repository" => repository,
            "reference" => "develop"
          })

        %{"repository" => repository, "revision" => revision, "path" => path}
      end

    %Outcome.Created{snapshot_id: id} =
      Boundary.create_snapshot(@client, %{"repositories" => repositories})

    id
  end

  # The git processes this BEAM runs through ports (a stream's cat-file among them).
  defp git_ports do
    for port <- Port.list(),
        {:name, name} <- [Port.info(port, :name)],
        name |> to_string() |> Path.basename() == "git",
        do: port
  end

  defp sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp start(dir, name, repositories) do
    home = Path.join(dir, name)
    File.mkdir!(home)
    File.write!(Path.join(home, "runtime.token"), @token <> "\n")
    File.chmod!(Path.join(home, "runtime.token"), 0o600)
    restart(home, repositories)
  end

  # Starts Code on `home` with these repositories, registered (no other instance may be);
  # stopped after the test.
  defp restart(home, repositories) do
    config = %{"port" => 0, "repositories" => repositories}
    File.write!(Path.join(home, "config.json"), JSON.encode!(config))
    {:ok, pid, port} = AtlasCode.start(home, register: true)
    on_exit(fn -> AtlasCode.stop(pid) end)
    {home, pid, port}
  end

  # A local bare repository with one commit of `files` on develop: Code's remote.
  defp bare(dir, name, files, extra) do
    source = Path.join(dir, name <> "-source")
    git(dir, ["init", "-q", "-b", "develop", source])

    for {path, content} <- files do
      File.mkdir_p!(Path.dirname(Path.join(source, path)))
      File.write!(Path.join(source, path), content)
    end

    File.mkdir_p!(Path.join(source, "bin"))
    extra.(source)
    git(source, ["add", "-A"])
    git(source, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", name])
    remote = Path.join(dir, name <> ".git")
    git(dir, ["clone", "-q", "--bare", source, remote])
    {remote, source |> git(["rev-parse", "HEAD"]) |> String.trim()}
  end

  defp bare(dir, name, files), do: bare(dir, name, files, fn _source -> :ok end)

  defp get(port, path) do
    request =
      {~c"http://127.0.0.1:#{port}#{path}",
       [{~c"authorization", ~c"Bearer " ++ String.to_charlist(@token)}]}

    {:ok, {{_, status, _}, _, reply}} =
      :httpc.request(:get, request, [timeout: 10_000, ssl: []], body_format: :binary)

    {status, JSON.decode!(reply)}
  end

  defp git(dir, args) do
    {output, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    output
  end
end
