defmodule AtlasCode.BoundaryTest do
  # The facade AtlasCode.Boundary on a running Code: a temporary home with a local bare
  # repository, started with register: true, reached through AtlasCode.settings/0. Not
  # async: one instance holds the registered name at a time.
  use ExUnit.Case, async: false

  alias AtlasCode.{Boundary, Service}
  alias AtlasCode.Boundary.{Outcome, SnapshotRepository, UnsupportedEntry}
  alias AtlasCodeBoundary.Generator.{InvalidInput, NotPermitted}

  setup {AtlasCode.TestDir, :tmp_dir}

  @token "runtime-secret-token"
  @client {"test:flow", [:snapshot]}

  setup %{tmp_dir: dir} do
    {remote, commit} = bare(dir, "app", %{"README.md" => "hello\n", "bin/run" => "run\n"})
    {home, pid, port} = start(dir, "home", %{"github.com/test/app" => "file://" <> remote})
    %{home: home, pid: pid, port: port, remote: remote, commit: commit}
  end

  describe "resolve_reference" do
    test "resolves a branch of the registered instance to its revision handle",
         %{home: home, commit: commit} do
      assert %Outcome.Resolved{repository: "github.com/test/app", reference: "develop"} =
               resolved = Boundary.resolve_reference(@client, resolve_input("develop"))

      assert resolved.revision == AtlasCode.handle("github.com/test/app", commit)

      assert JSON.decode!(
               File.read!(Path.join([home, "revisions", resolved.revision <> ".json"]))
             ) ==
               %{"commit" => commit, "repository" => "github.com/test/app"}
    end

    test "answers what the HTTP route answers, as an outcome", %{port: port} do
      for {input, outcome} <- [
            {resolve_input("develop"), Outcome.Resolved},
            {resolve_input("missing"), Outcome.UnknownReference},
            {resolve_input("bad..name"), Outcome.InvalidRequest},
            {%{"repository" => "github.com/test/other", "reference" => "develop"},
             Outcome.Forbidden}
          ] do
        assert %^outcome{} = answer = Boundary.resolve_reference(@client, input)
        response = http(port, "/v1/references/resolve", input)
        assert response == as_http(answer)
        # The facade's outcome and the HTTP status both still say what the Service says.
        assert response == Service.resolve_reference(AtlasCode.settings(), input)
      end
    end

    test "refuses what the contract does not allow before it reaches Code" do
      assert %NotPermitted{right: :snapshot} =
               Boundary.resolve_reference({"test:other", []}, resolve_input("develop"))

      assert %InvalidInput{capability: :resolve_reference} =
               Boundary.resolve_reference(@client, %{"repository" => "github.com/test/app"})

      assert %InvalidInput{} =
               Boundary.resolve_reference(@client, Map.put(resolve_input("develop"), "x", 1))
    end

    test "a remote that fails is provider_unavailable", %{tmp_dir: dir, pid: pid} do
      :ok = AtlasCode.stop(pid)
      start(dir, "broken", %{"github.com/test/app" => "file://" <> Path.join(dir, "nowhere.git")})

      assert %Outcome.ProviderUnavailable{message: "git ls-remote failed" <> _} =
               Boundary.resolve_reference(@client, resolve_input("develop"))
    end
  end

  describe "create_snapshot" do
    test "snapshots a revision of the registered instance", %{home: home, port: port} do
      %Outcome.Resolved{revision: revision} =
        Boundary.resolve_reference(@client, resolve_input("develop"))

      input = %{"repositories" => [repository(revision, "app")]}

      assert %Outcome.Created{
               snapshot_id: "sha256:" <> hex,
               repositories: [
                 %SnapshotRepository{
                   repository: "github.com/test/app",
                   revision: ^revision,
                   path: "app"
                 }
               ]
             } = created = Boundary.create_snapshot(@client, input)

      assert %{"version" => 2, "entries" => entries} =
               JSON.decode!(File.read!(Path.join([home, "snapshots", hex <> ".json"])))

      assert Enum.map(entries, & &1["path"]) == ["app/README.md", "app/bin/run"]
      assert http(port, "/v1/snapshots", input) == as_http(created)
    end

    test "answers each refusal as its outcome, as the HTTP route does",
         %{tmp_dir: dir, pid: pid} do
      :ok = AtlasCode.stop(pid)
      {plain, _} = bare(dir, "plain", %{"ok.txt" => "ok\n"})

      {unsupported, _} =
        bare(dir, "links", %{"ok.txt" => "ok\n"}, &File.ln_s!("/etc", &1 <> "/abs"))

      {home, _pid, port} =
        start(dir, "refusals", %{
          "github.com/test/plain" => "file://" <> plain,
          "github.com/test/links" => "file://" <> unsupported,
          "github.com/test/broken" => "file://" <> Path.join(dir, "nowhere.git")
        })

      %Outcome.Resolved{revision: plain_revision} =
        Boundary.resolve_reference(@client, %{
          "repository" => "github.com/test/plain",
          "reference" => "develop"
        })

      %Outcome.Resolved{revision: links_revision} =
        Boundary.resolve_reference(@client, %{
          "repository" => "github.com/test/links",
          "reference" => "develop"
        })

      # not_found: a revision resolved on a branch the remote deleted before any fetch.
      source = Path.join(dir, "plain-source")
      git(source, ["checkout", "-q", "-b", "gone"])
      File.write!(Path.join(source, "gone.txt"), "gone\n")
      git(source, ["add", "-A"])
      git(source, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "gone"])
      git(source, ["push", "-q", plain, "gone"])

      %Outcome.Resolved{revision: gone_revision} =
        Boundary.resolve_reference(@client, %{
          "repository" => "github.com/test/plain",
          "reference" => "gone"
        })

      git(plain, ["update-ref", "-d", "refs/heads/gone"])

      # provider_unavailable: a known revision of a remote that cannot be fetched.
      broken_revision =
        AtlasCode.put_revision(home, "github.com/test/broken", String.duplicate("a", 40))

      unknown = "rev_" <> String.duplicate("0", 64)
      plain = &%{"repository" => "github.com/test/plain", "revision" => &1, "path" => &2}

      cases = [
        {[plain.(plain_revision, "a"), plain.(plain_revision, "a/b")], Outcome.InvalidRequest},
        {[plain.("rev_x", "a")], Outcome.InvalidRequest},
        {[plain.(plain_revision, "../a")], Outcome.InvalidRequest},
        {[], Outcome.InvalidRequest},
        {[%{plain.(plain_revision, "a") | "repository" => "github.com/test/other"}],
         Outcome.Forbidden},
        {[plain.(unknown, "a")], Outcome.UnknownRevision},
        {[%{plain.(links_revision, "a") | "repository" => "github.com/test/plain"}],
         Outcome.RepositoryMismatch},
        {[%{plain.(links_revision, "a") | "repository" => "github.com/test/links"}],
         Outcome.UnsupportedContent},
        {[plain.(gone_revision, "a")], Outcome.NotFound},
        {[%{plain.(broken_revision, "a") | "repository" => "github.com/test/broken"}],
         Outcome.ProviderUnavailable}
      ]

      for {repositories, outcome} <- cases do
        input = %{"repositories" => repositories}

        assert %^outcome{} = answer = Boundary.create_snapshot(@client, input),
               inspect(repositories)

        response = http(port, "/v1/snapshots", input)
        assert response == as_http(answer), inspect(repositories)
        assert response == Service.create_snapshot(AtlasCode.settings(), input)
      end

      assert %Outcome.UnsupportedContent{
               entries: [
                 %UnsupportedEntry{
                   repository: "github.com/test/links",
                   path: "abs",
                   reason: :symlink_target
                 }
               ]
             } =
               Boundary.create_snapshot(@client, %{
                 "repositories" => [
                   %{
                     "repository" => "github.com/test/links",
                     "revision" => links_revision,
                     "path" => "a"
                   }
                 ]
               })
    end

    test "refuses a malformed input with the facade's own answer, as HTTP refuses its body",
         %{port: port} do
      input = %{"repositories" => [%{"repository" => "github.com/test/app"}]}

      assert %InvalidInput{capability: :create_snapshot} =
               Boundary.create_snapshot(@client, input)

      assert {400, %{"error" => %{"code" => "invalid_request", "message" => "Body must be" <> _}}} =
               http(port, "/v1/snapshots", input)

      # repositories given no list: refused like any malformed body, never a raise (or a 500).
      for repositories <- [%{}, %{"path" => "a"}, "x", 1, true] do
        input = %{"repositories" => repositories}

        assert %InvalidInput{capability: :create_snapshot} =
                 Boundary.create_snapshot(@client, input)

        assert http(port, "/v1/snapshots", input) == Service.malformed(:create_snapshot),
               inspect(repositories)
      end
    end
  end

  describe "the registered instance (AtlasCode.settings/0)" do
    test "is the started instance's settings, without what only its server needs",
         %{home: home} do
      settings = AtlasCode.settings()
      assert settings.home == home

      assert settings.repositories == %{
               "github.com/test/app" => settings.repositories["github.com/test/app"]
             }

      refute Map.has_key?(settings, :port)
      refute Map.has_key?(settings, :owner)
    end

    test "follows a restart: the facade reaches the newest registered instance, never a stopped one",
         %{tmp_dir: dir, pid: pid, home: first} do
      assert %Outcome.Resolved{} = Boundary.resolve_reference(@client, resolve_input("develop"))
      :ok = AtlasCode.stop(pid)

      assert_raise RuntimeError, ~r/No Code instance is registered/, fn ->
        AtlasCode.settings()
      end

      assert_raise RuntimeError, ~r/No Code instance is registered/, fn ->
        Boundary.resolve_reference(@client, resolve_input("develop"))
      end

      {remote, commit} = bare(dir, "next", %{"next.txt" => "next\n"})

      {second, _pid, _port} =
        start(dir, "second", %{"github.com/test/next" => "file://" <> remote})

      assert AtlasCode.settings().home == second

      assert %Outcome.Resolved{revision: revision} =
               Boundary.resolve_reference(@client, %{
                 "repository" => "github.com/test/next",
                 "reference" => "develop"
               })

      assert revision == AtlasCode.handle("github.com/test/next", commit)
      assert File.exists?(Path.join([second, "revisions", revision <> ".json"]))
      refute File.exists?(Path.join([first, "revisions", revision <> ".json"]))

      assert %Outcome.Forbidden{repository: "github.com/test/app"} =
               Boundary.resolve_reference(@client, resolve_input("develop"))
    end

    test "ends when the instance's server goes down without stop/1", %{pid: pid} do
      instance = Process.whereis(AtlasCode)
      ref = Process.monitor(instance)
      # The killed server's supervisors log their end; that is expected here.
      ExUnit.CaptureLog.capture_log(fn ->
        Process.exit(pid, :kill)
        assert_receive {:DOWN, ^ref, :process, ^instance, :normal}
      end)

      assert_raise RuntimeError, ~r/No Code instance is registered/, fn ->
        AtlasCode.settings()
      end
    end

    test "only one: a second registered start is refused and gives its home back",
         %{tmp_dir: dir, home: home} do
      {remote, _} = bare(dir, "other", %{"x" => "x\n"})
      other = home(dir, "other-home", %{"github.com/test/other" => "file://" <> remote})

      assert_raise RuntimeError, ~r/cannot register/, fn ->
        AtlasCode.start(other, register: true)
      end

      refute File.exists?(Path.join(other, "service.owner"))
      assert AtlasCode.settings().home == home

      # Without register: true an instance serves HTTP but is not the facade's.
      {:ok, unregistered, _port} = AtlasCode.start(other)
      on_exit(fn -> AtlasCode.stop(unregistered) end)
      assert AtlasCode.settings().home == home
    end
  end

  # A response of the facade as the HTTP route renders it: status and body.
  defp as_http(%module{} = outcome) when module in [Outcome.Resolved, Outcome.Created],
    do: {200, module.dump(outcome)}

  defp as_http(%module{} = outcome) do
    {message, details} = Map.pop!(module.dump(outcome), "message")
    code = module |> Module.split() |> List.last() |> Macro.underscore()
    {status(code), %{"error" => %{"code" => code, "message" => message, "details" => details}}}
  end

  defp status("invalid_request"), do: 400
  defp status("forbidden"), do: 403
  defp status(code) when code in ["unknown_reference", "unknown_revision", "not_found"], do: 404
  defp status("repository_mismatch"), do: 409
  defp status("unsupported_content"), do: 422
  defp status("provider_unavailable"), do: 503

  defp resolve_input(reference),
    do: %{"repository" => "github.com/test/app", "reference" => reference}

  defp repository(revision, path),
    do: %{"repository" => "github.com/test/app", "revision" => revision, "path" => path}

  defp start(dir, name, repositories) do
    home = home(dir, name, repositories)
    {:ok, pid, port} = AtlasCode.start(home, register: true)
    on_exit(fn -> AtlasCode.stop(pid) end)
    {home, pid, port}
  end

  defp home(dir, name, repositories) do
    home = Path.join(dir, name)
    File.mkdir!(home)
    config = %{"port" => 0, "repositories" => repositories}
    File.write!(Path.join(home, "config.json"), JSON.encode!(config))
    File.write!(Path.join(home, "runtime.token"), @token <> "\n")
    File.chmod!(Path.join(home, "runtime.token"), 0o600)
    home
  end

  # A local bare repository with one commit of `files` on develop: Code's remote.
  defp bare(dir, name, files, extra \\ fn _source -> :ok end) do
    source = Path.join(dir, name <> "-source")
    git(dir, ["init", "-q", "-b", "develop", source])

    for {path, content} <- files do
      File.mkdir_p!(Path.dirname(Path.join(source, path)))
      File.write!(Path.join(source, path), content)
    end

    extra.(source)
    git(source, ["add", "-A"])
    git(source, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", name])
    remote = Path.join(dir, name <> ".git")
    git(dir, ["clone", "-q", "--bare", source, remote])
    {remote, source |> git(["rev-parse", "HEAD"]) |> String.trim()}
  end

  defp http(port, path, body) do
    request =
      {~c"http://127.0.0.1:#{port}#{path}",
       [{~c"authorization", ~c"Bearer " ++ String.to_charlist(@token)}], ~c"application/json",
       JSON.encode!(body)}

    {:ok, {{_, status, _}, _, reply}} =
      :httpc.request(:post, request, [timeout: 10_000, ssl: []], body_format: :binary)

    {status, JSON.decode!(reply)}
  end

  defp git(dir, args) do
    {output, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    output
  end
end
