defmodule AtlasCodeTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  setup {AtlasCode.TestDir, :tmp_dir}
  @token "runtime-secret-token"
  @orchestrator "orchestrator-secret-token"
  @attribution "\n\n<sub>Written by an AI agent (test).</sub>\n"
  # Fixture provider, not GitHub: records each call; `fail-before`/`fail-after` files make
  # `pr create` fail before or after it creates the pull request.
  @gh """
  #!/bin/sh
  state=$(dirname "$0")
  echo "$GH_PROMPT_DISABLED $*" >> "$state/gh-calls"
  case "$1 $2" in
    "pr list")
      if [ -e "$state/pr-url" ]; then printf '[{"url":"%s"}]\\n' "$(cat "$state/pr-url")"; else echo '[]'; fi ;;
    "pr create")
      if [ -e "$state/fail-before" ]; then echo "ghp_secret failed" >&2; exit 1; fi
      for arg; do case "$arg" in --body-file=*) cp "${arg#--body-file=}" "$state/pr-body" ;; esac; done
      echo https://github.com/test/app/pull/7 > "$state/pr-url"
      if [ -e "$state/fail-after" ]; then echo "ghp_secret lost" >&2; exit 1; fi
      cat "$state/pr-url" ;;
    *) exit 2 ;;
  esac
  """

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
    %{home: home, pid: pid, port: port, commit: commit, source: source}
  end

  test "health reports the service with the runtime token", %{port: port} do
    assert {200, %{"service" => "atlas-code", "version" => "0.1.0"}} =
             request(port, :get, "/v1/health")
  end

  test "resolve maps a named reference to a durable opaque revision", %{
    port: port,
    home: home,
    commit: commit,
    source: source
  } do
    assert {200,
            %{
              "repository" => "github.com/test/fixture",
              "reference" => "develop",
              "revision" => revision
            } =
              reply} = resolve(port, "github.com/test/fixture", "develop")

    assert map_size(reply) == 3
    assert revision =~ ~r/\Arev_[0-9a-f]{64}\z/
    refute JSON.encode!(reply) =~ commit
    assert {200, ^reply} = resolve(port, "github.com/test/fixture", "develop")

    # The mapping is Code's own record, written before the reply.
    assert JSON.decode!(File.read!(Path.join([home, "revisions", revision <> ".json"]))) ==
             %{"commit" => commit, "repository" => "github.com/test/fixture"}

    # Only refs/heads/<reference> counts, not a longer name ending in it.
    git(source, ["branch", "nested/develop"])
    git(source, ["branch", "-m", "develop", "main"])

    assert {404, %{"error" => %{"code" => "unknown_reference"}}} =
             resolve(port, "github.com/test/fixture", "develop")
  end

  test "unknown references, forbidden repositories, invalid and legacy requests are refused", %{
    port: port
  } do
    assert {404,
            %{
              "error" => %{
                "code" => "unknown_reference",
                "details" => %{"reference" => "missing"}
              }
            }} =
             resolve(port, "github.com/test/fixture", "missing")

    assert {403, %{"error" => %{"code" => "forbidden"}}} =
             resolve(port, "github.com/test/other", "develop")

    for body <- [
          "not json",
          "[]",
          JSON.encode!(%{"repository" => "github.com/test/fixture"}),
          JSON.encode!(%{"repository" => "github.com/test/fixture", "ref" => "develop"}),
          JSON.encode!(%{"repository" => "github.com/test/fixture", "branch" => "develop"}),
          JSON.encode!(%{
            "repository" => "github.com/test/fixture",
            "reference" => "develop",
            "extra" => 1
          }),
          JSON.encode!(%{"repository" => "github.com/test/fixture", "reference" => 1}),
          JSON.encode!(%{"repository" => "github.com/test/fixture", "reference" => "../x"}),
          JSON.encode!(%{"repository" => "github.com/test/fixture", "reference" => "-x"}),
          JSON.encode!(%{"repository" => "github.com/test/fixture", "reference" => "a\u0000b"})
        ] do
      assert {400, %{"error" => %{"code" => "invalid_request", "details" => %{}}}} =
               raw(port, :post, "/v1/references/resolve", body)
    end

    # The commit-based endpoints are gone, not translated.
    for path <- ["/v1/revisions/resolve", "/v1/publications", "/v1/other"] do
      assert {404, %{"error" => %{"code" => "not_found"}}} = raw(port, :post, path, "{}")
    end

    assert {405, %{"error" => %{"code" => "method_not_allowed"}}} =
             request(port, :get, "/v1/references/resolve")
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
             resolve(port, "github.com/test/gone", "develop")

    refute message =~ dir
    # A handle Code recorded earlier, whose remote has since gone away.
    revision = AtlasCode.put_revision(other, "github.com/test/gone", String.duplicate("a", 40))

    snapshot = %{
      "repositories" => [
        %{"repository" => "github.com/test/gone", "revision" => revision, "path" => "gone"}
      ]
    }

    assert {503, %{"error" => %{"code" => "provider_unavailable", "message" => message}}} =
             raw(port, :post, "/v1/snapshots", JSON.encode!(snapshot))

    refute message =~ dir
    AtlasCode.stop(pid)
  end

  test "missing or wrong bearer tokens are unauthorized without echoing them", %{port: port} do
    change = "/v1/changes/00000000-0000-4000-8000-000000000000"
    json = JSON.encode!(%{"repository" => "github.com/test/fixture", "reference" => "develop"})
    # Larger than one 64 KiB chunk, so the token is checked on the first streamed piece.
    big = :binary.copy("x", 200_000)

    for headers <- [
          [],
          [{~c"authorization", ~c"Bearer wrong-token"}],
          [{~c"authorization", ~c"Basic " ++ String.to_charlist(@token)}]
        ] do
      for {method, path} <- [
            {:get, "/v1/health"},
            {:post, "/v1/references/resolve"},
            {:get, "/v1/other"},
            {:post, "/v1/snapshots"},
            {:get, "/v1/snapshots/sha256:#{String.duplicate("0", 64)}/manifest"},
            {:get, "/v1/snapshots/sha256:#{String.duplicate("0", 64)}/archive?path=app"},
            {:post, "/v1/changes"},
            {:put, "#{change}/blobs/#{String.duplicate("0", 64)}"},
            {:post, "#{change}/seal"},
            {:post, "/v1/reviews"},
            {:post, "/v1/integrations"}
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

  test "start refuses an invalid orchestrator token file", %{home: home} do
    orchestrator = Path.join(home, "orchestrator.token")
    File.write!(orchestrator, @orchestrator)
    File.chmod!(orchestrator, 0o644)
    assert_raise RuntimeError, ~r/owner-only/, fn -> AtlasCode.start(home) end
    File.rm!(orchestrator)
    File.ln_s!(Path.join(home, "runtime.token"), orchestrator)
    assert_raise RuntimeError, ~r/owner-only/, fn -> AtlasCode.start(home) end
    File.rm!(orchestrator)
    File.write!(orchestrator, @token)
    File.chmod!(orchestrator, 0o600)
    assert_raise RuntimeError, ~r/must differ/, fn -> AtlasCode.start(home) end
  end

  describe "ownership" do
    test "a running service owns its home; a second service or migration is refused and releasing keeps a tombstone",
         %{home: home, pid: pid, port: port} do
      assert %{"kind" => "service", "os_pid" => os_pid, "owner" => id} = record = owner(home)
      assert os_pid == String.to_integer(System.pid())
      error = assert_raise RuntimeError, fn -> AtlasCode.start(home) end
      assert error.message =~ "is owned by service pid #{os_pid}"
      assert error.message =~ "mix atlas_code.unlock --owner #{id}"
      refute error.message =~ @token
      assert_raise RuntimeError, ~r/is owned by service/, fn -> AtlasCode.Migration.run(home) end
      assert owner(home) == record
      assert {200, _} = request(port, :get, "/v1/health")

      assert :ok = AtlasCode.stop(pid)
      refute File.exists?(Path.join(home, "service.owner"))

      assert JSON.decode!(
               File.read!(Path.join([home, "service.owner.ended-" <> id, "owner.json"]))
             ) == record

      assert %{"changes" => 0, "reviews" => 0, "snapshots" => 0} = AtlasCode.Migration.run(home)
      {:ok, pid, _port} = AtlasCode.start(home)
      assert :ok = AtlasCode.stop(pid)

      kinds =
        for t <- Path.wildcard(Path.join(home, "service.owner.ended-*")),
            do: JSON.decode!(File.read!(Path.join(t, "owner.json")))["kind"]

      assert Enum.sort(kinds) == ["migration", "service", "service"]
      assert Path.wildcard(Path.join(home, "service.owner.*.tmp")) == []
    end

    test "an owner that exits abnormally never frees a home its server still uses", %{
      home: home,
      pid: pid
    } do
      :ok = AtlasCode.stop(pid)
      parent = self()

      starter =
        spawn(fn ->
          {:ok, pid, port} = AtlasCode.start(home)
          send(parent, {:started, pid, port})
          Process.sleep(:infinity)
        end)

      assert_receive {:started, pid, port}, 10_000
      ref = Process.monitor(starter)
      Process.exit(starter, :kill)
      assert_receive {:DOWN, ^ref, :process, ^starter, :killed}
      record = owner(home)

      assert {200, _} = request(port, :get, "/v1/health")
      assert_raise RuntimeError, ~r/is owned by service/, fn -> AtlasCode.start(home) end
      assert_raise RuntimeError, ~r/is owned by service/, fn -> AtlasCode.Migration.run(home) end
      assert owner(home) == record

      assert :ok = AtlasCode.stop(pid)
      assert File.exists?(Path.join(home, "service.owner.ended-" <> record["owner"]))
    end

    test "of concurrent starts exactly one owns the home", %{home: home, pid: pid} do
      :ok = AtlasCode.stop(pid)

      results =
        1..4
        |> Enum.map(fn _ ->
          Task.async(fn ->
            try do
              {:ok, AtlasCode.start(home)}
            rescue
              error -> {:error, error.message}
            end
          end)
        end)
        |> Task.await_many(30_000)

      assert [{:ok, {:ok, pid, _port}}] = Enum.filter(results, &match?({:ok, _}, &1))
      refused = for {:error, message} <- results, do: message
      assert length(refused) == 3 and Enum.all?(refused, &(&1 =~ "is owned by service"))
      assert :ok = AtlasCode.stop(pid)
      assert Path.wildcard(Path.join(home, "service.owner.*.tmp")) == []
    end

    test "a late or duplicate release never touches a newer owner", %{home: home, pid: pid} do
      first = owner(home)["owner"]
      assert :ok = AtlasCode.stop(pid)
      {:ok, newer, port} = AtlasCode.start(home)
      record = owner(home)

      refute AtlasCode.stop(pid) == :ok
      assert {:error, _} = AtlasCode.release(home, first)
      assert owner(home) == record
      assert {200, _} = request(port, :get, "/v1/health")
      assert :ok = AtlasCode.stop(newer)
      refute AtlasCode.stop(newer) == :ok
      assert {:error, _} = AtlasCode.release(home, record["owner"])
    end

    test "a stale owner is recovered, by start or unlock, only when ps proves it stopped",
         %{
           tmp_dir: dir,
           home: home,
           pid: pid
         } do
      :ok = AtlasCode.stop(pid)
      stale = stale_owner(home, 4_000_000)
      record = owner(home)
      absent = ps(dir, "absent", "exit 1")
      running = ps(dir, "running", ~s(echo "  $2"))

      # A ps that cannot see this process and PID 1 proves nothing by its silence.
      blind = Path.join(dir, "ps-blind")
      File.write!(blind, "#!/bin/sh\nexit 1\n")
      File.chmod!(blind, 0o755)

      undecided = [
        blind,
        ps(dir, "failing", "echo 'ps: cannot read processes' >&2; exit 2"),
        ps(dir, "warning", "echo 'ps: warning' >&2; exit 1"),
        ps(dir, "noisy", "echo oops; exit 1"),
        ps(dir, "other", "echo 12345"),
        ps(dir, "silent", "exit 0"),
        Path.join(dir, "no-such-ps")
      ]

      # A start whose ps shows the PID running (or reused), or cannot tell, is refused as
      # before and moves nothing; a migration never recovers.
      for script <- [running | undecided] do
        error = assert_raise RuntimeError, fn -> AtlasCode.start(home, ps: script) end
        assert error.message =~ "is owned by service pid 4000000"
        assert error.message =~ "mix atlas_code.unlock --owner #{stale}"
        assert owner(home) == record
      end

      assert_raise RuntimeError, ~r/is owned by service/, fn -> AtlasCode.Migration.run(home) end

      for script <- undecided do
        assert {:error, message} = AtlasCode.unlock(home, stale, script)
        assert message =~ "cannot establish that pid 4000000 has stopped"
      end

      assert {:error, message} = AtlasCode.unlock(home, stale, running)
      assert message =~ "still running"
      assert {:error, message} = AtlasCode.unlock(home, String.duplicate("0", 32), absent)
      assert message =~ "is owned by #{stale}"

      for pid <- ["4000000", 0, -1, nil] do
        File.write!(
          Path.join([home, "service.owner", "owner.json"]),
          JSON.encode!(%{record | "os_pid" => pid})
        )

        assert {:error, message} = AtlasCode.unlock(home, stale, absent)
        assert message =~ "no valid pid"
      end

      File.write!(Path.join([home, "service.owner", "owner.json"]), JSON.encode!(record))
      assert owner(home) == record
      assert Path.wildcard(Path.join(home, "service.owner.ended-*")) |> length() == 1

      tombstone = Path.join(home, "service.owner.ended-" <> stale)
      assert {:ok, {:recovered, ^tombstone}} = AtlasCode.unlock(home, stale, absent)
      assert JSON.decode!(File.read!(Path.join(tombstone, "owner.json"))) == record
      assert {:ok, :not_owned} = AtlasCode.unlock(home, stale, absent)

      # A live owner is never recovered: not by the real ps, whatever it can see here, nor by
      # a ps that would call every other PID absent.
      {:ok, pid, _port} = AtlasCode.start(home)
      live = owner(home)
      assert {:error, _} = AtlasCode.unlock(home, live["owner"])
      assert {:error, message} = AtlasCode.unlock(home, live["owner"], absent)
      assert message =~ "still running"
      assert owner(home) == live
      assert :ok = AtlasCode.stop(pid)
    end

    test "a start recovers an owner whose process is gone, keeps its tombstone and logs it; later starts are normal",
         %{tmp_dir: dir, home: home, pid: pid} do
      :ok = AtlasCode.stop(pid)
      absent = ps(dir, "absent", "exit 1")
      stale = stale_owner(home, 4_000_000)
      record = owner(home)

      log =
        capture_log(fn -> send(self(), {:started, AtlasCode.start(home, ps: absent)}) end)

      assert_received {:started, {:ok, pid, port}}
      assert log =~ "Code recovered #{home} from stopped owner #{stale} (service pid 4000000"
      tombstone = Path.join(home, "service.owner.ended-" <> stale)
      assert JSON.decode!(File.read!(Path.join(tombstone, "owner.json"))) == record
      service = owner(home)
      assert service["os_pid"] == String.to_integer(System.pid())
      refute service["owner"] == stale
      assert {200, _} = request(port, :get, "/v1/health")

      # The new owner is alive: even a ps calling every other PID absent cannot take it.
      error = assert_raise RuntimeError, fn -> AtlasCode.start(home, ps: absent) end
      assert error.message =~ "is owned by service pid #{System.pid()}"
      assert owner(home) == service
      assert :ok = AtlasCode.stop(pid)

      # Restarting a released home recovers nothing and logs nothing.
      log =
        capture_log(fn ->
          {:ok, pid, _port} = AtlasCode.start(home, ps: absent)
          assert :ok = AtlasCode.stop(pid)
        end)

      refute log =~ "recovered"
      assert Path.wildcard(Path.join(home, "service.owner.ended-*")) |> length() == 4
      assert Path.wildcard(Path.join(home, "service.owner.*.tmp")) == []
      refute File.exists?(Path.join(home, "service.owner"))
    end

    test "a start never recovers a live owner of another OS process", %{
      tmp_dir: dir,
      home: home,
      pid: pid
    } do
      :ok = AtlasCode.stop(pid)
      # PID 1 always runs; the real ps reports it running, or cannot tell when restricted.
      stale_owner(home, 1)
      record = owner(home)

      for script <- ["ps", ps(dir, "running", ~s(echo "  $2"))] do
        error = assert_raise RuntimeError, fn -> AtlasCode.start(home, ps: script) end
        assert error.message =~ "is owned by service pid 1 "
        assert owner(home) == record
      end

      assert Path.wildcard(Path.join(home, "service.owner.*.tmp")) == []
    end

    test "concurrent starts recovering the same stale owner leave exactly one owner", %{
      tmp_dir: dir,
      home: home,
      pid: pid
    } do
      :ok = AtlasCode.stop(pid)
      absent = ps(dir, "absent", "exit 1")
      stale = stale_owner(home, 4_000_000)

      log =
        capture_log(fn ->
          send(
            self(),
            {:results,
             1..4
             |> Enum.map(fn _ ->
               Task.async(fn ->
                 try do
                   {:ok, AtlasCode.start(home, ps: absent)}
                 rescue
                   error -> {:error, Exception.message(error)}
                 end
               end)
             end)
             |> Task.await_many(30_000)}
          )
        end)

      assert log =~ "from stopped owner #{stale}"
      assert_received {:results, results}
      assert [{:ok, {:ok, pid, _port}}] = Enum.filter(results, &match?({:ok, _}, &1))
      assert File.exists?(Path.join(home, "service.owner.ended-" <> stale))
      assert :ok = AtlasCode.stop(pid)
      assert Path.wildcard(Path.join(home, "service.owner.*.tmp")) == []
    end

    test "a stale unlock that read the old owner moves neither a newer owner nor a running service",
         %{
           tmp_dir: dir,
           home: home,
           pid: pid
         } do
      :ok = AtlasCode.stop(pid)
      absent = ps(dir, "absent", "exit 1")
      stale = stale_owner(home, 4_000_001)
      old = owner(home)

      # Between this unlock's read and its rename, another unlock recovers the stale owner and a
      # newer owner takes the home: the rename then finds the stale owner's tombstone taken.
      staged = Path.join(dir, "newer")
      File.mkdir!(staged)
      newer = %{old | "owner" => String.duplicate("f", 32), "os_pid" => 4_000_002}
      File.write!(Path.join(staged, "owner.json"), JSON.encode!(newer))

      racing =
        ps(dir, "racing", """
        mv "#{home}/service.owner" "#{home}/service.owner.ended-#{stale}" || exit 9
        mv "#{staged}" "#{home}/service.owner" || exit 9
        exit 1
        """)

      assert {:error, :eexist} = AtlasCode.unlock(home, stale, racing)
      assert owner(home) == newer

      assert JSON.decode!(
               File.read!(Path.join([home, "service.owner.ended-" <> stale, "owner.json"]))
             ) == old

      File.rename!(
        Path.join(home, "service.owner"),
        Path.join(home, "service.owner.ended-" <> newer["owner"])
      )

      # The same stale unlock repeated against a newer running service re-reads and refuses.
      {:ok, pid, port} = AtlasCode.start(home)
      service = owner(home)
      assert {:error, message} = AtlasCode.unlock(home, stale, absent)
      assert message =~ "is owned by #{service["owner"]}"
      assert {:error, _} = AtlasCode.release(home, stale)
      assert owner(home) == service
      assert {200, _} = request(port, :get, "/v1/health")
      assert :ok = AtlasCode.stop(pid)
    end
  end

  test "without an orchestrator token Code starts and refuses reviews and integrations", %{
    port: port
  } do
    for {path, body} <- [
          {"/v1/reviews",
           %{
             "review_id" => uuid(1),
             "change_id" => uuid(2),
             "target" => "develop",
             "title" => "t",
             "body" => @attribution
           }},
          {"/v1/integrations",
           %{
             "integration_id" => uuid(1),
             "review_id" => uuid(2),
             "revision" => rev(1),
             "target_revision" => rev(2)
           }}
        ] do
      assert {403,
              %{
                "error" => %{
                  "code" => "forbidden",
                  "message" => "Reviews and integrations are not configured"
                }
              }} =
               orchestrate(port, path, body, @token)
    end
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

      revisions =
        for name <- ["app", "docs", "bad"], into: %{} do
          {200, %{"revision" => revision}} = resolve(port, "github.com/test/#{name}", "develop")
          {name, revision}
        end

      %{port: port, app: app, docs: docs, bad: bad, home: home, revisions: revisions}
    end

    test "two repositories at exact revisions give a stable ID, a manifest of blob bytes and exact archives",
         %{
           tmp_dir: dir,
           port: port,
           app: {app, app_commit},
           docs: {docs, docs_commit},
           home: home,
           revisions: revisions
         } do
      repositories = [
        %{
          "path" => "vendor/docs",
          "repository" => "github.com/test/docs",
          "revision" => revisions["docs"]
        },
        %{"path" => "app", "repository" => "github.com/test/app", "revision" => revisions["app"]}
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
              %{
                "snapshot_id" => ^id,
                "entries" => entries,
                "repositories" => ^listed,
                "version" => 2
              } =
                manifest} = request(port, :get, "/v1/snapshots/#{id}/manifest")

      # No commit appears in what clients see.
      for commit <- [app_commit, docs_commit],
          reply <- [created, manifest],
          do: refute(JSON.encode!(reply) =~ commit)

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

    test "unknown or foreign revisions, unsafe paths, forbidden repositories and unsupported content are refused",
         %{port: port, app: {_, app_commit}, revisions: revisions} do
      entry = fn path ->
        %{"repository" => "github.com/test/app", "revision" => revisions["app"], "path" => path}
      end

      assert {404,
              %{"error" => %{"code" => "unknown_revision", "details" => %{"revision" => unknown}}}} =
               snapshot(port, [%{entry.("app") | "revision" => rev(0)}])

      assert unknown == rev(0)

      assert {409,
              %{
                "error" => %{
                  "code" => "repository_mismatch",
                  "details" => %{"repository" => "github.com/test/app"}
                }
              }} =
               snapshot(port, [%{entry.("app") | "revision" => revisions["docs"]}])

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

      # Commits are never accepted in place of a revision.
      for revision <- ["abc", app_commit, "rev_" <> app_commit, String.upcase(revisions["app"])] do
        assert {400, %{"error" => %{"code" => "invalid_request", "details" => details}}} =
                 snapshot(port, [%{entry.("a") | "revision" => revision}])

        assert details == %{}
      end

      for body <- [
            "[]",
            ~s({"repositories": []}),
            JSON.encode!(%{"repositories" => [Map.put(entry.("a"), "x", 1)]}),
            JSON.encode!(%{
              "repositories" => [
                entry.("a") |> Map.delete("revision") |> Map.put("commit", app_commit)
              ]
            })
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
                 %{
                   "repository" => "github.com/test/bad",
                   "revision" => revisions["bad"],
                   "path" => "bad"
                 }
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

    test "revisions, snapshots and archives survive a restart", %{
      tmp_dir: dir,
      app: {app, _},
      revisions: revisions
    } do
      repositories = %{"github.com/test/app" => "file://" <> app}
      {home, port, pid} = serve_pid(dir, "restart-home", repositories)
      {200, %{"revision" => revision}} = resolve(port, "github.com/test/app", "develop")
      assert revision == revisions["app"]

      {200, %{"snapshot_id" => id}} =
        snapshot(port, [
          %{"repository" => "github.com/test/app", "revision" => revision, "path" => "app"}
        ])

      {200, manifest} = request(port, :get, "/v1/snapshots/#{id}/manifest")
      {200, tar} = archive(port, id, "app")
      AtlasCode.stop(pid)

      {:ok, pid, port} = AtlasCode.start(home)
      assert {200, ^manifest} = request(port, :get, "/v1/snapshots/#{id}/manifest")
      assert {200, ^tar} = archive(port, id, "app")

      assert {200, %{"snapshot_id" => ^id}} =
               snapshot(port, [
                 %{"repository" => "github.com/test/app", "revision" => revision, "path" => "app"}
               ])

      AtlasCode.stop(pid)
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

      {200, %{"revision" => revision}} = resolve(port, "github.com/test/app", "develop")

      {200, %{"snapshot_id" => snapshot_id}} =
        snapshot(port, [
          %{"repository" => "github.com/test/app", "revision" => revision, "path" => "app"}
        ])

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
          "base_revision" => revision,
          "entries" => entries
        }
      end

      %{
        port: port,
        home: home,
        source: source,
        base: base,
        revision: revision,
        cache: cache,
        change: change
      }
    end

    test "a mixed change uploads, seals onto the exact base and stays private", %{
      port: port,
      home: home,
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
              %{
                "error" => %{
                  "code" => "incomplete_upload",
                  "details" => %{"missing" => ^expected}
                }
              }} =
               seal(port, id)

      readme = files["README.md"]

      assert {400, %{"error" => %{"code" => "invalid_request"}}} =
               upload(port, id, hex(readme), String.duplicate("x", byte_size(readme)))

      assert {400, %{"error" => %{"code" => "invalid_request"}}} =
               upload(port, id, hex(readme), readme <> "x")

      assert {404, %{"error" => %{"code" => "not_found"}}} =
               upload(port, id, hex("unreferenced"), "unreferenced")

      remaining = expected -- [hex(readme)]

      assert {200, %{"state" => "open", "missing" => ^remaining}} =
               upload(port, id, hex(readme), readme)

      assert {200, %{"missing" => ^remaining}} = upload(port, id, hex(readme), readme)

      for bytes <- [script | Map.values(files)] do
        assert {200, %{"state" => "open"}} = upload(port, id, hex(bytes), bytes)
      end

      assert {200, %{"state" => "open", "missing" => []}} = submit(port, change.(id, entries))

      assert {200,
              %{"change_id" => ^id, "state" => "sealed", "missing" => [], "revision" => revision} =
                sealed} = seal(port, id)

      assert map_size(sealed) == 4
      commit = commit_of(home, revision)
      refute JSON.encode!(sealed) =~ commit

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

      assert {_, status} =
               System.cmd("git", ["cat-file", "-e", commit], cd: source, stderr_to_stdout: true)

      assert status != 0
    end

    # Git owns ignore rules: a new path that `git add -A` in the change's working tree would skip
    # (base and written .gitignore files, nested ones, negations, ignored directories) is left
    # out of the sealed tree; a path tracked in the base stays even when a pattern matches it.
    test "a seal leaves out new paths the resulting tree's .gitignore files ignore", %{
      tmp_dir: dir
    } do
      {source, _base} =
        fixture(dir, "ignoring", fn source ->
          for {path, bytes} <- [
                {".gitignore", "cache/\n*.tmp\n!keep.tmp\n/out/\n"},
                {"pkg/.gitignore", "local.txt\n"},
                {"pkg/main.txt", "main\n"},
                {"pkg/tracked.tmp", "tracked\n"}
              ] do
            File.mkdir_p!(Path.dirname(Path.join(source, path)))
            File.write!(Path.join(source, path), bytes)
          end

          git(source, ["add", "-f", "pkg/tracked.tmp"])
        end)

      {home, port} = serve(dir, "ignoring-home", %{"github.com/test/app" => "file://" <> source})
      {200, %{"revision" => revision}} = resolve(port, "github.com/test/app", "develop")

      {200, %{"snapshot_id" => snapshot_id}} =
        snapshot(port, [
          %{"repository" => "github.com/test/app", "revision" => revision, "path" => "app"}
        ])

      [cache] = Path.wildcard(Path.join([home, "cache", "*.git"]))
      id = uuid(77)

      kept = %{
        "pkg/main.txt" => "main again\n",
        "pkg/tracked.tmp" => "tracked again\n",
        "pkg/new.txt" => "new\n",
        "keep.tmp" => "negated\n",
        "other/local.txt" => "not under pkg\n",
        "extra/.gitignore" => "*.log\n"
      }

      ignored = %{
        "pkg/cache/m.bin" => <<0, 1, 2>>,
        "cache/top.bin" => <<3, 4>>,
        "pkg/scratch.tmp" => "scratch\n",
        ~s(pkg/say "hi".tmp) => "quoted\n",
        "pkg/local.txt" => "local\n",
        "out/result.txt" => "result\n",
        "extra/run.log" => "log\n"
      }

      entries =
        Enum.map(Map.merge(kept, ignored), fn {path, bytes} -> write(path, bytes) end) ++
          [symlink("out/link", "../pkg/main.txt")]

      assert {200, %{"state" => "open"}} =
               submit(port, %{
                 "change_id" => id,
                 "snapshot_id" => snapshot_id,
                 "repository" => "github.com/test/app",
                 "base_revision" => revision,
                 "entries" => entries
               })

      for {_path, bytes} <- Map.merge(kept, ignored),
          do: {200, _} = upload(port, id, hex(bytes), bytes)

      assert {200, %{"state" => "sealed", "revision" => sealed}} = seal(port, id)
      assert {200, %{"revision" => ^sealed}} = seal(port, id)

      paths =
        cache
        |> git(["ls-tree", "-r", "-z", "--name-only", "--full-tree", commit_of(home, sealed)])
        |> :binary.split(<<0>>, [:global, :trim_all])
        |> Enum.sort()

      assert paths == Enum.sort([".gitignore", "pkg/.gitignore" | Map.keys(kept)])
    end

    test "base mismatches, unknown targets and unsafe or conflicting entries are refused", %{
      port: port,
      home: home,
      change: change
    } do
      id = "1b4e28ba-2fa1-11d2-883f-0016d3cca427"
      ok = [write("README.md", "x\n")]

      # A newer revision of the same repository is not the snapshot's base.
      {200, %{"revision" => moved}} = resolve(port, "github.com/test/app", "develop")

      assert {409,
              %{
                "error" => %{"code" => "base_mismatch", "details" => %{"base_revision" => ^moved}}
              }} =
               submit(port, %{change.(id, ok) | "base_revision" => moved})

      for base <- [String.duplicate("a", 40), "rev_x", 1] do
        assert {400, %{"error" => %{"code" => "invalid_request"}}} =
                 submit(port, %{change.(id, ok) | "base_revision" => base})
      end

      legacy =
        change.(id, ok)
        |> Map.delete("base_revision")
        |> Map.put("base_commit", String.duplicate("a", 40))

      assert {400, %{"error" => %{"code" => "invalid_request"}}} = submit(port, legacy)

      assert {404, %{"error" => %{"code" => "not_found"}}} =
               submit(port, %{
                 change.(id, ok)
                 | "snapshot_id" => "sha256:" <> String.duplicate("0", 64)
               })

      assert {404, %{"error" => %{"code" => "not_found", "details" => %{"repository" => _}}}} =
               submit(port, %{change.(id, ok) | "repository" => "github.com/test/other"})

      assert {403, %{"error" => %{"code" => "forbidden"}}} =
               submit(port, %{change.(id, ok) | "repository" => "github.com/test/denied"})

      for bad <- ["x", String.upcase(id), id <> "0"] do
        assert {400, %{"error" => %{"code" => "invalid_request"}}} =
                 submit(port, change.(bad, ok))
      end

      for path <- ["../x", "/abs", "a//b", ".git/config", "x/.GIT", "a\\b", ""] do
        assert {400,
                %{"error" => %{"code" => "invalid_request", "details" => %{"path" => ^path}}}} =
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
                    "details" => %{
                      "entries" => [%{"path" => "lib/up", "reason" => "symlink_target"}]
                    }
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

  test "repository fingerprints match Runtime's golden fixture byte for byte" do
    %{"cases" => [_ | _] = cases} =
      Path.expand("../../../../tools/runtime/snapshot/testdata/fingerprints.json", __DIR__)
      |> File.read!()
      |> JSON.decode!()

    for %{"name" => name, "request" => request, "canonical" => canonical, "fingerprint" => fpr} <-
          cases do
      sorted = Map.update!(request, "entries", &Enum.sort_by(&1, fn entry -> entry["path"] end))
      assert JSON.encode!(sorted) == canonical, name
      assert "fpr_" <> hex(canonical) == fpr, name
      # A change ID is outside the fingerprint.
      assert AtlasCode.fingerprint(Map.put(request, "change_id", uuid(1))) == fpr, name
    end
  end

  describe "reviews and integrations" do
    setup %{tmp_dir: dir}, do: provider(dir, "reviews-home")

    test "a given fingerprint must be the change's content before a review or integration has effects",
         %{port: port, home: home, remote: remote, base: base, sealed: sealed} do
      change = uuid(110)
      revision = sealed.(change, "github.com/test/plain", %{"README.md" => "approved\n"})
      fpr = fingerprint_of(home, change)
      reviews = Path.join(home, "reviews")

      assert {409,
              %{
                "error" => %{
                  "code" => "fingerprint_mismatch",
                  "details" => %{"change_id" => ^change, "fingerprint" => ^fpr}
                }
              }} =
               orchestrate(
                 port,
                 "/v1/reviews",
                 Map.put(review(uuid(111), change), "fingerprint", fingerprint(1))
               )

      refute File.exists?(reviews)
      assert git(remote, ["for-each-ref", "refs/heads/work"]) == ""

      # The refused ID is free: the approved fingerprint opens the review, and repeats replay it.
      body = Map.put(review(uuid(111), change), "fingerprint", fpr)

      assert {200, %{"state" => "open", "revision" => ^revision}} =
               orchestrate(port, "/v1/reviews", body)

      assert {200, %{"state" => "open"}} = orchestrate(port, "/v1/reviews", body)

      assert {409, %{"error" => %{"code" => "conflict"}}} =
               orchestrate(port, "/v1/reviews", %{body | "fingerprint" => fingerprint(1)})

      assert {409, %{"error" => %{"code" => "conflict"}}} =
               orchestrate(port, "/v1/reviews", Map.delete(body, "fingerprint"))

      assert git(remote, ["reflog", "show", "refs/heads/work/review-" <> uuid(111)])
             |> String.split("\n", trim: true)
             |> length() == 1

      {200, %{"revision" => target}} = resolve(port, "github.com/test/plain", "develop")
      ok = Map.put(integration(uuid(112), uuid(111), revision, target), "fingerprint", fpr)

      assert {409,
              %{
                "error" => %{
                  "code" => "fingerprint_mismatch",
                  "details" => %{"change_id" => ^change, "fingerprint" => ^fpr}
                }
              }} =
               orchestrate(port, "/v1/integrations", %{ok | "fingerprint" => fingerprint(1)})

      refute File.exists?(Path.join(home, "integrations"))
      assert git(remote, ["rev-parse", "refs/heads/develop"]) == base <> "\n"

      assert {200, %{"state" => "integrated", "method" => "fast_forward"}} =
               orchestrate(port, "/v1/integrations", ok)

      assert {200, %{"state" => "integrated"}} = orchestrate(port, "/v1/integrations", ok)

      assert {409, %{"error" => %{"code" => "conflict"}}} =
               orchestrate(port, "/v1/integrations", %{ok | "fingerprint" => fingerprint(1)})

      assert git(remote, ["rev-parse", "refs/heads/develop"]) == commit_of(home, revision) <> "\n"
    end

    test "only the orchestrator token reviews and integrates; it may call every endpoint", %{
      port: port
    } do
      body = review(uuid(1), uuid(2))

      assert {403,
              %{
                "error" => %{
                  "code" => "forbidden",
                  "message" => "Reviews and integrations require the orchestrator token"
                }
              }} = orchestrate(port, "/v1/reviews", body, @token)

      assert {404, %{"error" => %{"code" => "not_found"}}} =
               orchestrate(port, "/v1/reviews", body)

      {status, reply} =
        send_request(port, :get, "/v1/health", "", [
          {~c"authorization", ~c"Bearer " ++ String.to_charlist(@orchestrator)}
        ])

      assert status == 200
      refute reply =~ @orchestrator
    end

    test "invalid, legacy and provider-specific review requests and unsealed changes are refused before any record",
         %{
           port: port,
           home: home,
           remote: remote,
           sealed: sealed,
           snapshot_id: snapshot_id,
           revisions: revisions
         } do
      change = uuid(10)
      sealed.(change, "github.com/test/plain", %{"README.md" => "x\n"})
      ok = review(uuid(11), change)

      for body <- [
            "not json",
            Map.delete(ok, "target"),
            Map.put(ok, "extra", 1),
            Map.put(ok, "branch", "work/x"),
            Map.put(ok, "pull_request", %{
              "base" => "develop",
              "title" => "t",
              "body" => @attribution
            }),
            Map.put(ok, "review_url", "https://github.com/test/app/pull/1"),
            %{ok | "review_id" => "x"},
            %{ok | "change_id" => change <> "0"},
            %{ok | "target" => "../x"},
            %{ok | "target" => "-x"},
            %{ok | "target" => 1},
            %{ok | "title" => " "},
            %{ok | "title" => "a\nb"},
            %{ok | "title" => String.duplicate("t", 257)},
            # Attribution is required in review bodies.
            %{ok | "body" => "No attribution"},
            Map.put(ok, "fingerprint", "fpr_" <> String.duplicate("A", 64)),
            Map.put(ok, "fingerprint", 1),
            ok |> Map.put("fingerprint", fingerprint(0)) |> Map.put("extra", 1)
          ] do
        assert {400, %{"error" => %{"code" => "invalid_request"}}} =
                 orchestrate(port, "/v1/reviews", body)
      end

      assert {404, %{"error" => %{"code" => "not_found"}}} =
               orchestrate(port, "/v1/reviews", %{ok | "change_id" => uuid(12)})

      bytes = "open\n"

      {200, %{"state" => "open"}} =
        submit(port, %{
          "change_id" => uuid(13),
          "snapshot_id" => snapshot_id,
          "repository" => "github.com/test/plain",
          "base_revision" => revisions["plain"],
          "entries" => [write("README.md", bytes)]
        })

      assert {409, %{"error" => %{"code" => "change_not_sealed"}}} =
               orchestrate(port, "/v1/reviews", %{ok | "change_id" => uuid(13)})

      refute File.exists?(Path.join(home, "reviews"))
      assert git(remote, ["for-each-ref", "refs/heads/work"]) == ""
    end

    test "a local review pushes the exact sealed revision once to a location Code names", %{
      tmp_dir: dir,
      port: port,
      home: home,
      remote: remote,
      base: base,
      sealed: sealed
    } do
      change = uuid(20)
      revision = sealed.(change, "github.com/test/plain", %{"README.md" => "reviewed\n"})
      commit = commit_of(home, revision)
      body = review(uuid(21), change)

      expected = %{
        "review_id" => uuid(21),
        "change_id" => change,
        "repository" => "github.com/test/plain",
        "target" => "develop",
        "revision" => revision,
        "state" => "open"
      }

      assert {200, ^expected} = orchestrate(port, "/v1/reviews", body)
      location = "refs/heads/work/review-" <> uuid(21)
      assert git(remote, ["rev-parse", location]) == commit <> "\n"
      assert git(remote, ["rev-parse", commit <> "^@"]) == base <> "\n"
      assert git(remote, ["rev-parse", "refs/heads/develop"]) == base <> "\n"
      assert {200, ^expected} = orchestrate(port, "/v1/reviews", body)

      # A response lost after the push: the record still says pushing, the location is ours.
      file = Path.join([home, "reviews", uuid(21) <> ".json"])
      record = file |> File.read!() |> JSON.decode!()
      assert record["phase"] == "open"
      File.write!(file, JSON.encode!(%{record | "phase" => "pushing"}))
      assert {200, ^expected} = orchestrate(port, "/v1/reviews", body)

      assert git(remote, ["reflog", "show", location])
             |> String.split("\n", trim: true)
             |> length() == 1

      assert {409, %{"error" => %{"code" => "conflict"}}} =
               orchestrate(port, "/v1/reviews", %{body | "title" => "Other"})

      # No provider was involved for a plain remote.
      refute File.exists?(Path.join(dir, "gh-calls"))
    end

    test "existing review locations are never overwritten, even at the same commit", %{
      port: port,
      home: home,
      remote: remote,
      base: base,
      sealed: sealed
    } do
      change = uuid(30)

      commit =
        commit_of(home, sealed.(change, "github.com/test/plain", %{"README.md" => "taken\n"}))

      [cache] =
        Path.wildcard(Path.join([home, "cache", "*.git"])) |> Enum.filter(&commit?(&1, commit))

      git(cache, ["push", "-q", remote, "#{commit}:refs/heads/work/review-#{uuid(32)}"])

      other =
        remote
        |> git([
          "-c",
          "user.name=t",
          "-c",
          "user.email=t@t",
          "commit-tree",
          base <> "^{tree}",
          "-p",
          base,
          "-m",
          "other"
        ])
        |> String.trim()

      git(remote, ["update-ref", "refs/heads/work/review-#{uuid(31)}", other])
      refs = git(remote, ["for-each-ref"])

      for n <- [31, 32] do
        assert {409, %{"error" => %{"code" => "location_taken"}}} =
                 orchestrate(port, "/v1/reviews", review(uuid(n), change))

        assert {409, %{"error" => %{"code" => "location_taken"}}} =
                 orchestrate(port, "/v1/reviews", review(uuid(n), change))

        assert %{"phase" => "failed"} =
                 JSON.decode!(File.read!(Path.join([home, "reviews", uuid(n) <> ".json"])))
      end

      assert git(remote, ["for-each-ref"]) == refs
    end

    test "a GitHub review opens its pull request once through the provider", %{
      tmp_dir: dir,
      port: port,
      home: home,
      remote: remote,
      sealed: sealed
    } do
      change = uuid(50)
      revision = sealed.(change, "github.com/test/app", %{"README.md" => "pull request\n"})
      body = review(uuid(51), change)

      assert {200,
              %{
                "revision" => ^revision,
                "repository" => "github.com/test/app",
                "state" => "open",
                "review_url" => "https://github.com/test/app/pull/7"
              } = reviewed} = orchestrate(port, "/v1/reviews", body)

      assert {200, ^reviewed} = orchestrate(port, "/v1/reviews", body)
      location = "work/review-" <> uuid(51)

      assert git(remote, ["rev-parse", "refs/heads/" <> location]) ==
               commit_of(home, revision) <> "\n"

      assert File.read!(Path.join(dir, "pr-body")) == body["body"]

      list = "1 pr list --repo=test/app --head=#{location} --state all --json url"

      create =
        "1 pr create --repo=test/app --head=#{location} --base=develop --title=Fix --body-file="

      assert [^list, created] =
               dir |> Path.join("gh-calls") |> File.read!() |> String.split("\n", trim: true)

      assert String.starts_with?(created, create)
    end

    test "a pull request failure after the push is incomplete and a repeat resumes without a second push or PR",
         %{tmp_dir: dir, port: port, home: home, remote: remote, sealed: sealed} do
      change = uuid(60)
      revision = sealed.(change, "github.com/test/app", %{"README.md" => "retried\n"})
      body = review(uuid(61), change)
      location = "refs/heads/work/review-" <> uuid(61)
      File.write!(Path.join(dir, "fail-before"), "")

      assert {502,
              %{"error" => %{"code" => "review_incomplete", "details" => %{"phase" => "pushed"}}} =
                error} =
               orchestrate(port, "/v1/reviews", body)

      refute JSON.encode!(error) =~ "ghp_secret"
      assert git(remote, ["rev-parse", location]) == commit_of(home, revision) <> "\n"

      # The provider creates the pull request but its response is lost.
      File.rm!(Path.join(dir, "fail-before"))
      File.write!(Path.join(dir, "fail-after"), "")

      assert {502, %{"error" => %{"code" => "review_incomplete"}}} =
               orchestrate(port, "/v1/reviews", body)

      File.rm!(Path.join(dir, "fail-after"))

      assert {200, %{"review_url" => "https://github.com/test/app/pull/7"} = reviewed} =
               orchestrate(port, "/v1/reviews", body)

      assert {200, ^reviewed} = orchestrate(port, "/v1/reviews", body)

      # The last attempt adopted the existing pull request instead of creating another.
      calls = dir |> Path.join("gh-calls") |> File.read!() |> String.split("\n", trim: true)

      assert Enum.map(calls, &(&1 |> String.split(" ") |> Enum.take(3))) == [
               ["1", "pr", "list"],
               ["1", "pr", "create"],
               ["1", "pr", "list"],
               ["1", "pr", "create"],
               ["1", "pr", "list"]
             ]

      assert git(remote, ["reflog", "show", location])
             |> String.split("\n", trim: true)
             |> length() == 1
    end

    test "a review containing the exact target fast-forwards it once; repeats and lost responses replay it",
         %{
           port: port,
           home: home,
           remote: remote,
           sealed: sealed
         } do
      change = uuid(70)
      revision = sealed.(change, "github.com/test/plain", %{"README.md" => "integrated\n"})
      commit = commit_of(home, revision)
      {200, _} = orchestrate(port, "/v1/reviews", review(uuid(71), change))
      {200, %{"revision" => target}} = resolve(port, "github.com/test/plain", "develop")
      body = integration(uuid(72), uuid(71), revision, target)

      expected = %{
        "integration_id" => uuid(72),
        "review_id" => uuid(71),
        "repository" => "github.com/test/plain",
        "target" => "develop",
        "revision" => revision,
        "method" => "fast_forward",
        "state" => "integrated"
      }

      assert {200, ^expected} = orchestrate(port, "/v1/integrations", body)
      assert git(remote, ["rev-parse", "refs/heads/develop"]) == commit <> "\n"
      assert {200, ^expected} = orchestrate(port, "/v1/integrations", body)

      # A response lost after the push: the record still says integrating, the target is ours.
      file = Path.join([home, "integrations", uuid(72) <> ".json"])
      record = file |> File.read!() |> JSON.decode!()
      File.write!(file, JSON.encode!(Map.drop(%{record | "phase" => "integrating"}, ["result"])))
      assert {200, ^expected} = orchestrate(port, "/v1/integrations", body)

      assert git(remote, ["reflog", "show", "refs/heads/develop"])
             |> String.split("\n", trim: true)
             |> length() == 1

      assert {409, %{"error" => %{"code" => "conflict"}}} =
               orchestrate(port, "/v1/integrations", %{body | "target_revision" => revision})

      # The target now is the review's revision: resolving it gives the same handle.
      assert {200, %{"revision" => ^revision}} = resolve(port, "github.com/test/plain", "develop")

      assert {200, %{"method" => "already_integrated", "revision" => ^revision}} =
               orchestrate(
                 port,
                 "/v1/integrations",
                 integration(uuid(73), uuid(71), revision, revision)
               )

      assert git(remote, ["reflog", "show", "refs/heads/develop"])
             |> String.split("\n", trim: true)
             |> length() == 1
    end

    test "a moved target is refused, then merged when clean, and a conflicting review leaves it unchanged",
         %{
           tmp_dir: dir,
           port: port,
           home: home,
           remote: remote,
           base: base,
           sealed: sealed
         } do
      change = uuid(80)
      revision = sealed.(change, "github.com/test/plain", %{"README.md" => "merged\n"})
      commit = commit_of(home, revision)
      {200, _} = orchestrate(port, "/v1/reviews", review(uuid(81), change))
      {200, %{"revision" => stale}} = resolve(port, "github.com/test/plain", "develop")
      advanced = advance(dir, remote, %{"other.txt" => "advanced\n"})

      assert {409,
              %{
                "error" => %{
                  "code" => "target_moved",
                  "details" => %{"target" => "develop", "current" => current}
                }
              }} =
               orchestrate(
                 port,
                 "/v1/integrations",
                 integration(uuid(82), uuid(81), revision, stale)
               )

      assert {200, %{"revision" => ^current}} = resolve(port, "github.com/test/plain", "develop")
      assert git(remote, ["rev-parse", "refs/heads/develop"]) == advanced <> "\n"

      assert {409, %{"error" => %{"code" => "target_moved"}}} =
               orchestrate(
                 port,
                 "/v1/integrations",
                 integration(uuid(82), uuid(81), revision, stale)
               )

      assert {200, %{"method" => "merge", "revision" => merged, "state" => "integrated"}} =
               orchestrate(
                 port,
                 "/v1/integrations",
                 integration(uuid(83), uuid(81), revision, current)
               )

      merge = commit_of(home, merged)
      assert git(remote, ["rev-parse", "refs/heads/develop"]) == merge <> "\n"
      assert git(remote, ["rev-parse", merge <> "^@"]) == advanced <> "\n" <> commit <> "\n"
      assert git(remote, ["show", merge <> ":README.md"]) == "merged\n"
      assert git(remote, ["show", merge <> ":other.txt"]) == "advanced\n"

      assert git(remote, ["log", "-1", "--format=%an <%ae>|%s", merge]) ==
               "Atlas Code <atlas-code@localhost>|Atlas integration #{uuid(83)}\n"

      # Another review of the same base edits README.md differently.
      conflicting = uuid(84)
      other = sealed.(conflicting, "github.com/test/plain", %{"README.md" => "conflict\n"})
      {200, _} = orchestrate(port, "/v1/reviews", review(uuid(85), conflicting))
      body = integration(uuid(86), uuid(85), other, merged)

      assert {409,
              %{
                "error" => %{
                  "code" => "integration_conflict",
                  "details" => %{"paths" => ["README.md"]}
                }
              } = error} =
               orchestrate(port, "/v1/integrations", body)

      assert {409, ^error} = orchestrate(port, "/v1/integrations", body)
      assert git(remote, ["rev-parse", "refs/heads/develop"]) == merge <> "\n"
      refute git(remote, ["rev-parse", "refs/heads/develop"]) == base <> "\n"

      # No reply carries a commit.
      for reply <- [error], c <- [commit, merge, advanced], do: refute(JSON.encode!(reply) =~ c)
    end

    test "a remote that refuses the target update is reported and never bypassed", %{
      port: port,
      home: home,
      remote: remote,
      base: base,
      sealed: sealed
    } do
      change = uuid(90)
      revision = sealed.(change, "github.com/test/plain", %{"README.md" => "protected\n"})
      {200, _} = orchestrate(port, "/v1/reviews", review(uuid(91), change))
      {200, %{"revision" => target}} = resolve(port, "github.com/test/plain", "develop")
      hook = Path.join([remote, "hooks", "pre-receive"])
      File.mkdir_p!(Path.dirname(hook))

      File.write!(hook, """
      #!/bin/sh
      while read old new ref; do
        if [ "$ref" = refs/heads/develop ]; then echo "develop is protected" >&2; exit 1; fi
      done
      """)

      File.chmod!(hook, 0o755)
      body = integration(uuid(92), uuid(91), revision, target)

      assert {409,
              %{
                "error" => %{
                  "code" => "integration_refused",
                  "details" => %{"target" => "develop"}
                }
              } = error} =
               orchestrate(port, "/v1/integrations", body)

      refute JSON.encode!(error) =~ "protected"
      assert {409, ^error} = orchestrate(port, "/v1/integrations", body)
      assert git(remote, ["rev-parse", "refs/heads/develop"]) == base <> "\n"

      assert %{"phase" => "refused"} =
               JSON.decode!(File.read!(Path.join([home, "integrations", uuid(92) <> ".json"])))
    end

    test "a target moved between the lease check and the update keeps the other work", %{
      port: port,
      remote: remote,
      base: base,
      sealed: sealed
    } do
      change = uuid(95)
      revision = sealed.(change, "github.com/test/plain", %{"README.md" => "raced\n"})
      {200, _} = orchestrate(port, "/v1/reviews", review(uuid(96), change))
      {200, %{"revision" => target}} = resolve(port, "github.com/test/plain", "develop")

      other =
        remote
        |> git([
          "-c",
          "user.name=t",
          "-c",
          "user.email=t@t",
          "commit-tree",
          base <> "^{tree}",
          "-p",
          base,
          "-m",
          "other"
        ])
        |> String.trim()

      hook = Path.join([remote, "hooks", "pre-receive"])
      File.mkdir_p!(Path.dirname(hook))
      # Runs after the client checked its lease against the advertised refs.
      File.write!(
        hook,
        "#!/bin/sh\nenv -u GIT_QUARANTINE_PATH git update-ref refs/heads/develop #{other}\n"
      )

      File.chmod!(hook, 0o755)

      assert {409,
              %{"error" => %{"code" => "target_moved", "details" => %{"current" => "rev_" <> _}}}} =
               orchestrate(
                 port,
                 "/v1/integrations",
                 integration(uuid(97), uuid(96), revision, target)
               )

      assert git(remote, ["rev-parse", "refs/heads/develop"]) == other <> "\n"
    end

    test "a target moved between Code's check and its push is never overwritten", %{tmp_dir: dir} do
      {source, base} = fixture(dir, "race", &File.write!(Path.join(&1, "README.md"), "hello\n"))
      remote = Path.join(dir, "race.git")
      git(dir, ["clone", "-q", "--bare", source, remote])

      other =
        remote
        |> git([
          "-c",
          "user.name=t",
          "-c",
          "user.email=t@t",
          "commit-tree",
          base <> "^{tree}",
          "-p",
          base,
          "-m",
          "other"
        ])
        |> String.trim()

      arm = Path.join(dir, "arm")
      wrapper = Path.join(dir, "transport")

      # Code's cache reaches the remote through this transport; once armed, the next listing
      # moves develop right after it was advertised, before Code's push connects.
      File.write!(wrapper, """
      #!/bin/sh
      if [ "$1" = git-upload-pack ] && [ -e "#{arm}" ]; then
        git upload-pack "#{remote}"; status=$?
        rm "#{arm}"
        git --git-dir "#{remote}" update-ref refs/heads/develop #{other}
        exit $status
      fi
      exec git "${1#git-}" "#{remote}"
      """)

      File.chmod!(wrapper, 0o755)
      url = "file://" <> remote

      {_home, port, _pid} =
        serve_pid(dir, "race-home", %{"github.com/test/race" => url}, %{}, fn home ->
          File.write!(Path.join(home, "orchestrator.token"), @orchestrator <> "\n")
          File.chmod!(Path.join(home, "orchestrator.token"), 0o600)
          cache = Path.join([home, "cache", hex(["github.com/test/race", 0, url]) <> ".git"])
          git(dir, ["init", "-q", "--bare", cache])
          git(cache, ["config", "protocol.ext.allow", "always"])
          git(cache, ["config", "url.ext::#{wrapper} %S.insteadOf", url])
        end)

      {200, %{"revision" => target}} = resolve(port, "github.com/test/race", "develop")

      {200, %{"snapshot_id" => snapshot_id}} =
        snapshot(port, [
          %{"repository" => "github.com/test/race", "revision" => target, "path" => "race"}
        ])

      bytes = "raced\n"

      {200, _} =
        submit(port, %{
          "change_id" => uuid(98),
          "snapshot_id" => snapshot_id,
          "repository" => "github.com/test/race",
          "base_revision" => target,
          "entries" => [write("README.md", bytes)]
        })

      {200, _} = upload(port, uuid(98), hex(bytes), bytes)
      {200, %{"revision" => revision}} = seal(port, uuid(98))
      {200, _} = orchestrate(port, "/v1/reviews", review(uuid(99), uuid(98)))
      File.write!(arm, "")

      assert {409,
              %{"error" => %{"code" => "target_moved", "details" => %{"current" => current}}}} =
               orchestrate(
                 port,
                 "/v1/integrations",
                 integration(uuid(100), uuid(99), revision, target)
               )

      refute File.exists?(arm)
      assert git(remote, ["rev-parse", "refs/heads/develop"]) == other <> "\n"
      assert {200, %{"revision" => ^current}} = resolve(port, "github.com/test/race", "develop")
    end

    test "unknown, foreign or mismatched handles, legacy fields and reviews that are not open are refused",
         %{
           port: port,
           home: home,
           remote: remote,
           base: base,
           sealed: sealed,
           revisions: revisions
         } do
      change = uuid(100)
      revision = sealed.(change, "github.com/test/plain", %{"README.md" => "refused\n"})
      commit = commit_of(home, revision)
      {200, _} = orchestrate(port, "/v1/reviews", review(uuid(101), change))
      {200, %{"revision" => target}} = resolve(port, "github.com/test/plain", "develop")
      ok = integration(uuid(102), uuid(101), revision, target)

      assert {404, %{"error" => %{"code" => "not_found"}}} =
               orchestrate(port, "/v1/integrations", %{ok | "review_id" => uuid(109)})

      assert {409,
              %{
                "error" => %{
                  "code" => "revision_mismatch",
                  "details" => %{"revision" => ^revision}
                }
              }} =
               orchestrate(port, "/v1/integrations", %{ok | "revision" => target})

      assert {404, %{"error" => %{"code" => "unknown_revision"}}} =
               orchestrate(port, "/v1/integrations", %{ok | "target_revision" => rev(0)})

      assert {409, %{"error" => %{"code" => "repository_mismatch"}}} =
               orchestrate(port, "/v1/integrations", %{ok | "target_revision" => revisions["app"]})

      for body <- [
            "not json",
            Map.delete(ok, "target_revision"),
            Map.put(ok, "extra", 1),
            Map.put(ok, "branch", "develop"),
            Map.put(ok, "pr_url", "https://github.com/test/app/pull/1"),
            Map.put(ok, "expected_head", commit),
            %{ok | "target_revision" => base},
            %{ok | "revision" => commit},
            %{ok | "integration_id" => "x"},
            %{ok | "review_id" => 1},
            Map.put(ok, "fingerprint", "sha256:" <> String.duplicate("0", 64)),
            ok |> Map.put("fingerprint", fingerprint(0)) |> Map.put("extra", 1)
          ] do
        assert {400, %{"error" => %{"code" => "invalid_request"}}} =
                 orchestrate(port, "/v1/integrations", body)
      end

      git(remote, ["update-ref", "refs/heads/work/review-#{uuid(103)}", base])
      {409, _} = orchestrate(port, "/v1/reviews", review(uuid(103), change))

      assert {409, %{"error" => %{"code" => "review_not_open"}}} =
               orchestrate(port, "/v1/integrations", %{ok | "review_id" => uuid(103)})

      refute File.exists?(Path.join(home, "integrations"))
      assert git(remote, ["rev-parse", "refs/heads/develop"]) == base <> "\n"
    end

    test "an update fast-forwards the pull request to the change's tree once; integration follows it",
         %{tmp_dir: dir, port: port, home: home, remote: remote, sealed: sealed} do
      first = sealed.(uuid(120), "github.com/test/app", %{"README.md" => "first\n"})
      {200, _} = orchestrate(port, "/v1/reviews", review(uuid(121), uuid(120)))
      calls = File.read!(Path.join(dir, "gh-calls"))
      location = "refs/heads/work/review-" <> uuid(121)

      # The rework was made from the base again; the update still carries exactly its content.
      second =
        sealed.(uuid(122), "github.com/test/app", %{
          "README.md" => "second\n",
          "other.txt" => "changed\n"
        })

      fpr = fingerprint_of(home, uuid(122))
      body = review_update(uuid(123), uuid(121), uuid(122), first, fpr)
      {update_id, review_id, change_id} = {uuid(123), uuid(121), uuid(122)}

      assert {200,
              %{
                "update_id" => ^update_id,
                "review_id" => ^review_id,
                "change_id" => ^change_id,
                "repository" => "github.com/test/app",
                "previous_revision" => ^first,
                "revision" => updated,
                "state" => "open",
                "review_url" => "https://github.com/test/app/pull/7"
              } = reply} = orchestrate(port, "/v1/review-updates", body)

      child = commit_of(home, updated)
      refute updated in [first, second]
      assert git(remote, ["rev-parse", location]) == child <> "\n"
      assert git(remote, ["rev-parse", child <> "^@"]) == commit_of(home, first) <> "\n"

      # The sealed change exists only in Code's cache; the child carries its exact tree.
      [cache] =
        Path.wildcard(Path.join([home, "cache", "*.git"]))
        |> Enum.filter(&commit?(&1, commit_of(home, second)))

      assert git(remote, ["rev-parse", child <> "^{tree}"]) ==
               git(cache, ["rev-parse", commit_of(home, second) <> "^{tree}"])

      assert git(remote, ["show", child <> ":other.txt"]) == "changed\n"

      # Fixed identity, dated by its parent: the child depends only on the update.
      assert git(remote, ["log", "-1", "--format=%an <%ae>|%cn <%ce>|%ct", child]) ==
               git(remote, [
                 "log",
                 "-1",
                 "--format=Atlas Code <atlas-code@localhost>|Atlas Code <atlas-code@localhost>|%ct",
                 commit_of(home, first)
               ])

      # One fast-forward of the location, and the pull request follows it without a provider call.
      assert reflog(remote, location) == 2
      assert File.read!(Path.join(dir, "gh-calls")) == calls
      assert {200, ^reply} = orchestrate(port, "/v1/review-updates", body)

      review_file = Path.join([home, "reviews", uuid(121) <> ".json"])

      assert %{"revision" => ^updated, "change_id" => "00000000-0000-4000-8000-000000000122"} =
               original = review_file |> File.read!() |> JSON.decode!()

      assert original["updates"] == [uuid(123)]

      assert {200,
              %{"revision" => ^updated, "change_id" => "00000000-0000-4000-8000-000000000122"}} =
               orchestrate(port, "/v1/reviews", review(uuid(121), uuid(120)))

      # Responses lost after the push: the location moved, the update record did not, and the
      # review record did (first repeat) or did not (second).
      file = Path.join([home, "review-updates", uuid(123) <> ".json"])
      record = file |> File.read!() |> JSON.decode!()
      File.write!(file, JSON.encode!(%{record | "phase" => "pushing"}))
      assert {200, ^reply} = orchestrate(port, "/v1/review-updates", body)
      assert JSON.decode!(File.read!(review_file)) == original
      File.write!(file, JSON.encode!(%{record | "phase" => "pushing"}))

      File.write!(
        review_file,
        JSON.encode!(
          Map.drop(%{original | "revision" => first, "change_id" => uuid(120)}, ["updates"])
        )
      )

      assert {200, ^reply} = orchestrate(port, "/v1/review-updates", body)
      assert JSON.decode!(File.read!(review_file)) == original

      # Code stopped before recording the update: the repeat derives the same commit, finds it
      # pushed and claims its private ref again, which a different commit could not.
      File.rm!(file)

      File.write!(
        review_file,
        JSON.encode!(
          Map.drop(%{original | "revision" => first, "change_id" => uuid(120)}, ["updates"])
        )
      )

      assert {200, ^reply} = orchestrate(port, "/v1/review-updates", body)
      assert JSON.decode!(File.read!(review_file)) == original
      assert reflog(remote, location) == 2

      for other <- [
            %{body | "fingerprint" => fingerprint(1)},
            %{body | "change_id" => uuid(120)},
            %{body | "revision" => updated}
          ] do
        assert {409, %{"error" => %{"code" => "conflict"}}} =
                 orchestrate(port, "/v1/review-updates", other)
      end

      # Integration now requires the update: the old revision and the old content are refused.
      {200, %{"revision" => target}} = resolve(port, "github.com/test/plain", "develop")
      target = AtlasCode.put_revision(home, "github.com/test/app", commit_of(home, target))
      old = integration(uuid(124), uuid(121), first, target)

      assert {409,
              %{
                "error" => %{
                  "code" => "revision_mismatch",
                  "details" => %{"revision" => ^updated}
                }
              }} =
               orchestrate(port, "/v1/integrations", old)

      assert {409, %{"error" => %{"code" => "fingerprint_mismatch"}}} =
               orchestrate(
                 port,
                 "/v1/integrations",
                 Map.put(
                   %{old | "revision" => updated},
                   "fingerprint",
                   fingerprint_of(home, uuid(120))
                 )
               )

      assert {200, %{"method" => "fast_forward", "revision" => ^updated, "state" => "integrated"}} =
               orchestrate(
                 port,
                 "/v1/integrations",
                 Map.put(integration(uuid(125), uuid(121), updated, target), "fingerprint", fpr)
               )

      assert git(remote, ["rev-parse", "refs/heads/develop"]) == child <> "\n"
    end

    test "every update check refuses before any record or remote effect", %{
      port: port,
      pid: pid,
      home: home,
      remote: remote,
      base: base,
      sealed: sealed,
      snapshot_id: snapshot_id,
      revisions: revisions
    } do
      first = sealed.(uuid(130), "github.com/test/plain", %{"README.md" => "first\n"})
      {200, _} = orchestrate(port, "/v1/reviews", review(uuid(131), uuid(130)))
      sealed.(uuid(132), "github.com/test/plain", %{"README.md" => "second\n"})
      sealed.(uuid(133), "github.com/test/app", %{"README.md" => "elsewhere\n"})

      {200, %{"state" => "open"}} =
        submit(port, %{
          "change_id" => uuid(134),
          "snapshot_id" => snapshot_id,
          "repository" => "github.com/test/plain",
          "base_revision" => revisions["plain"],
          "entries" => [write("README.md", "open\n")]
        })

      git(remote, ["update-ref", "refs/heads/work/review-#{uuid(135)}", base])
      {409, _} = orchestrate(port, "/v1/reviews", review(uuid(135), uuid(130)))
      fpr = fingerprint_of(home, uuid(132))
      ok = review_update(uuid(136), uuid(131), uuid(132), first, fpr)
      refs = git(remote, ["for-each-ref"])

      for body <- [
            "not json",
            Map.delete(ok, "fingerprint"),
            %{ok | "fingerprint" => nil},
            %{ok | "fingerprint" => "fpr_" <> String.duplicate("A", 64)},
            Map.put(ok, "extra", 1),
            Map.put(ok, "target", "develop"),
            %{ok | "update_id" => "x"},
            %{ok | "review_id" => 1},
            %{ok | "change_id" => uuid(132) <> "0"},
            %{ok | "revision" => commit_of(home, first)}
          ] do
        assert {400, %{"error" => %{"code" => "invalid_request"}}} =
                 orchestrate(port, "/v1/review-updates", body)
      end

      assert {403, %{"error" => %{"code" => "forbidden"}}} =
               orchestrate(port, "/v1/review-updates", ok, @token)

      refusals = [
        {%{ok | "review_id" => uuid(139)}, 404, "not_found", %{"review_id" => uuid(139)}},
        {%{ok | "review_id" => uuid(135)}, 409, "review_not_open", %{"review_id" => uuid(135)}},
        {%{ok | "change_id" => uuid(138)}, 404, "not_found", %{"change_id" => uuid(138)}},
        {%{ok | "change_id" => uuid(134)}, 409, "change_not_sealed", %{"change_id" => uuid(134)}},
        {%{ok | "change_id" => uuid(133)}, 409, "repository_mismatch",
         %{"repository" => "github.com/test/plain"}},
        {%{ok | "revision" => rev(0)}, 409, "revision_mismatch", %{"revision" => first}},
        {%{ok | "fingerprint" => fingerprint(1)}, 409, "fingerprint_mismatch",
         %{"change_id" => uuid(132), "fingerprint" => fpr}}
      ]

      for {body, status, code, details} <- refusals do
        assert {^status, %{"error" => %{"code" => ^code, "details" => got}}} =
                 orchestrate(port, "/v1/review-updates", body)

        assert Map.take(got, Map.keys(details)) == details, code
      end

      # The repository is no longer allowed, then its remote is one Code's cache does not hold.
      config = Path.join(home, "config.json")
      allowed = config |> File.read!() |> JSON.decode!()
      AtlasCode.stop(pid)

      for {repositories, status, code} <- [
            {Map.delete(allowed["repositories"], "github.com/test/plain"), 403, "forbidden"},
            {%{allowed["repositories"] | "github.com/test/plain" => "file://" <> remote <> "/."},
             409, "conflict"}
          ] do
        File.write!(config, JSON.encode!(%{allowed | "repositories" => repositories}))
        {:ok, pid, port} = AtlasCode.start(home)

        assert {^status, %{"error" => %{"code" => ^code}}} =
                 orchestrate(port, "/v1/review-updates", ok)

        AtlasCode.stop(pid)
      end

      File.write!(config, JSON.encode!(allowed))
      {:ok, pid, port} = AtlasCode.start(home)
      on_exit(fn -> AtlasCode.stop(pid) end)

      assert git(remote, ["for-each-ref"]) == refs
      refute File.exists?(Path.join(home, "review-updates"))

      assert %{"revision" => ^first, "change_id" => "00000000-0000-4000-8000-000000000130"} =
               JSON.decode!(File.read!(Path.join([home, "reviews", uuid(131) <> ".json"])))

      # Every refused update ID is still free.
      assert {200, %{"previous_revision" => ^first}} =
               orchestrate(port, "/v1/review-updates", ok)
    end

    test "a location moved by someone else or refused by the remote is never overwritten", %{
      port: port,
      home: home,
      remote: remote,
      sealed: sealed
    } do
      first = sealed.(uuid(140), "github.com/test/plain", %{"README.md" => "first\n"})
      {200, _} = orchestrate(port, "/v1/reviews", review(uuid(141), uuid(140)))
      sealed.(uuid(142), "github.com/test/plain", %{"README.md" => "second\n"})
      fpr = fingerprint_of(home, uuid(142))
      location = "refs/heads/work/review-" <> uuid(141)
      pushed = on_top(remote, location)

      body = review_update(uuid(143), uuid(141), uuid(142), first, fpr)

      assert {409,
              %{"error" => %{"code" => "location_moved", "details" => %{"current" => current}}} =
                error} = orchestrate(port, "/v1/review-updates", body)

      assert commit_of(home, current) == pushed
      assert {409, ^error} = orchestrate(port, "/v1/review-updates", body)
      assert git(remote, ["rev-parse", location]) == pushed <> "\n"

      assert %{"revision" => ^first, "change_id" => "00000000-0000-4000-8000-000000000140"} =
               JSON.decode!(File.read!(Path.join([home, "reviews", uuid(141) <> ".json"])))

      # A person pushed on top of our update after its response was lost: it still counts.
      sealed.(uuid(144), "github.com/test/plain", %{"README.md" => "landed\n"})
      {200, _} = orchestrate(port, "/v1/reviews", review(uuid(145), uuid(144)))
      sealed.(uuid(146), "github.com/test/plain", %{"README.md" => "after\n"})

      landed =
        review_update(
          uuid(147),
          uuid(145),
          uuid(146),
          commit_revision(home, uuid(144)),
          fingerprint_of(home, uuid(146))
        )

      assert {200, reply} = orchestrate(port, "/v1/review-updates", landed)
      file = Path.join([home, "review-updates", uuid(147) <> ".json"])
      File.write!(file, JSON.encode!(%{JSON.decode!(File.read!(file)) | "phase" => "pushing"}))
      on_top(remote, "refs/heads/work/review-" <> uuid(145))
      assert {200, ^reply} = orchestrate(port, "/v1/review-updates", landed)

      # Branch policy on the remote refuses the location's update.
      sealed.(uuid(148), "github.com/test/plain", %{"README.md" => "protected\n"})

      {200, %{"revision" => protected}} =
        orchestrate(port, "/v1/reviews", review(uuid(149), uuid(148)))

      hook = Path.join([remote, "hooks", "pre-receive"])
      File.mkdir_p!(Path.dirname(hook))
      File.write!(hook, "#!/bin/sh\necho \"work branches are protected\" >&2\nexit 1\n")
      File.chmod!(hook, 0o755)
      refused = review_update(uuid(150), uuid(149), uuid(142), protected, fpr)

      assert {409, %{"error" => %{"code" => "update_refused"}} = error} =
               orchestrate(port, "/v1/review-updates", refused)

      refute JSON.encode!(error) =~ "protected"
      File.rm!(hook)
      assert {409, ^error} = orchestrate(port, "/v1/review-updates", refused)

      assert git(remote, ["rev-parse", "refs/heads/work/review-" <> uuid(149)]) ==
               commit_of(home, protected) <> "\n"
    end
  end

  describe "migration" do
    setup %{tmp_dir: dir}, do: provider(dir, "migration-home")

    test "an older home is refused until migrated; then its edits, phases and evidence carry over",
         %{
           tmp_dir: dir,
           port: port,
           pid: pid,
           home: home,
           remote: remote,
           base: base,
           sealed: sealed,
           snapshot_id: "sha256:" <> successor = snapshot_id,
           revisions: revisions
         } do
      pr = %{"base" => "develop", "title" => "Fix", "body" => "Fixes it." <> @attribution}
      {x, w, z, f, y} = {uuid(110), uuid(111), uuid(112), uuid(113), uuid(114)}
      x_revision = sealed.(x, "github.com/test/app", %{"README.md" => "published\n"})
      w_revision = sealed.(w, "github.com/test/app", %{"README.md" => "pushed\n"})
      z_revision = sealed.(z, "github.com/test/plain", %{"README.md" => "pushing\n"})
      f_revision = sealed.(f, "github.com/test/app", %{"README.md" => "failed\n"})

      # An open change with one of its two blobs uploaded.
      open = %{
        "change_id" => y,
        "snapshot_id" => snapshot_id,
        "repository" => "github.com/test/plain",
        "base_revision" => revisions["plain"],
        "entries" => [write("a.txt", "a\n"), write("b.txt", "b\n")]
      }

      {200, %{"state" => "open"}} = submit(port, open)
      {200, %{"missing" => [missing]}} = upload(port, y, hex("a\n"), "a\n")
      AtlasCode.stop(pid)

      # Rewrite the home into the shape Code wrote before revision handles.
      commits =
        Map.new([x_revision, w_revision, z_revision, f_revision], &{&1, commit_of(home, &1)})

      v2 = File.read!(Path.join([home, "snapshots", successor <> ".json"]))
      manifest = JSON.decode!(v2)

      v1 =
        JSON.encode!(%{
          "entries" => manifest["entries"],
          "repositories" =>
            for(
              r <- manifest["repositories"],
              do: %{"commit" => base, "path" => r["path"], "repository" => r["repository"]}
            )
        })

      old = hex(v1)
      File.write!(Path.join([home, "snapshots", old <> ".json"]), v1)
      File.rm!(Path.join([home, "snapshots", successor <> ".json"]))

      requests =
        for id <- [x, w, z, f, y], into: %{} do
          change = Path.join([home, "changes", id])
          request = File.read!(Path.join(change, "request.json"))
          decoded = JSON.decode!(request)

          File.write!(
            Path.join(change, "change.json"),
            JSON.encode!(%{
              "base_commit" => base,
              "change_id" => id,
              "entries" => decoded["entries"],
              "repository" => decoded["repository"],
              "snapshot_id" => "sha256:" <> old
            })
          )

          File.rm!(Path.join(change, "request.json"))

          case File.read(Path.join(change, "revision")) do
            {:ok, revision} ->
              File.write!(Path.join(change, "commit"), commits[revision])
              File.rm!(Path.join(change, "revision"))

            {:error, :enoent} ->
              :ok
          end

          {id, request}
        end

      File.rm_rf!(Path.join(home, "revisions"))

      [cache] =
        Path.wildcard(Path.join([home, "cache", "*.git"]))
        |> Enum.filter(&commit?(&1, commits[x_revision]))

      git(cache, [
        "push",
        "-q",
        remote,
        "#{commits[x_revision]}:refs/heads/work/p1",
        "#{commits[w_revision]}:refs/heads/work/p2"
      ])

      File.write!(Path.join(dir, "pr-url"), "https://github.com/test/app/pull/7")

      publications = %{
        uuid(120) => %{
          "request" => %{
            "publication_id" => uuid(120),
            "change_id" => x,
            "branch" => "work/p1",
            "pull_request" => pr
          },
          "phase" => "published",
          "repository" => "github.com/test/app",
          "base_commit" => base,
          "commit" => commits[x_revision],
          "pull_request" => %{"url" => "https://github.com/test/app/pull/7", "base" => "develop"}
        },
        uuid(121) => %{
          "request" => %{
            "publication_id" => uuid(121),
            "change_id" => w,
            "branch" => "work/p2",
            "pull_request" => pr
          },
          "phase" => "pushed",
          "repository" => "github.com/test/app",
          "base_commit" => base,
          "commit" => commits[w_revision]
        },
        uuid(122) => %{
          "request" => %{"publication_id" => uuid(122), "change_id" => z, "branch" => "work/p3"},
          "phase" => "pushing",
          "repository" => "github.com/test/plain",
          "base_commit" => base,
          "commit" => commits[z_revision]
        },
        uuid(123) => %{
          "request" => %{"publication_id" => uuid(123), "change_id" => f, "branch" => "work/p4"},
          "phase" => "failed",
          "repository" => "github.com/test/app",
          "base_commit" => base,
          "commit" => commits[f_revision]
        }
      }

      File.mkdir_p!(Path.join(home, "publications"))

      for {id, record} <- publications,
          do: File.write!(Path.join([home, "publications", id <> ".json"]), JSON.encode!(record))

      evidence = files(home)

      assert_raise RuntimeError, ~r/records from before revision handles/, fn ->
        AtlasCode.start(home)
      end

      counts = %{"snapshots" => 1, "changes" => 5, "reviews" => 4}
      assert AtlasCode.Migration.run(home) == counts
      migrated = files(home)

      # Nothing older changed; the counterparts are exactly what the API writes today.
      assert Map.take(migrated, Map.keys(evidence)) == evidence
      assert migrated["snapshots/#{old}.successor"] == snapshot_id
      assert migrated["snapshots/#{successor}.json"] == v2
      for {id, request} <- requests, do: assert(migrated["changes/#{id}/request.json"] == request)
      assert migrated["changes/#{x}/revision"] == x_revision
      refute Map.has_key?(migrated, "changes/#{y}/revision")
      assert AtlasCode.Migration.run(home) == counts
      # A repeat adds only its own ownership tombstone.
      records = &Map.reject(&1, fn {path, _} -> String.starts_with?(path, "service.owner") end)
      assert records.(files(home)) == records.(migrated)

      {:ok, pid, port} = AtlasCode.start(home)

      assert {409,
              %{
                "error" => %{
                  "code" => "snapshot_superseded",
                  "details" => %{"successor" => ^snapshot_id}
                }
              }} =
               request(port, :get, "/v1/snapshots/sha256:#{old}/manifest")

      assert {409, %{"error" => %{"code" => "snapshot_superseded"}}} =
               request(port, :get, "/v1/snapshots/sha256:#{old}/archive?path=app")

      assert {200, %{"version" => 2}} =
               request(port, :get, "/v1/snapshots/#{snapshot_id}/manifest")

      # The open change resumes with the same request; the sealed one replays its revision.
      assert {200, %{"state" => "open", "missing" => [^missing]}} = submit(port, open)
      {200, _} = upload(port, y, hex("b\n"), "b\n")
      assert {200, %{"state" => "sealed", "revision" => "rev_" <> _}} = seal(port, y)

      assert {200, %{"state" => "sealed", "revision" => ^x_revision}} =
               submit(port, JSON.decode!(requests[x]))

      # Each publication answers its equivalent review request from its recorded phase.
      equivalent =
        &%{
          "review_id" => &1,
          "change_id" => &2,
          "target" => "develop",
          "title" => "Fix",
          "body" => pr["body"]
        }

      assert {200,
              %{"revision" => ^x_revision, "review_url" => "https://github.com/test/app/pull/7"}} =
               orchestrate(port, "/v1/reviews", equivalent.(uuid(120), x))

      refute File.exists?(Path.join(dir, "gh-calls"))

      assert {200, %{"revision" => ^w_revision, "state" => "open"}} =
               orchestrate(port, "/v1/reviews", equivalent.(uuid(121), w))

      assert ["1 pr list --repo=test/app --head=work/p2 " <> _] =
               dir |> Path.join("gh-calls") |> File.read!() |> String.split("\n", trim: true)

      assert git(remote, ["rev-parse", "refs/heads/work/p2"]) == commits[w_revision] <> "\n"

      assert git(remote, [
               "for-each-ref",
               "--format=%(refname)",
               "refs/heads/work/review-#{uuid(121)}"
             ]) == ""

      assert {409, %{"error" => %{"code" => "conflict"}}} =
               orchestrate(port, "/v1/reviews", equivalent.(uuid(122), z))

      assert {409, %{"error" => %{"code" => "conflict"}}} =
               orchestrate(port, "/v1/reviews", equivalent.(uuid(123), f))

      # A migrated review integrates like any other; one without a target never does.
      target = revisions["app"]

      assert {200, %{"method" => "fast_forward", "revision" => ^x_revision}} =
               orchestrate(
                 port,
                 "/v1/integrations",
                 integration(uuid(124), uuid(120), x_revision, target)
               )

      assert git(remote, ["rev-parse", "refs/heads/develop"]) == commits[x_revision] <> "\n"

      {200, %{"revision" => plain}} = resolve(port, "github.com/test/plain", "develop")

      File.write!(
        Path.join([home, "reviews", uuid(122) <> ".json"]),
        JSON.encode!(%{JSON.decode!(migrated["reviews/#{uuid(122)}.json"]) | "phase" => "open"})
      )

      assert {409, %{"error" => %{"code" => "review_has_no_target"}}} =
               orchestrate(
                 port,
                 "/v1/integrations",
                 integration(uuid(125), uuid(122), z_revision, plain)
               )

      # The pushing publication's change is reviewed again at a new location.
      assert {200, %{"revision" => ^z_revision}} =
               orchestrate(port, "/v1/reviews", review(uuid(126), z))

      AtlasCode.stop(pid)

      # An interrupted or contradicted migration keeps Code from starting.
      File.write!(Path.join(home, "migration.json"), ~s({"state":"running"}))

      assert_raise RuntimeError,
                   ~r/records from before revision handles \(migration.json\)/,
                   fn -> AtlasCode.start(home) end

      File.write!(Path.join([home, "changes", x, "request.json"]), "{}")

      assert_raise RuntimeError, ~r/exists with other content/, fn ->
        AtlasCode.Migration.run(home)
      end

      assert_raise RuntimeError, ~r/before revision handles/, fn -> AtlasCode.start(home) end
      File.write!(Path.join([home, "changes", x, "request.json"]), requests[x])
      assert AtlasCode.Migration.run(home) == counts
      {:ok, pid, _port} = AtlasCode.start(home)
      AtlasCode.stop(pid)
    end
  end

  defp serve(dir, name, repositories, config \\ %{}, prepare \\ fn _home -> :ok end) do
    {home, port, _pid} = serve_pid(dir, name, repositories, config, prepare)
    {home, port}
  end

  defp serve_pid(dir, name, repositories, config \\ %{}, prepare \\ fn _home -> :ok end) do
    home = Path.join(dir, name)
    File.mkdir!(home)

    File.write!(
      Path.join(home, "config.json"),
      JSON.encode!(Map.merge(config, %{"port" => 0, "repositories" => repositories}))
    )

    File.write!(Path.join(home, "runtime.token"), @token <> "\n")
    File.chmod!(Path.join(home, "runtime.token"), 0o600)
    prepare.(home)
    {:ok, pid, port} = AtlasCode.start(home)
    on_exit(fn -> AtlasCode.stop(pid) end)
    {home, port, pid}
  end

  # A bare local remote behind two repository names: github.com/test/plain uses it directly,
  # github.com/test/app through a GitHub URL that Code's cache rewrites to it, so the GitHub
  # provider mapping applies while no push or fetch leaves this machine. Resolving the GitHub
  # URL would, so that repository's handle is recorded through Code's own mapping instead.
  defp provider(dir, name) do
    {source, base} =
      fixture(dir, "app", fn source ->
        File.write!(Path.join(source, "README.md"), "hello\n")
        File.write!(Path.join(source, "other.txt"), "other\n")
      end)

    remote = Path.join(dir, "remote.git")
    git(dir, ["clone", "-q", "--bare", source, remote])
    # Bare repositories keep no reflog by default; it counts the remote's ref updates.
    git(remote, ["config", "core.logAllRefUpdates", "always"])
    gh = Path.join(dir, "gh")
    File.write!(gh, @gh)
    File.chmod!(gh, 0o755)
    hub = "https://github.com/test/app.git"
    repositories = %{"github.com/test/app" => hub, "github.com/test/plain" => "file://" <> remote}

    {home, port, pid} =
      serve_pid(dir, name, repositories, %{"gh" => gh}, fn home ->
        File.write!(Path.join(home, "orchestrator.token"), @orchestrator <> "\n")
        File.chmod!(Path.join(home, "orchestrator.token"), 0o600)
        cache = Path.join([home, "cache", hex(["github.com/test/app", 0, hub]) <> ".git"])
        git(dir, ["init", "-q", "--bare", cache])
        git(cache, ["config", "url.file://#{remote}.insteadOf", hub])
      end)

    {200, %{"revision" => plain}} = resolve(port, "github.com/test/plain", "develop")

    revisions = %{
      "plain" => plain,
      "app" => AtlasCode.put_revision(home, "github.com/test/app", base)
    }

    {200, %{"snapshot_id" => snapshot_id}} =
      snapshot(port, [
        %{"repository" => "github.com/test/app", "revision" => revisions["app"], "path" => "app"},
        %{
          "repository" => "github.com/test/plain",
          "revision" => revisions["plain"],
          "path" => "plain"
        }
      ])

    sealed = fn id, repository, files ->
      name = repository |> String.split("/") |> List.last()

      {200, %{"state" => "open"}} =
        submit(port, %{
          "change_id" => id,
          "snapshot_id" => snapshot_id,
          "repository" => repository,
          "base_revision" => revisions[name],
          "entries" => for({path, bytes} <- files, do: write(path, bytes))
        })

      for {_path, bytes} <- files, do: {200, _} = upload(port, id, hex(bytes), bytes)
      {200, %{"state" => "sealed", "revision" => revision}} = seal(port, id)
      revision
    end

    %{
      port: port,
      pid: pid,
      home: home,
      remote: remote,
      base: base,
      sealed: sealed,
      snapshot_id: snapshot_id,
      revisions: revisions
    }
  end

  # Advances the remote's develop with a commit of `files` made in a clone of it.
  defp advance(dir, remote, files) do
    clone = Path.join(dir, "advance-#{System.unique_integer([:positive])}")
    git(dir, ["clone", "-q", remote, clone])
    for {path, bytes} <- files, do: File.write!(Path.join(clone, path), bytes)
    git(clone, ["add", "-A"])
    git(clone, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "advance"])
    git(clone, ["push", "-q", "origin", "develop"])
    clone |> git(["rev-parse", "HEAD"]) |> String.trim()
  end

  # Every file under home by relative path, with its bytes.
  defp files(home) do
    for file <- Path.wildcard(Path.join(home, "**"), match_dot: true),
        File.regular?(file),
        into: %{},
        do: {Path.relative_to(file, home), File.read!(file)}
  end

  # The record of the home's current owner.
  defp owner(home), do: JSON.decode!(File.read!(Path.join([home, "service.owner", "owner.json"])))

  # An owner directory left by a service whose OS process `os_pid` ended without releasing it.
  defp stale_owner(home, os_pid) do
    owner = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    staging = Path.join(home, "stale.tmp")
    File.mkdir!(staging)

    File.write!(
      Path.join(staging, "owner.json"),
      JSON.encode!(%{
        "kind" => "service",
        "node" => "nonode@nohost",
        "os_pid" => os_pid,
        "owner" => owner,
        "started_at" => "2026-11-09T00:00:00Z"
      })
    )

    File.rename!(staging, Path.join(home, "service.owner"))
    owner
  end

  # A stand-in for ps (-p PID -o pid=) that sees this process and PID 1 and runs `body` for
  # any other PID.
  defp ps(dir, name, body) do
    file = Path.join(dir, "ps-" <> name)

    File.write!(file, """
    #!/bin/sh
    if [ "$2" = "#{System.pid()}" ] || [ "$2" = 1 ]; then echo "  $2"; exit 0; fi
    #{body}
    """)

    File.chmod!(file, 0o755)
    file
  end

  # The private commit behind a handle, read from Code's own mapping.
  defp commit_of(home, revision),
    do: JSON.decode!(File.read!(Path.join([home, "revisions", revision <> ".json"])))["commit"]

  defp rev(n), do: "rev_" <> String.pad_leading(Integer.to_string(n), 64, "0")
  defp fingerprint(n), do: "fpr_" <> String.pad_leading(Integer.to_string(n), 64, "0")

  # Recomputed from the stored request the way Runtime's submit computes it.
  defp fingerprint_of(home, change) do
    request = JSON.decode!(File.read!(Path.join([home, "changes", change, "request.json"])))
    "fpr_" <> hex(JSON.encode!(Map.delete(request, "change_id")))
  end

  defp review(id, change),
    do: %{
      "review_id" => id,
      "change_id" => change,
      "target" => "develop",
      "title" => "Fix",
      "body" => "Fixes it." <> @attribution
    }

  defp integration(id, review, revision, target),
    do: %{
      "integration_id" => id,
      "review_id" => review,
      "revision" => revision,
      "target_revision" => target
    }

  defp review_update(id, review, change, revision, fingerprint),
    do: %{
      "update_id" => id,
      "review_id" => review,
      "change_id" => change,
      "revision" => revision,
      "fingerprint" => fingerprint
    }

  # The sealed revision of a change, from Code's own record.
  defp commit_revision(home, change),
    do: File.read!(Path.join([home, "changes", change, "revision"]))

  # A third party's commit on top of `ref` in the bare remote, made without a work tree.
  defp on_top(remote, ref) do
    head = remote |> git(["rev-parse", ref]) |> String.trim()

    commit =
      remote
      |> git([
        "-c",
        "user.name=t",
        "-c",
        "user.email=t@t",
        "commit-tree",
        head <> "^{tree}",
        "-p",
        head,
        "-m",
        "pushed by someone else"
      ])
      |> String.trim()

    git(remote, ["update-ref", ref, commit])
    commit
  end

  defp reflog(remote, ref),
    do: remote |> git(["reflog", "show", ref]) |> String.split("\n", trim: true) |> length()

  defp uuid(n),
    do: "00000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(n), 12, "0")

  defp commit?(dir, commit),
    do:
      match?(
        {_, 0},
        System.cmd("git", ["cat-file", "-e", commit], cd: dir, stderr_to_stdout: true)
      )

  defp orchestrate(port, path, body, token \\ @orchestrator) do
    body = if is_binary(body), do: body, else: JSON.encode!(body)

    {status, reply} =
      send_request(port, :post, path, body, [
        {~c"authorization", ~c"Bearer " ++ String.to_charlist(token)}
      ])

    {status, JSON.decode!(reply)}
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

  defp upload(port, id, digest, bytes),
    do: raw(port, :put, "/v1/changes/#{id}/blobs/#{digest}", bytes)

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

  defp resolve(port, repository, reference),
    do:
      raw(
        port,
        :post,
        "/v1/references/resolve",
        JSON.encode!(%{"repository" => repository, "reference" => reference})
      )

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
