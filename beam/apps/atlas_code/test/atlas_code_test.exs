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
    body = JSON.encode!(%{"repository" => "github.com/test/fixture", "ref" => "develop"})

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
            {:get, "/v1/snapshots/sha256:#{String.duplicate("0", 64)}/archive?path=app"}
          ] do
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
    setup %{tmp_dir: dir, home: home} do
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

      snapshots_home = Path.join(dir, "snapshots-home")
      File.mkdir!(snapshots_home)

      File.write!(
        Path.join(snapshots_home, "config.json"),
        JSON.encode!(%{"port" => 0, "repositories" => repositories})
      )

      File.cp!(Path.join(home, "runtime.token"), Path.join(snapshots_home, "runtime.token"))
      File.chmod!(Path.join(snapshots_home, "runtime.token"), 0o600)
      {:ok, pid, port} = AtlasCode.start(snapshots_home)
      on_exit(fn -> AtlasCode.stop(pid) end)
      %{port: port, app: app, docs: docs, bad: bad, home: snapshots_home}
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
      if method == :post, do: {url, headers, ~c"application/json", body}, else: {url, headers}

    {:ok, {{_, status, _}, _, reply}} =
      :httpc.request(method, request, [timeout: 10_000, ssl: []], body_format: :binary)

    {status, reply}
  end

  defp git(dir, args) do
    {output, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    output
  end
end
