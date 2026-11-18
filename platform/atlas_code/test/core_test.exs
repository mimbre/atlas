defmodule AtlasCode.CoreTest do
  @moduledoc """
  Code in the prod core (M3c-code-prod): anonymous base reads, the home's OS lock (and the
  older PID lock it must still honour) and the supervised, registered `AtlasCode.Core`.
  Not async: these change PATH and the one registered instance of this BEAM.
  """
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias AtlasCode.{Core, Lock, Service}

  setup {AtlasCode.TestDir, :tmp_dir}

  @repository "github.com/test/public"
  @private "github.com/test/private"
  @runtime_exs Path.expand("../../../products/software_factory/config/runtime.exs", __DIR__)

  setup %{tmp_dir: dir} do
    source = Path.join(dir, "source")
    git(dir, ["init", "-q", "-b", "develop", source])
    File.write!(Path.join(source, "README.md"), "hello\n")
    git(source, ["add", "README.md"])
    git(source, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "base"])
    %{source: source, url: "file://" <> source}
  end

  describe "anonymous reads" do
    test "a base resolve and fetch of a credentials-none repository run git with no credential helper; others keep gh's",
         %{tmp_dir: dir, url: url, source: source} do
      log = git_recorder(dir)

      # The same repository under two remotes, so each call tells which entry it is for.
      home =
        home(dir, %{
          @repository => %{"url" => url, "credentials" => "none"},
          @private => source
        })

      {:ok, pid, _port} = AtlasCode.start(home, register: true)
      on_exit(fn -> AtlasCode.stop(pid) end)
      settings = AtlasCode.settings()

      for repository <- [@repository, @private] do
        assert {200, %{"revision" => revision}} =
                 Service.resolve_reference(settings, %{
                   "repository" => repository,
                   "reference" => "develop"
                 })

        placement = %{"repository" => repository, "revision" => revision, "path" => "app"}

        assert {200, %{"snapshot_id" => _}} =
                 Service.create_snapshot(settings, %{"repositories" => [placement]})
      end

      calls = calls(log)
      remote = Enum.filter(calls, &Enum.any?(&1, fn arg -> arg in ["fetch", "ls-remote"] end))
      public = Enum.filter(remote, &(url in &1))
      private = Enum.filter(remote, &(source in &1))
      assert length(public) + length(private) == length(remote)

      # Both reads of the public repository happened, with no helper at all: only the empty
      # value, which clears every inherited one.
      assert Enum.any?(public, &("fetch" in &1)) and Enum.any?(public, &("ls-remote" in &1))

      for argv <- public do
        assert helpers(argv) == ["credential.helper="], inspect(argv)
        refute Enum.any?(argv, &(&1 =~ "gh")), inspect(argv)
      end

      # Same remote, default entry: gh's helper is still there (writes and other reads keep it).
      assert Enum.any?(private, &("fetch" in &1)) and Enum.any?(private, &("ls-remote" in &1))

      for argv <- private,
          do: assert("credential.helper=!gh auth git-credential" in helpers(argv))
    end

    test "config.json refuses other credential modes and extra members", %{tmp_dir: dir, url: url} do
      for entry <- [
            %{"url" => url, "credentials" => "gh"},
            %{"url" => url},
            %{"url" => url, "credentials" => "none", "token" => "x"},
            %{"url" => "", "credentials" => "none"}
          ] do
        home = home(dir, %{@repository => entry})
        assert_raise RuntimeError, ~r/credentials/, fn -> AtlasCode.start(home) end
      end
    end
  end

  describe "the home's OS lock" do
    test "is released by the kernel when the BEAM holding it is SIGKILLed", %{tmp_dir: dir} do
      home = Path.join(dir, "home")
      File.mkdir_p!(home)
      port = beam_taking_lock(home)

      assert wait_for(fn -> File.exists?(Path.join(home, "locked")) end)
      assert Lock.acquire(home) == :busy

      File.write!(Path.join(home, "go"), "")
      assert_receive {^port, {:exit_status, status}}, 15_000
      # 128 + SIGKILL: the BEAM had no chance to release anything itself.
      assert status == 137

      assert {:ok, lock} = wait_for(fn -> ok(Lock.acquire(home)) end)
      assert :ok = Lock.release(lock)
    end

    test "dies with its server, and the next start recovers the home without ps", %{
      tmp_dir: dir,
      url: url
    } do
      home = home(dir, %{@repository => url})
      {:ok, pid, _port} = AtlasCode.start(home)
      %{"owner" => first, "lock" => "flock"} = owner(home)
      assert Lock.acquire(home) == :busy

      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
      # The owner directory stays (crash semantics); only the lock went.
      assert owner(home)["owner"] == first
      assert {:ok, lock} = wait_for(fn -> ok(Lock.acquire(home)) end)
      :ok = Lock.release(lock)

      log =
        capture_log(fn ->
          send(self(), {:started, AtlasCode.start(home, ps: Path.join(dir, "no-such-ps"))})
        end)

      assert_received {:started, {:ok, pid, _port}}
      assert log =~ "from stopped owner #{first}"
      assert log =~ "its lock was free"
      assert File.exists?(Path.join(home, "service.owner.ended-" <> first))
      assert :ok = AtlasCode.stop(pid)
    end

    test "a stale owner with this very PID (a restarted container) is recovered, a live one never",
         %{tmp_dir: dir, url: url} do
      home = home(dir, %{@repository => url})
      stale = owner_record(home, String.to_integer(System.pid()), "flock")

      capture_log(fn -> send(self(), {:started, AtlasCode.start(home)}) end)
      assert_received {:started, {:ok, pid, _port}}
      assert File.exists?(Path.join(home, "service.owner.ended-" <> stale))
      live = owner(home)

      # Same BEAM, same PID, same ps: the lock alone refuses a second owner.
      assert_raise RuntimeError, ~r/is owned by service/, fn -> AtlasCode.start(home) end
      assert_raise RuntimeError, ~r/is owned by service/, fn -> AtlasCode.Migration.run(home) end
      assert {:error, message} = AtlasCode.unlock(home, live["owner"], always_absent(dir))
      assert message =~ "still running"
      assert owner(home) == live
      assert :ok = AtlasCode.stop(pid)
    end

    test "an old-style PID owner is honoured while its PID runs and taken over after", %{
      tmp_dir: dir,
      url: url
    } do
      home = home(dir, %{@repository => url})
      # A Code from before the OS lock, still running: it never takes service.lock.
      sleeper = Port.open({:spawn_executable, System.find_executable("sleep")}, args: ["60"])
      {:os_pid, os_pid} = Port.info(sleeper, :os_pid)
      on_exit(fn -> System.cmd("kill", ["-9", "#{os_pid}"], stderr_to_stdout: true) end)
      old = owner_record(home, os_pid, nil)
      record = owner(home)
      refute Map.has_key?(record, "lock")
      ps = liveness_ps(dir)

      for _ <- 1..2 do
        error = assert_raise RuntimeError, fn -> AtlasCode.start(home, ps: ps) end
        assert error.message =~ "is owned by service pid #{os_pid}"
        assert owner(home) == record
        # The refused start keeps no lock behind.
        assert {:ok, lock} = Lock.acquire(home)
        :ok = Lock.release(lock)
      end

      assert {:error, message} = AtlasCode.unlock(home, old, ps)
      assert message =~ "still running"

      Port.close(sleeper)
      System.cmd("kill", ["-9", "#{os_pid}"], stderr_to_stdout: true)
      assert wait_for(fn -> match?({_, 1}, System.cmd(ps, ["-p", "#{os_pid}", "-o", "pid="])) end)

      capture_log(fn -> send(self(), {:started, AtlasCode.start(home, ps: ps)}) end)
      assert_received {:started, {:ok, pid, _port}}

      assert JSON.decode!(
               File.read!(Path.join([home, "service.owner.ended-" <> old, "owner.json"]))
             ) ==
               record

      assert %{"lock" => "flock", "kind" => "service"} = owner(home)
      assert Lock.acquire(home) == :busy
      assert :ok = AtlasCode.stop(pid)
      assert {:ok, lock} = wait_for(fn -> ok(Lock.acquire(home)) end)
      :ok = Lock.release(lock)
    end
  end

  describe "AtlasCode.Core" do
    test "without code.home in the settings nothing is configured, started or written", %{
      tmp_dir: dir
    } do
      would_be = Path.join(dir, "code-home")

      for code <- [nil, %{"data" => Path.join(dir, "effects"), "repositories" => ["o/r"]}] do
        config = runtime_config(dir, code)
        assert config[:atlas_code][:service] == nil
        children = AtlasCode.Application.children(config[:atlas_code] || [])
        refute Enum.any?(children, &match?({Core, _}, &1))
      end

      refute Process.whereis(Core)
      refute File.exists?(would_be)
      assert_raise RuntimeError, ~r/No Code instance/, fn -> AtlasCode.settings() end

      # A home without sources is refused before anything runs.
      assert_raise RuntimeError, ~r/code.sources/, fn ->
        runtime_config(dir, %{"data" => dir, "repositories" => [], "home" => would_be})
      end

      refute File.exists?(would_be)
    end

    test "with code.home and code.sources but no flow.work_source nothing is configured, started or written",
         %{tmp_dir: dir, url: url} do
      would_be = Path.join(dir, "code-home")

      code = %{
        "data" => Path.join(dir, "effects"),
        "repositories" => ["o/r"],
        "home" => would_be,
        "sources" => %{@repository => %{"url" => url, "credentials" => "none"}}
      }

      # No flow block, and a flow block without a work source.
      for flow <- [nil, %{"tick_seconds" => 5}] do
        config = runtime_config(dir, code, if(flow, do: %{"flow" => flow}, else: %{}))
        assert config[:atlas_code][:service] == nil
        assert config[:atlas_flow][:work_source] == nil
        # The rest of the code block still applies: Code's effect receiver is configured.
        assert %{"dir" => _} = config[:atlas_code][:effects]
        children = AtlasCode.Application.children(config[:atlas_code])
        refute Enum.any?(children, &match?({Core, _}, &1))
      end

      refute Process.whereis(Core)
      refute File.exists?(would_be)
      assert_raise RuntimeError, ~r/No Code instance/, fn -> AtlasCode.settings() end

      # A home waiting for its work source is still checked.
      assert_raise RuntimeError, ~r/code.sources/, fn ->
        runtime_config(dir, Map.delete(code, "sources"))
      end
    end

    test "with code.home, code.sources and flow.work_source it starts supervised and registered, and restarts its server",
         %{tmp_dir: dir, url: url} do
      sources = %{@repository => %{"url" => url, "credentials" => "none"}}

      config =
        runtime_config(
          dir,
          %{
            "data" => Path.join(dir, "effects"),
            "repositories" => ["o/r"],
            "home" => Path.join(dir, "code-home"),
            "sources" => sources
          },
          %{"flow" => %{"work_source" => work_source(dir)}}
        )

      assert config[:atlas_flow][:work_source][:credentials_env] == "ATLAS_TEST_RUNTIMES"

      service = config[:atlas_code][:service]
      assert service == %{"home" => Path.join(dir, "code-home"), "repositories" => sources}
      assert [{Core, ^service}] = AtlasCode.Application.children(service: service)

      start_supervised!({Core, Map.put(service, "retry_ms", 50)})
      settings = wait_for(fn -> registered() end)
      assert settings.home == Path.join(dir, "code-home")
      assert MapSet.member?(settings.anonymous, @repository)

      assert {200, %{"revision" => "rev_" <> _}} =
               Service.resolve_reference(settings, %{
                 "repository" => @repository,
                 "reference" => "develop"
               })

      assert JSON.decode!(File.read!(Path.join(settings.home, "config.json"))) ==
               %{"port" => 0, "repositories" => sources}

      # A server that goes down is started again and registered again.
      %{server: server} = :sys.get_state(Core)

      capture_log(fn ->
        Process.exit(server, :kill)

        assert wait_for(fn ->
                 registered() && :sys.get_state(Core).server not in [nil, server]
               end)
      end)

      assert registered()
      stop_supervised!(Core)
      refute File.exists?(Path.join(settings.home, "service.owner"))
      assert_raise RuntimeError, ~r/No Code instance/, fn -> AtlasCode.settings() end
    end

    test "generates runtime.token once, 0600 and owner-only home, and keeps it", %{
      tmp_dir: dir,
      url: url
    } do
      home = Path.join(dir, "code-home")
      start_supervised!({Core, %{"home" => home, "repositories" => %{@repository => url}}})
      assert wait_for(fn -> registered() end)
      token = Path.join(home, "runtime.token")

      assert %File.Stat{type: :regular, mode: mode} = File.lstat!(token)
      assert Bitwise.band(mode, 0o777) == 0o600
      assert Bitwise.band(File.stat!(home).mode, 0o777) == 0o700
      assert File.read!(token) =~ ~r/\A[0-9a-f]{64}\n\z/
      first = File.read!(token)

      stop_supervised!(Core)
      start_supervised!({Core, %{"home" => home, "repositories" => %{@repository => url}}})
      assert wait_for(fn -> registered() end)
      assert File.read!(token) == first
      stop_supervised!(Core)
    end
  end

  # -- helpers

  defp registered do
    AtlasCode.settings()
  rescue
    RuntimeError -> nil
  end

  defp ok({:ok, _} = ok), do: ok
  defp ok(_), do: nil

  defp wait_for(fun, tries \\ 100) do
    case fun.() do
      falsy when falsy in [nil, false] and tries > 0 ->
        Process.sleep(50)
        wait_for(fun, tries - 1)

      result ->
        result
    end
  end

  defp home(dir, repositories) do
    home = Path.join(dir, "home-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)

    File.write!(
      Path.join(home, "config.json"),
      JSON.encode!(%{"port" => 0, "repositories" => repositories})
    )

    token = Path.join(home, "runtime.token")
    File.write!(token, "token\n")
    File.chmod!(token, 0o600)
    home
  end

  defp owner(home), do: JSON.decode!(File.read!(Path.join([home, "service.owner", "owner.json"])))

  # An owner directory left behind by `os_pid`, written with the OS lock or (nil) before it.
  defp owner_record(home, os_pid, lock) do
    owner = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    staging = Path.join(home, "stale.tmp")
    File.mkdir!(staging)

    record =
      %{
        "kind" => "service",
        "node" => "nonode@nohost",
        "os_pid" => os_pid,
        "owner" => owner,
        "started_at" => "2026-11-09T00:00:00Z"
      }
      |> then(&if(lock, do: Map.put(&1, "lock", lock), else: &1))

    File.write!(Path.join(staging, "owner.json"), JSON.encode!(record))
    File.rename!(staging, Path.join(home, "service.owner"))
    owner
  end

  # A ps that answers from the kernel (`kill -0`), as `ps -p PID -o pid=` would.
  defp liveness_ps(dir) do
    file = Path.join(dir, "ps-live")

    File.write!(file, """
    #!/bin/sh
    if [ "$2" = "#{System.pid()}" ] || [ "$2" = 1 ]; then echo "  $2"; exit 0; fi
    if kill -0 "$2" 2>/dev/null; then echo "  $2"; exit 0; fi
    exit 1
    """)

    File.chmod!(file, 0o755)
    file
  end

  defp always_absent(dir) do
    file = Path.join(dir, "ps-absent")

    File.write!(
      file,
      "#!/bin/sh\nif [ \"$2\" = \"#{System.pid()}\" ] || [ \"$2\" = 1 ]; then echo \"  $2\"; exit 0; fi\nexit 1\n"
    )

    File.chmod!(file, 0o755)
    file
  end

  # A second BEAM that takes the lock, says so, and on `go` SIGKILLs itself (within 15 s).
  defp beam_taking_lock(home) do
    paths = [:code.which(Lock), :code.which(System)] |> Enum.map(&Path.dirname(to_string(&1)))
    locked = Path.join(home, "locked")
    go = Path.join(home, "go")

    eval = """
    {ok, _} = 'Elixir.AtlasCode.Lock':acquire(<<"#{home}">>),
    ok = file:write_file("#{locked}", <<>>),
    W = fun Wait(0) -> ok; Wait(N) -> case filelib:is_file("#{go}") of true -> ok; false -> timer:sleep(20), Wait(N - 1) end end,
    W(750),
    os:cmd("kill -9 " ++ os:getpid()).
    """

    Port.open({:spawn_executable, System.find_executable("erl")}, [
      :exit_status,
      args: ["-noshell", "-pa" | paths] ++ ["-eval", eval]
    ])
  end

  # A git on PATH that records each call's argv (one per line, arguments NUL-separated) and
  # runs the real one.
  defp git_recorder(dir) do
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)
    log = Path.join(dir, "git-calls")
    real = System.find_executable("git")

    File.write!(Path.join(bin, "git"), """
    #!/bin/sh
    for arg in "$@"; do printf '%s\\0' "$arg"; done >> "#{log}"
    printf '\\n' >> "#{log}"
    exec "#{real}" "$@"
    """)

    File.chmod!(Path.join(bin, "git"), 0o755)
    path = System.get_env("PATH")
    System.put_env("PATH", bin <> ":" <> path)
    on_exit(fn -> System.put_env("PATH", path) end)
    log
  end

  defp calls(log) do
    for line <- log |> File.read!() |> String.split("\n", trim: true),
        do: String.split(line, <<0>>, trim: true)
  end

  defp helpers(argv), do: Enum.filter(argv, &String.starts_with?(&1, "credential.helper"))

  defp work_source(dir),
    do: %{"credentials_env" => "ATLAS_TEST_RUNTIMES", "results" => Path.join(dir, "results")}

  defp runtime_config(dir, code, extra \\ %{}) do
    file = Path.join(dir, "settings.json")

    settings =
      %{
        "env" => "test",
        "control" => %{"host" => "127.0.0.1", "port" => 1},
        "rela" => %{"url" => "http://127.0.0.1:1"},
        "facts" => %{"data" => Path.join(dir, "facts")}
      }
      |> then(&if(code, do: Map.put(&1, "code", code), else: &1))
      |> Map.merge(extra)

    File.write!(file, JSON.encode!(settings))
    read_runtime("test", file)
  end

  # runtime.exs for an environment and its settings file. The bus link token is a dummy,
  # only so that a file with `bus_link` (prod) evaluates.
  defp read_runtime(env, file) do
    variables = [
      {"ATLAS_ENV", env},
      {"ATLAS_ENV_FILE", file},
      {"ATLAS_BUS_LINK_TOKEN", "{}"}
    ]

    prior = Map.new(variables, fn {key, _} -> {key, System.get_env(key)} end)

    try do
      System.put_env(variables)
      Config.Reader.read!(@runtime_exs, env: :dev)
    after
      for {key, value} <- prior do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end
    end
  end

  defp git(dir, args) do
    {output, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    output
  end
end
