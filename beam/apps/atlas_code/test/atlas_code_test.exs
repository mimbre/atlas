defmodule AtlasCodeTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir
  @token "runtime-secret-token"

  setup %{tmp_dir: dir} do
    source = Path.join(dir, "source")
    git(dir, ["init", "-q", "-b", "develop", source])

    git(source, [
      "-c",
      "user.name=t",
      "-c",
      "user.email=t@t",
      "commit",
      "--allow-empty",
      "-qm",
      "base"
    ])

    commit = source |> git(["rev-parse", "HEAD"]) |> String.trim()

    home = Path.join(dir, "home")
    File.mkdir!(home)
    config = %{"port" => 0, "repositories" => %{"github.com/test/fixture" => "file://" <> source}}
    File.write!(Path.join(home, "config.json"), JSON.encode!(config))
    token = Path.join(home, "runtime.token")
    File.write!(token, @token <> "\n")
    File.chmod!(token, 0o600)

    {:ok, pid, port} = AtlasCode.start(home)
    on_exit(fn -> AtlasCode.stop(pid) end)
    %{home: home, port: port, commit: commit, source: source}
  end

  test "health reports the service with the runtime token", %{port: port} do
    assert {200, %{"service" => "atlas-code", "version" => "0.1.0"}} =
             request(port, :get, "/v1/health")
  end

  test "resolve returns the exact branch commit", %{port: port, commit: commit, source: source} do
    assert {200,
            %{"repository" => "github.com/test/fixture", "ref" => "develop", "commit" => ^commit}} =
             resolve(port, %{"repository" => "github.com/test/fixture", "ref" => "develop"})

    # Only refs/heads/<ref> counts, not a longer name ending in it.
    git(source, ["branch", "nested/develop"])
    git(source, ["branch", "-m", "develop", "main"])

    assert {404, %{"error" => %{"code" => "unknown_ref"}}} =
             resolve(port, %{"repository" => "github.com/test/fixture", "ref" => "develop"})
  end

  test "unknown ref, forbidden repository and invalid requests are refused", %{port: port} do
    assert {404, %{"error" => %{"code" => "unknown_ref", "details" => %{"ref" => "missing"}}}} =
             resolve(port, %{"repository" => "github.com/test/fixture", "ref" => "missing"})

    assert {403, %{"error" => %{"code" => "forbidden"}}} =
             resolve(port, %{"repository" => "github.com/test/other", "ref" => "develop"})

    for body <- [
          "not json",
          "[]",
          JSON.encode!(%{"repository" => "github.com/test/fixture"}),
          JSON.encode!(%{
            "repository" => "github.com/test/fixture",
            "ref" => "develop",
            "extra" => 1
          }),
          JSON.encode!(%{"repository" => "github.com/test/fixture", "ref" => 1}),
          JSON.encode!(%{"repository" => "github.com/test/fixture", "ref" => "../x"}),
          JSON.encode!(%{"repository" => "github.com/test/fixture", "ref" => "-x"}),
          JSON.encode!(%{"repository" => "github.com/test/fixture", "ref" => "a\u0000b"})
        ] do
      assert {400, %{"error" => %{"code" => "invalid_request", "details" => %{}}}} =
               raw(port, :post, "/v1/revisions/resolve", body)
    end

    assert {404, %{"error" => %{"code" => "not_found"}}} = request(port, :get, "/v1/other")

    assert {405, %{"error" => %{"code" => "method_not_allowed"}}} =
             request(port, :get, "/v1/revisions/resolve")
  end

  test "unreachable remotes are provider failures without Git output", %{tmp_dir: dir, home: home} do
    config = %{
      "port" => 0,
      "repositories" => %{"github.com/test/gone" => "file://" <> Path.join(dir, "gone")}
    }

    other = Path.join(dir, "other-home")
    File.mkdir!(other)
    File.write!(Path.join(other, "config.json"), JSON.encode!(config))
    File.cp!(Path.join(home, "runtime.token"), Path.join(other, "runtime.token"))
    File.chmod!(Path.join(other, "runtime.token"), 0o600)
    {:ok, pid, port} = AtlasCode.start(other)

    assert {503, %{"error" => %{"code" => "provider_unavailable", "message" => message}}} =
             resolve(port, %{"repository" => "github.com/test/gone", "ref" => "develop"})

    refute message =~ dir

    snapshot = %{
      "repositories" => [
        %{
          "repository" => "github.com/test/gone",
          "commit" => String.duplicate("a", 40),
          "path" => "gone"
        }
      ]
    }

    assert {503, %{"error" => %{"code" => "provider_unavailable", "message" => message}}} =
             raw(port, :post, "/v1/snapshots", JSON.encode!(snapshot))

    refute message =~ dir
    AtlasCode.stop(pid)
  end

  test "missing or wrong bearer tokens are unauthorized without echoing them", %{port: port} do
    change = "/v1/changes/00000000-0000-4000-8000-000000000000"
    json = JSON.encode!(%{"repository" => "github.com/test/fixture", "ref" => "develop"})
    # Larger than one 64 KiB chunk, so the token is checked on the first streamed piece.
    big = :binary.copy("x", 200_000)

    for headers <- [
          [],
          [{~c"authorization", ~c"Bearer wrong-token"}],
          [{~c"authorization", ~c"Basic " ++ String.to_charlist(@token)}]
        ] do
      for {method, path} <- [
            {:get, "/v1/health"},
            {:post, "/v1/revisions/resolve"},
            {:get, "/v1/other"},
            {:post, "/v1/snapshots"},
            {:get, "/v1/snapshots/sha256:#{String.duplicate("0", 64)}/manifest"},
            {:get, "/v1/snapshots/sha256:#{String.duplicate("0", 64)}/archive?path=app"},
            {:post, "/v1/changes"},
            {:put, "#{change}/blobs/#{String.duplicate("0", 64)}"},
            {:post, "#{change}/seal"}
          ],
          body <- [json, big] do
        {status, reply} = send_request(port, method, path, body, headers)
        assert status == 401
        assert reply =~ ~s("unauthorized")
        refute reply =~ "wrong-token"
        refute reply =~ @token
      end
    end
  end

  test "start refuses a token file readable by others", %{home: home} do
    File.chmod!(Path.join(home, "runtime.token"), 0o644)
    assert_raise RuntimeError, ~r/owner-only/, fn -> AtlasCode.start(home) end
    File.rm!(Path.join(home, "runtime.token"))
    assert_raise RuntimeError, ~r/owner-only/, fn -> AtlasCode.start(home) end
  end

  describe "snapshots" do
    setup %{tmp_dir: dir} do
      app =
        fixture(dir, "app", fn source ->
          File.mkdir_p!(Path.join(source, "bin"))
          File.write!(Path.join(source, "bin/run.sh"), "#!/bin/sh\necho hi\n")
          File.chmod!(Path.join(source, "bin/run.sh"), 0o755)
          File.mkdir_p!(Path.join(source, "data"))
          File.write!(Path.join(source, "data/blob.bin"), <<0, 1, 2, 255, 0, 10, 13>>)
          File.write!(Path.join(source, "data/empty"), "")
          File.mkdir_p!(Path.join(source, "lib"))
          File.ln_s!("../data/blob.bin", Path.join(source, "lib/link"))
          # The export-subst placeholder must come out as committed, not expanded.
          File.write!(Path.join(source, "version.txt"), "$Format:%H$\n")

          File.write!(
            Path.join(source, ".gitattributes"),
            "version.txt export-subst\n* export-ignore\n"
          )

          # Longer than ustar's 100-byte name field, so the archive needs a pax header.
          long =
            Path.join(["deep", String.duplicate("d", 60), String.duplicate("f", 60) <> ".txt"])

          File.mkdir_p!(Path.join(source, Path.dirname(long)))
          File.write!(Path.join(source, long), "long\n")
        end)

      docs =
        fixture(dir, "docs", fn source ->
          File.mkdir_p!(Path.join(source, "nested/dir"))
          File.write!(Path.join(source, "README.md"), "# docs\n")
          File.write!(Path.join(source, "nested/dir/file.txt"), "nested\n")
        end)

      bad =
        fixture(dir, "bad", fn source ->
          File.write!(Path.join(source, "ok.txt"), "ok\n")
          File.ln_s!("../outside", Path.join(source, "up"))
          File.ln_s!("/etc/passwd", Path.join(source, "abs"))
          # An embedded repository is committed as a gitlink (mode 160000).
          File.mkdir!(Path.join(source, "vendor"))
          fixture(Path.join(source, "vendor"), "sub", &File.write!(Path.join(&1, "x"), "x\n"))
        end)

      repositories =
        for {name, {source, _}} <- [app: app, docs: docs, bad: bad],
            into: %{},
            do: {"github.com/test/#{name}", "file://" <> source}

      {home, port} = serve(dir, "snapshots-home", repositories)
      %{port: port, app: app, docs: docs, bad: bad, home: home}
    end

    test "two repositories at exact commits give a stable ID, a manifest of blob bytes and exact archives",
         %{
           tmp_dir: dir,
           port: port,
           app: {app, app_commit},
           docs: {docs, docs_commit},
           home: home
         } do
      repositories = [
        %{
          "repository" => "github.com/test/docs",
          "commit" => docs_commit,
          "path" => "vendor/docs"
        },
        %{"repository" => "github.com/test/app", "commit" => app_commit, "path" => "app"}
      ]

      assert {200, %{"snapshot_id" => "sha256:" <> hex = id, "repositories" => listed} = created} =
               snapshot(port, repositories)

      assert listed == Enum.reverse(repositories)
      # The source moving on does not change the snapshot of its exact commit.
      File.write!(Path.join(app, "later.txt"), "later\n")
      git(app, ["add", "-A"])
      git(app, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "later"])
      assert {200, ^created} = snapshot(port, Enum.reverse(repositories))

      assert {200,
              %{"snapshot_id" => ^id, "entries" => entries, "repositories" => ^listed} = manifest} =
               request(port, :get, "/v1/snapshots/#{id}/manifest")

      # The ID is the SHA-256 of the canonical manifest JSON, recomputable from the response.
      canonical = JSON.encode!(Map.delete(manifest, "snapshot_id"))
      assert hex == Base.encode16(:crypto.hash(:sha256, canonical), case: :lower)
      assert File.read!(Path.join([home, "snapshots", hex <> ".json"])) == canonical
      assert Enum.map(entries, & &1["path"]) == Enum.sort(Enum.map(entries, & &1["path"]))

      git(app, ["reset", "-q", "--hard", app_commit])

      for {source, root, repository} <- [
            {app, "app", "github.com/test/app"},
            {docs, "vendor/docs", "github.com/test/docs"}
          ] do
        own = Enum.filter(entries, &(&1["repository"] == repository))

        expected =
          source
          |> git(["ls-files"])
          |> String.split("\n", trim: true)
          |> Enum.map(&(root <> "/" <> &1))

        assert Enum.map(own, & &1["path"]) == Enum.sort(expected)

        for %{"path" => path} = entry <- own do
          file = Path.join(source, String.replace_prefix(path, root <> "/", ""))
          bytes = if entry["kind"] == "symlink", do: File.read_link!(file), else: File.read!(file)
          assert entry["sha256"] == Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
          assert entry["size"] == byte_size(bytes)
        end

        {200, tar} = archive(port, id, root)
        assert {200, ^tar} = archive(port, id, root)
        # Deterministic headers: mtime, uid and gid are zero.
        <<_name::binary-100, _mode::binary-8, uid::binary-8, gid::binary-8, _size::binary-12,
          mtime::binary-12, _::binary>> = tar

        assert {uid, gid, mtime} == {"0000000\0", "0000000\0", "00000000000\0"}

        out = Path.join(dir, "out-" <> Path.basename(root))
        File.mkdir_p!(out)
        File.write!(out <> ".tar", tar)
        {_, 0} = System.cmd("tar", ["-xf", out <> ".tar", "-C", out])

        extracted =
          out |> Path.join("**") |> Path.wildcard(match_dot: true) |> Enum.reject(&File.dir?/1)

        assert Enum.sort(Enum.map(extracted, &(root <> "/" <> Path.relative_to(&1, out)))) ==
                 Enum.map(own, & &1["path"])

        refute File.exists?(Path.join(out, ".git"))

        for %{"path" => path} = entry <- own do
          file = Path.join(out, String.replace_prefix(path, root <> "/", ""))

          case entry do
            %{"kind" => "symlink"} ->
              assert File.read_link!(file) == entry["target"]

            %{"kind" => "file", "mode" => mode} ->
              assert Base.encode16(:crypto.hash(:sha256, File.read!(file)), case: :lower) ==
                       entry["sha256"]

              assert Bitwise.band(File.lstat!(file).mode, 0o111) != 0 == (mode == "100755")
          end
        end
      end

      by_path = Map.new(entries, &{&1["path"], &1})
      assert %{"kind" => "file", "mode" => "100755"} = by_path["app/bin/run.sh"]

      assert %{"kind" => "symlink", "mode" => "120000", "target" => "../data/blob.bin"} =
               by_path["app/lib/link"]

      refute Map.has_key?(by_path["app/data/blob.bin"], "target")
      assert File.read!(Path.join(dir, "out-app/version.txt")) == "$Format:%H$\n"
      assert File.read!(Path.join(dir, "out-app/data/blob.bin")) == <<0, 1, 2, 255, 0, 10, 13>>
    end

    test "unknown commits, unsafe paths, forbidden repositories and unsupported content are refused",
         %{port: port, app: {_, app_commit}, bad: {_, bad_commit}} do
      entry = fn path ->
        %{"repository" => "github.com/test/app", "commit" => app_commit, "path" => path}
      end

      assert {404,
              %{
                "error" => %{
                  "code" => "not_found",
                  "details" => %{"commit" => "0000000000000000000000000000000000000000"}
                }
              }} =
               snapshot(port, [%{entry.("app") | "commit" => String.duplicate("0", 40)}])

      for path <- [
            "../x",
            "/abs",
            "a/../b",
            "a//b",
            "a/",
            "./a",
            "a\\b",
            ".git",
            "x/.GIT",
            "",
            "a\nb"
          ] do
        assert {400,
                %{"error" => %{"code" => "invalid_request", "details" => %{"path" => ^path}}}} =
                 snapshot(port, [entry.(path)])
      end

      for paths <- [["a", "a"], ["a", "a/b"], ["x/y/z", "x/y"]] do
        assert {400,
                %{"error" => %{"code" => "invalid_request", "details" => %{"paths" => [_, _]}}}} =
                 snapshot(port, Enum.map(paths, entry))
      end

      for commit <- ["abc", String.upcase(app_commit), app_commit <> "0"] do
        assert {400, %{"error" => %{"code" => "invalid_request"}}} =
                 snapshot(port, [%{entry.("a") | "commit" => commit}])
      end

      for body <- [
            "[]",
            ~s({"repositories": []}),
            JSON.encode!(%{"repositories" => [Map.put(entry.("a"), "x", 1)]})
          ] do
        assert {400, %{"error" => %{"code" => "invalid_request"}}} =
                 raw(port, :post, "/v1/snapshots", body)
      end

      assert {403, %{"error" => %{"code" => "forbidden"}}} =
               snapshot(port, [%{entry.("a") | "repository" => "github.com/test/other"}])

      assert {422,
              %{
                "error" => %{
                  "code" => "unsupported_content",
                  "details" => %{"entries" => refused}
                }
              }} =
               snapshot(port, [
                 %{"repository" => "github.com/test/bad", "commit" => bad_commit, "path" => "bad"}
               ])

      assert Enum.sort_by(refused, & &1["path"]) == [
               %{
                 "repository" => "github.com/test/bad",
                 "path" => "abs",
                 "reason" => "symlink_target"
               },
               %{
                 "repository" => "github.com/test/bad",
                 "path" => "up",
                 "reason" => "symlink_target"
               },
               %{
                 "repository" => "github.com/test/bad",
                 "path" => "vendor/sub",
                 "reason" => "submodule"
               }
             ]

      unknown = "sha256:" <> String.duplicate("0", 64)

      assert {404, %{"error" => %{"code" => "not_found"}}} =
               request(port, :get, "/v1/snapshots/#{unknown}/manifest")

      assert {404, %{"error" => %{"code" => "not_found"}}} =
               request(port, :get, "/v1/snapshots/#{unknown}/archive?path=app")

      assert {400, %{"error" => %{"code" => "invalid_request"}}} =
               request(port, :get, "/v1/snapshots/sha256:../manifest")

      assert {400, %{"error" => %{"code" => "invalid_request"}}} =
               request(port, :get, "/v1/snapshots/abc/archive?path=app")

      {200, %{"snapshot_id" => id}} = snapshot(port, [entry.("app")])

      assert {404, %{"error" => %{"code" => "not_found", "details" => %{"path" => "other"}}}} =
               request(port, :get, "/v1/snapshots/#{id}/archive?path=other")

      assert {404, %{"error" => %{"code" => "not_found"}}} =
               request(port, :get, "/v1/snapshots/#{id}/archive")

      assert {404, %{"error" => %{"code" => "not_found"}}} =
               request(port, :get, "/v1/snapshots/#{id}/other")

      assert {405, %{"error" => %{"code" => "method_not_allowed"}}} =
               request(port, :get, "/v1/snapshots")
    end
  end

  describe "changes" do
    setup %{tmp_dir: dir} do
      {source, base} =
        fixture(dir, "app", fn source ->
          for {path, bytes} <- [
                {"README.md", "hello\n"},
                {"bin/run.sh", "#!/bin/sh\necho hi\n"},
                {"data/blob.bin", <<0, 1, 2, 255>>},
                {"dir/a.txt", "a\n"},
                {"dir/b.txt", "b\n"},
                {"old", "old\n"},
                # Line-ending filters must not touch submitted bytes.
                {".gitattributes", "*.txt text eol=crlf\n"}
              ] do
            File.mkdir_p!(Path.dirname(Path.join(source, path)))
            File.write!(Path.join(source, path), bytes)
          end

          File.mkdir_p!(Path.join(source, "lib"))
          File.ln_s!("../README.md", Path.join(source, "lib/link"))
        end)

      {home, port} =
        serve(dir, "changes-home", %{
          "github.com/test/app" => "file://" <> source,
          "github.com/test/other" => "file://" <> source
        })

      {200, %{"snapshot_id" => snapshot_id}} =
        snapshot(port, [%{"repository" => "github.com/test/app", "commit" => base, "path" => "app"}])

      # The source branch moves on after the snapshot; changes still build on the snapshot base.
      File.write!(Path.join(source, "later.txt"), "later\n")
      git(source, ["add", "-A"])
      git(source, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "later"])

      [cache] = Path.wildcard(Path.join([home, "cache", "*.git"]))

      change = fn id, entries ->
        %{
          "change_id" => id,
          "snapshot_id" => snapshot_id,
          "repository" => "github.com/test/app",
          "base_commit" => base,
          "entries" => entries
        }
      end

      %{port: port, home: home, source: source, base: base, cache: cache, change: change}
    end

    test "a mixed change uploads, seals onto the exact base and stays private", %{
      port: port,
      source: source,
      base: base,
      cache: cache,
      change: change
    } do
      id = "7d444840-9dc0-11d1-b245-5ffdce74fad2"
      big = :crypto.strong_rand_bytes(200_000)

      files = %{
        "README.md" => "hello again\n",
        "assets/big.bin" => big,
        "assets/logo.bin" => <<0, 255, 1, 254, 0>>,
        "notes.txt" => "one\r\ntwo\r\n",
        "dir" => "a file where a directory was\n",
        "old/new.txt" => "a directory where a file was\n"
      }

      script = "#!/bin/sh\necho hi\n"

      entries =
        Enum.map(files, fn {path, bytes} -> write(path, bytes) end) ++
          [
            write("bin/run.sh", script, "100755"),
            symlink("lib/link", "../bin/run.sh"),
            symlink("docs/readme", "../README.md")
          ] ++
          for(path <- ["data/blob.bin", "dir/a.txt", "dir/b.txt", "old"], do: delete(path))

      source_refs = git(source, ["for-each-ref"])
      heads = git(cache, ["for-each-ref", "refs/heads"])
      expected = [script | Map.values(files)] |> Enum.map(&hex/1) |> Enum.uniq() |> Enum.sort()

      assert {200, %{"change_id" => ^id, "state" => "open", "missing" => ^expected} = open} =
               submit(port, change.(id, entries))

      refute Map.has_key?(open, "commit")
      # Entry order does not matter; any other body under the same ID conflicts.
      assert {200, ^open} = submit(port, change.(id, Enum.reverse(entries)))

      assert {409, %{"error" => %{"code" => "conflict"}}} =
               submit(port, change.(id, tl(entries)))

      assert {422,
              %{"error" => %{"code" => "incomplete_upload", "details" => %{"missing" => ^expected}}}} =
               seal(port, id)

      readme = files["README.md"]

      assert {400, %{"error" => %{"code" => "invalid_request"}}} =
               upload(port, id, hex(readme), String.duplicate("x", byte_size(readme)))

      assert {400, %{"error" => %{"code" => "invalid_request"}}} =
               upload(port, id, hex(readme), readme <> "x")

      assert {404, %{"error" => %{"code" => "not_found"}}} =
               upload(port, id, hex("unreferenced"), "unreferenced")

      remaining = expected -- [hex(readme)]
      assert {200, %{"state" => "open", "missing" => ^remaining}} = upload(port, id, hex(readme), readme)
      assert {200, %{"missing" => ^remaining}} = upload(port, id, hex(readme), readme)

      for bytes <- [script | Map.values(files)] do
        assert {200, %{"state" => "open"}} = upload(port, id, hex(bytes), bytes)
      end

      assert {200, %{"state" => "open", "missing" => []}} = submit(port, change.(id, entries))

      assert {200, %{"change_id" => ^id, "state" => "sealed", "missing" => [], "commit" => commit} =
                sealed} = seal(port, id)

      assert {200, ^sealed} = seal(port, id)
      assert {200, ^sealed} = submit(port, change.(id, entries))

      # Exactly one parent, the snapshot base, although the source branch has moved on.
      assert git(cache, ["rev-parse", commit <> "^@"]) == base <> "\n"
      refute git(source, ["rev-parse", "develop"]) == base <> "\n"
      assert git(cache, ["rev-parse", "refs/atlas/changes/" <> id]) == commit <> "\n"

      assert git(cache, ["log", "-1", "--format=%an <%ae>|%cn <%ce>|%s", commit]) ==
               "Atlas Code <atlas-code@localhost>|Atlas Code <atlas-code@localhost>|Atlas change #{id}\n"

      tree =
        for record <-
              cache
              |> git(["ls-tree", "-r", "-z", "--full-tree", commit])
              |> :binary.split(<<0>>, [:global, :trim_all]),
            into: %{} do
          [meta, path] = :binary.split(record, "\t")
          [mode, "blob", oid] = String.split(meta, " ")
          {path, {mode, git(cache, ["cat-file", "blob", oid])}}
        end

      assert tree ==
               files
               |> Map.new(fn {path, bytes} -> {path, {"100644", bytes}} end)
               |> Map.merge(%{
                 ".gitattributes" => {"100644", "*.txt text eol=crlf\n"},
                 "bin/run.sh" => {"100755", script},
                 "lib/link" => {"120000", "../bin/run.sh"},
                 "docs/readme" => {"120000", "../README.md"}
               })

      # Nothing was published: no remote ref moved and the remote never received the commit.
      assert git(cache, ["for-each-ref", "refs/heads"]) == heads
      assert git(source, ["for-each-ref"]) == source_refs
      assert {_, status} = System.cmd("git", ["cat-file", "-e", commit], cd: source, stderr_to_stdout: true)
      assert status != 0
    end

    test "base mismatches, unknown targets and unsafe or conflicting entries are refused", %{
      port: port,
      home: home,
      change: change
    } do
      id = "1b4e28ba-2fa1-11d2-883f-0016d3cca427"
      ok = [write("README.md", "x\n")]

      assert {409, %{"error" => %{"code" => "base_mismatch"}}} =
               submit(port, %{change.(id, ok) | "base_commit" => String.duplicate("a", 40)})

      assert {404, %{"error" => %{"code" => "not_found"}}} =
               submit(port, %{change.(id, ok) | "snapshot_id" => "sha256:" <> String.duplicate("0", 64)})

      assert {404, %{"error" => %{"code" => "not_found", "details" => %{"repository" => _}}}} =
               submit(port, %{change.(id, ok) | "repository" => "github.com/test/other"})

      assert {403, %{"error" => %{"code" => "forbidden"}}} =
               submit(port, %{change.(id, ok) | "repository" => "github.com/test/denied"})

      for bad <- ["x", String.upcase(id), id <> "0"] do
        assert {400, %{"error" => %{"code" => "invalid_request"}}} =
                 submit(port, change.(bad, ok))
      end

      for path <- ["../x", "/abs", "a//b", ".git/config", "x/.GIT", "a\\b", ""] do
        assert {400, %{"error" => %{"code" => "invalid_request", "details" => %{"path" => ^path}}}} =
                 submit(port, change.(id, [write(path, "x")]))
      end

      for entries <- [
            [],
            [write("a", "x"), write("a", "x")],
            [Map.delete(write("a", "x"), "kind")],
            [Map.put(write("a", "x"), "extra", 1)],
            [%{write("a", "x") | "mode" => "100664"}],
            [%{write("a", "x") | "size" => 64 * 1024 * 1024 + 1}],
            [%{write("a", "x") | "sha256" => String.upcase(hex("x"))}],
            [%{symlink("a", "README.md") | "sha256" => hex("other")}],
            [%{symlink("a", "README.md") | "size" => 1}],
            [write("a", "x"), %{write("b", "x") | "size" => 2}],
            # Deletes must name base files or symlinks, never directories or absent paths.
            [delete("missing")],
            [delete("dir")],
            # Replacing a directory or a file needs explicit deletes of the base paths.
            [write("dir", "x")],
            [delete("dir/a.txt"), write("dir", "x")],
            [write("README.md/x", "x")],
            [write("lib/link/x", "x")],
            [write("new", "x"), write("new/x", "x")]
          ] do
        assert {400, %{"error" => %{"code" => "invalid_request"}}} =
                 submit(port, change.(id, entries))
      end

      assert {400, %{"error" => %{"details" => %{"paths" => ["dir", "dir/b.txt"]}}}} =
               submit(port, change.(id, [delete("dir/a.txt"), write("dir", "x")]))

      for target <- ["../../x", "/etc/passwd", "../.."] do
        assert {422,
                %{
                  "error" => %{
                    "code" => "unsupported_content",
                    "details" => %{"entries" => [%{"path" => "lib/up", "reason" => "symlink_target"}]}
                  }
                }} = submit(port, change.(id, [symlink("lib/up", target)]))
      end

      refute File.exists?(Path.join([home, "changes", id]))

      for {method, path} <- [{:put, "/blobs/#{hex("x")}"}, {:post, "/seal"}] do
        assert {404, %{"error" => %{"code" => "not_found"}}} =
                 raw(port, method, "/v1/changes/#{id}" <> path, "x")

        assert {400, %{"error" => %{"code" => "invalid_request"}}} =
                 raw(port, method, "/v1/changes/x" <> path, "x")
      end

      assert {405, %{"error" => %{"code" => "method_not_allowed"}}} =
               request(port, :get, "/v1/changes")

      # JSON endpoints keep their own small limits even though blob uploads may be large.
      assert {413, %{"error" => %{"code" => "payload_too_large"}}} =
               raw(port, :post, "/v1/snapshots", :binary.copy(" ", 20_000))

      assert {413, %{"error" => %{"code" => "payload_too_large"}}} =
               raw(port, :post, "/v1/changes", :binary.copy(" ", 1024 * 1024 + 1))
    end
  end

  defp serve(dir, name, repositories) do
    home = Path.join(dir, name)
    File.mkdir!(home)

    File.write!(
      Path.join(home, "config.json"),
      JSON.encode!(%{"port" => 0, "repositories" => repositories})
    )

    File.write!(Path.join(home, "runtime.token"), @token <> "\n")
    File.chmod!(Path.join(home, "runtime.token"), 0o600)
    {:ok, pid, port} = AtlasCode.start(home)
    on_exit(fn -> AtlasCode.stop(pid) end)
    {home, port}
  end

  defp write(path, bytes, mode \\ "100644"),
    do: %{
      "path" => path,
      "op" => "write",
      "kind" => "file",
      "mode" => mode,
      "size" => byte_size(bytes),
      "sha256" => hex(bytes)
    }

  defp symlink(path, target),
    do: %{
      "path" => path,
      "op" => "write",
      "kind" => "symlink",
      "mode" => "120000",
      "target" => target,
      "size" => byte_size(target),
      "sha256" => hex(target)
    }

  defp delete(path), do: %{"path" => path, "op" => "delete"}
  defp hex(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
  defp submit(port, change), do: raw(port, :post, "/v1/changes", JSON.encode!(change))
  defp upload(port, id, digest, bytes), do: raw(port, :put, "/v1/changes/#{id}/blobs/#{digest}", bytes)
  defp seal(port, id), do: raw(port, :post, "/v1/changes/#{id}/seal", "")

  defp fixture(dir, name, build) do
    source = Path.join(dir, name)
    git(dir, ["init", "-q", "-b", "develop", source])
    build.(source)
    git(source, ["add", "-A"])
    git(source, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", name])
    {source, source |> git(["rev-parse", "HEAD"]) |> String.trim()}
  end

  defp snapshot(port, repositories),
    do: raw(port, :post, "/v1/snapshots", JSON.encode!(%{"repositories" => repositories}))

  defp archive(port, id, path),
    do:
      send_request(
        port,
        :get,
        "/v1/snapshots/#{id}/archive?path=#{URI.encode_www_form(path)}",
        "",
        [{~c"authorization", ~c"Bearer " ++ String.to_charlist(@token)}]
      )

  defp resolve(port, body), do: raw(port, :post, "/v1/revisions/resolve", JSON.encode!(body))
  defp request(port, method, path), do: raw(port, method, path, "")

  defp raw(port, method, path, body) do
    {status, reply} =
      send_request(port, method, path, body, [
        {~c"authorization", ~c"Bearer " ++ String.to_charlist(@token)}
      ])

    {status, JSON.decode!(reply)}
  end

  defp send_request(port, method, path, body, headers) do
    url = ~c"http://127.0.0.1:#{port}#{path}"

    request =
      if method in [:post, :put],
        do: {url, headers, ~c"application/json", body},
        else: {url, headers}

    {:ok, {{_, status, _}, _, reply}} =
      :httpc.request(method, request, [timeout: 10_000, ssl: []], body_format: :binary)

    {status, reply}
  end

  defp git(dir, args) do
    {output, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    output
  end
end
