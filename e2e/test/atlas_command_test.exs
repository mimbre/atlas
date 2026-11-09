defmodule AtlasE2E.AtlasCommandTest do
  # What `bin/atlas` (the Control client) and `bin/atlas-ops` (operating) refuse or choose
  # before they start anything: no rela, no core and no prod data is touched here. prod is
  # the default; automation passes --env test or a private ATLAS_ENV_FILE, and a mismatch
  # between the two is refused. Both resolve the environment through bin/lib/env.sh.
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  defp atlas(args, env \\ [], cd \\ @root), do: run("bin/atlas", args, env, cd)
  defp ops(args, env \\ [], cd \\ @root), do: run("bin/atlas-ops", args, env, cd)

  defp run(command, args, env, cd) do
    System.cmd(Path.join(@root, command), args,
      env: [{"ATLAS_ENV_FILE", nil}, {"ATLAS_NO_UPDATE", "1"} | env],
      cd: cd,
      stderr_to_stdout: true
    )
  end

  defp private_file(env) do
    dir = Path.join(System.tmp_dir!(), "atlas-command-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    file = Path.join(dir, "#{env}.json")
    settings = @root |> Path.join("env/test.json") |> File.read!() |> JSON.decode!()
    File.write!(file, JSON.encode!(%{settings | "env" => env}))
    on_exit(fn -> File.rm_rf!(dir) end)
    file
  end

  test "prod is the default; --env test chooses test" do
    assert {"prod " <> file, 0} = ops(["env"])
    assert String.trim(file) == Path.join(real(@root), "env/prod.json")
    assert {"test " <> file, 0} = ops(["env", "--env", "test"])
    assert String.trim(file) == Path.join(real(@root), "env/test.json")
    assert {"test " <> _, 0} = ops(["env", "--env=test"])
  end

  test "a private file is its own environment, and must agree with --env" do
    test_file = private_file("test")
    assert {"test " <> _, 0} = ops(["env"], [{"ATLAS_ENV_FILE", test_file}])

    assert {out, 1} = ops(["env", "--env", "prod"], [{"ATLAS_ENV_FILE", test_file}])
    assert out =~ "is for test, not prod"
    assert {out, 1} = ops(["status", "--env", "prod"], [{"ATLAS_ENV_FILE", test_file}])
    assert out =~ "is for test, not prod"

    # atlas applies the same rule, before it connects to anything.
    assert {out, 1} = atlas(["get", "X", "--env", "prod"], [{"ATLAS_ENV_FILE", test_file}])
    assert out =~ "is for test, not prod"

    prod_file = private_file("prod")
    assert {out, 1} = atlas(["tui", "--env", "test"], [{"ATLAS_ENV_FILE", prod_file}])
    assert out =~ "is for prod, not test"
  end

  test "an unknown or empty environment is refused" do
    for {run, command} <- [{&ops/1, ["env"]}, {&ops/1, ["status"]}, {&atlas/1, ["get", "X"]}] do
      assert {out, 1} = run.(command ++ ["--env", "staging"])
      assert out =~ "no environment 'staging'"
      assert {out, 2} = run.(command ++ ["--env"])
      assert out =~ "--env needs test or prod"
      assert {_, 2} = run.(command ++ ["--env="])
    end
  end

  test "exact fact reads reach the environment guard before connecting" do
    assert {out, 1} =
             atlas(["facts", "_", "W-1", "--env", "prod"], [
               {"ATLAS_ENV_FILE", private_file("test")}
             ])

    assert out =~ "is for test, not prod"
  end

  test "the TUI rejects surface selectors without reserving generic entity properties" do
    for value <- ["console", "legacy", "unknown"],
        args <- [["--surface", value], ["--surface=#{value}"]],
        command <- [[], ["tui"]] do
      assert {out, 2} = atlas(command ++ args)
      assert out =~ "unknown option --surface"
    end

    # Stop at the environment guard, before connecting or creating anything.
    assert {out, 1} =
             atlas(
               ["put", "widget", "--surface", "dark", "--env", "prod"],
               [{"ATLAS_ENV_FILE", private_file("test")}]
             )

    assert out =~ "is for test, not prod"
  end

  defp atlas_dev(args) do
    System.cmd(Path.join(@root, "bin/atlas-dev"), args,
      env: [{"ATLAS_ENV_FILE", nil}],
      cd: @root,
      stderr_to_stdout: true
    )
  end

  test "the end-to-end test refuses prod" do
    assert {out, 1} = atlas_dev(["e2e", "--env", "prod"])
    assert out =~ "never on prod"
    assert {out, 1} = atlas_dev(["e2e", "uc-atlas-01", "--env=prod"])
    assert out =~ "never on prod"
    assert {out, 2} = atlas_dev(["e2e", "--env"])
    assert out =~ "--env needs test or prod"
  end

  test "the end-to-end test is development tooling, not an atlas command" do
    for args <- [["e2e"], ["e2e", "--env", "test"], ["e2e", "uc-atlas-01", "--env", "test"]] do
      assert {out, 2} = atlas(args)
      assert out =~ "atlas help [<kind>]", "atlas #{Enum.join(args, " ")}: #{out}"
      refute out =~ "e2e"
    end

    assert {out, 2} = atlas_dev([])
    assert out =~ "bin/atlas-dev e2e"
    assert {_, 2} = atlas_dev(["tui"])
  end

  @tag :requires_git
  test "atlas-ops works from any folder: from /, and from inside another repository" do
    {common, 0} =
      System.cmd("git", ["-C", @root, "rev-parse", "--path-format=absolute", "--git-common-dir"])

    main = common |> String.trim() |> Path.dirname() |> real()

    other = Path.join(System.tmp_dir!(), "atlas-other-repo-#{System.unique_integer([:positive])}")
    File.mkdir_p!(other)
    on_exit(fn -> File.rm_rf!(other) end)
    {_, 0} = System.cmd("git", ["init", "-q", other])

    for cd <- ["/", other] do
      assert {out, 0} = ops(["main-clone"], [], cd)
      assert String.trim(out) == main, "atlas-ops main-clone from #{cd}: #{out}"
      assert {out, 0} = ops(["where"], [], cd)
      assert String.trim(out) == real(@root), "atlas-ops where from #{cd}: #{out}"
      assert {"prod " <> file, 0} = ops(["env"], [], cd)
      assert String.trim(file) == Path.join(real(@root), "env/prod.json")
    end
  end

  # The physical path, as `pwd -P` gives it (macOS's /tmp and /var are links).
  defp real(path) do
    {out, 0} = System.cmd("pwd", ["-P"], cd: path)
    String.trim(out)
  end

  test "test and prod share no port and no data, and neither is the live store" do
    [test, prod] =
      for env <- ["test", "prod"],
          do: @root |> Path.join("env/#{env}.json") |> File.read!() |> JSON.decode!()

    assert {test["env"], prod["env"]} == {"test", "prod"}

    # Both run on Fly (IS-Atlas-26, IS-Atlas-79), each its own pair of apps: this Mac has
    # only the clients' files.
    assert test["fly"]["app"] == "eyra-atlas-test"
    assert prod["fly"]["app"] == "eyra-atlas"
    refute test["fly"]["rela_app"] == prod["fly"]["rela_app"]

    for settings <- [test, prod] do
      refute Map.has_key?(settings, "rela")
      refute Map.has_key?(settings, "facts")
    end

    hosts = [test["control"]["host_env"], prod["control"]["host_env"]]
    assert Enum.uniq(hosts) == hosts
    ports = [test["control"]["port"], prod["control"]["port"]]
    assert Enum.uniq(ports) == ports
    refute test["fly"]["local"] == prod["fly"]["local"]
    refute test["fly"]["local"] =~ "/atlas/prod"
  end

  # A copy of env/test.json whose clients' files go to a folder of its own.
  defp fly_file do
    dir = Path.join(System.tmp_dir!(), "atlas-fly-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    settings = @root |> Path.join("env/test.json") |> File.read!() |> JSON.decode!()
    file = Path.join(dir, "test.json")
    settings = put_in(settings, ["fly", "local"], dir)

    settings =
      Map.put(settings, "control", %{
        "host" => "test.security-fixture.ts.net",
        "port" => 7691,
        "tls" => %{}
      })

    File.write!(file, JSON.encode!(settings))
    on_exit(fn -> File.rm_rf!(dir) end)
    file
  end

  # A private test file of an environment that runs on this Mac.
  defp local_file do
    dir = Path.join(System.tmp_dir!(), "atlas-local-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    file = Path.join(dir, "test.json")

    settings = %{
      "env" => "test",
      # Who decides what a person decides (the model names only the role).
      "actors" => %{"decider" => "melle"},
      "control" => %{"host" => "127.0.0.1", "port" => 1},
      "rela" => %{
        "url" => "http://127.0.0.1:2/api/v1",
        "port" => 2,
        "data" => Path.join(dir, "rela"),
        "bin" => Path.join(dir, "bin")
      },
      "facts" => %{"data" => Path.join(dir, "beam")}
    }

    File.write!(file, JSON.encode!(settings))
    on_exit(fn -> File.rm_rf!(dir) end)
    file
  end

  test "an environment on Fly runs no core and no rela here, and takes no migration" do
    on_fly = [{"ATLAS_ENV_FILE", fly_file()}]

    assert {out, 1} = ops(["up", "--env", "test"], on_fly)
    assert out =~ "runs on Fly (eyra-atlas-test and eyra-atlas-test-rela)"
    assert out =~ "no core to run here"

    for args <- [["stop"], ["stop", "--rela"], ["restart"]] do
      assert {out, 1} = ops(args ++ ["--env", "test"], on_fly)
      assert out =~ "a merge to develop deploys it", "atlas-ops #{Enum.join(args, " ")}: #{out}"
    end

    assert {out, 1} = atlas(["migrate-done-owner", "--dry-run", "--env", "test"], on_fly)
    assert out =~ "the migration reads rela on this Mac"
  end

  # On Fly, Control is on the tailnet (D-0089): the Fly app's MagicDNS name, and the port its
  # core listens on (fly/<env>/core.json). What bin/lib/env.sh resolves, as atlas uses it.
  test "on Fly, the clients' Control is the core app's tailnet name and its own port" do
    for env <- ["test", "prod"] do
      settings = @root |> Path.join("env/#{env}.json") |> File.read!() |> JSON.decode!()
      core = @root |> Path.join("fly/#{env}/core.json") |> File.read!() |> JSON.decode!()
      refute Map.has_key?(settings["fly"], "control_port")

      script =
        ~s(prog=test root="$1" env="$2"; . "$root/bin/lib/env.sh"; resolve_env; resolve_places; echo "$fly_app $host $port")

      assert {out, 0} =
               System.cmd("bash", ["-c", script, "resolve", @root, env],
                 env: [
                   {"ATLAS_ENV_FILE", nil},
                   {"ATLAS_CONTROL_TEST_HOST", "test.security-fixture.ts.net"},
                   {"ATLAS_CONTROL_PROD_HOST", "prod.security-fixture.ts.net"}
                 ],
                 stderr_to_stdout: true
               )

      app = settings["fly"]["app"]

      assert out == "#{app} #{env}.security-fixture.ts.net #{core["control"]["port"]}\n",
             "#{env}: #{out}"
    end
  end

  # Stand-ins on PATH: nc answers with status nc_status; fly, flyctl and mix answer nothing.
  # Every call is noted, so a test sees what was reached, and that nothing else ran.
  defp fake_tools(nc_status) do
    dir = Path.join(System.tmp_dir!(), "atlas-fake-tools-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    calls = Path.join(dir, "calls")

    for {name, status} <- [{"nc", nc_status}, {"fly", 0}, {"flyctl", 0}, {"mix", 99}] do
      file = Path.join(dir, name)
      File.write!(file, "#!/bin/sh\necho \"#{name} $*\" >> '#{calls}'\nexit #{status}\n")
      File.chmod!(file, 0o755)
    end

    on_exit(fn -> File.rm_rf!(dir) end)
    {[{"ATLAS_ENV_FILE", fly_file()}, {"PATH", dir <> ":" <> System.get_env("PATH")}], calls}
  end

  test "off the tailnet, a command that needs Control says so, and opens or builds nothing" do
    for args <- [["list", "scene"], ["get", "X"], ["help"], ["tui"], []] do
      {env, calls} = fake_tools(1)
      assert {out, 1} = atlas(args ++ ["--env", "test"], env), "atlas #{Enum.join(args, " ")}"
      assert out =~ "test.security-fixture.ts.net:7691"
      assert File.read!(calls) == "nc -z -w 3 test.security-fixture.ts.net 7691\n"
    end
  end

  test "atlas-ops status says whether Control answers over the tailnet" do
    control = fn out ->
      out |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "control:"))
    end

    {env, calls} = fake_tools(0)
    assert {out, 0} = ops(["status", "--env", "test"], env)
    assert [answers] = control.(out)
    assert answers =~ "test.security-fixture.ts.net:7691"
    assert File.read!(calls) =~ "nc -z -w 3 test.security-fixture.ts.net 7691\n"
    assert File.read!(calls) =~ "fly status -a eyra-atlas-test\n"

    {env, calls} = fake_tools(1)
    assert {out, 0} = ops(["status", "--env", "test"], env)
    assert [silent] = control.(out)
    assert silent =~ "test.security-fixture.ts.net:7691"
    assert silent != answers
    assert File.read!(calls) =~ "nc -z -w 3 test.security-fixture.ts.net 7691\n"
  end

  test "on an environment on this Mac, atlas starts nothing: without Control, the TUI says how" do
    file = local_file()
    assert {out, 2} = atlas(["tui", "--env", "test"], [{"ATLAS_ENV_FILE", file}])
    assert out =~ "Control for test does not answer: atlas-ops restart --env test"
    refute File.exists?(Path.join(Path.dirname(file), "rela-server.pid"))
    refute File.exists?(Path.join(Path.dirname(file), "core.pid"))
  end

  test "removed commands are unknown: they show the usage, exit 2 and run nothing" do
    on_fly = [{"ATLAS_ENV_FILE", fly_file()}]

    for args <- [
          ["migrate-completion"],
          ["migrate-owner", "--dry-run"],
          ["migrate-assignment", "--dry-run"],
          ["load-plan", "SCENES.md", "links.json"],
          ["playground", "init", "/nonexistent"],
          ["attach", "breaker", "--prototype", "/nonexistent"],
          # Operating is atlas-ops.
          ["status"],
          ["logs"],
          ["stop"],
          ["restart"],
          ["up"],
          ["rela-status"],
          ["rela-stop"],
          ["move-to-fly", "--dry-run"],
          ["fetch-from-fly", "--to", "/nonexistent"],
          ["env"],
          ["where"],
          ["main-clone"],
          ["install"]
        ] do
      assert {out, 2} = atlas(args ++ ["--env", "test"], on_fly), "atlas #{Enum.join(args, " ")}"
      assert out =~ "atlas: try Atlas from any folder."
      assert out =~ "atlas-ops --help"
      refute out =~ "migrations read rela"
      refute out =~ "does not answer at"
      refute out =~ "closed this"
    end

    # atlas-ops takes no Control client word, and has no aliases for the old ones.
    for word <- ["tui", "get", "rela-stop", "rela-status", "e2e", "tunnel"] do
      assert {out, 2} = ops([word, "--env", "test"], on_fly), "atlas-ops #{word}"
      assert out =~ "atlas-ops: operate an Atlas environment"
    end
  end

  test "move-to-fly is only for an environment on Fly, and needs data to move" do
    local = [{"ATLAS_ENV_FILE", local_file()}]
    assert {out, 1} = ops(["move-to-fly", "--dry-run", "--env", "test"], local)
    assert out =~ "does not run on Fly"

    empty = Path.join(System.tmp_dir!(), "atlas-move-#{System.unique_integer([:positive])}")
    File.mkdir_p!(empty)
    on_exit(fn -> File.rm_rf!(empty) end)

    on_fly = [{"ATLAS_ENV_FILE", fly_file()}]

    assert {out, 1} =
             ops(["move-to-fly", "--from", empty, "--dry-run", "--env", "test"], on_fly)

    assert out =~ "has no rela data"
  end

  test "prod's clients use Fly; a move takes the folder the Mac kept prod's data in" do
    prod = @root |> Path.join("env/prod.json") |> File.read!() |> JSON.decode!()

    assert %{"app" => "eyra-atlas", "rela_app" => "eyra-atlas-rela", "in_use" => true} =
             prod["fly"]

    assert prod["fly"]["move_from"] =~ "/atlas/prod"
    refute prod["fly"]["local"] == prod["fly"]["move_from"]
  end

  # A copy of env/prod.json on ports and folders of its own, so nothing reaches prod.
  defp prod_file(in_use) do
    dir = Path.join(System.tmp_dir!(), "atlas-prod-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    settings = @root |> Path.join("env/prod.json") |> File.read!() |> JSON.decode!()

    settings =
      settings
      |> put_in(["fly", "in_use"], in_use)
      |> put_in(["fly", "local"], Path.join(dir, "on-fly"))
      |> put_in(["control", "port"], 3)
      |> Map.put("rela", %{
        "url" => "http://127.0.0.1:4/api/v1",
        "port" => 4,
        "data" => Path.join(dir, "rela"),
        "bin" => Path.join(dir, "bin")
      })

    file = Path.join(dir, "prod.json")
    File.write!(file, JSON.encode!(settings))
    on_exit(fn -> File.rm_rf!(dir) end)
    file
  end

  test "until \"in_use\" is true, prod's core runs on this Mac; then on Fly" do
    assert {out, 0} = ops(["stop", "--env", "prod"], [{"ATLAS_ENV_FILE", prod_file(false)}])
    assert out =~ "core stopped (rela keeps running)"

    on_fly = [{"ATLAS_ENV_FILE", prod_file(true)}]
    assert {out, 1} = ops(["stop", "--env", "prod"], on_fly)
    assert out =~ "a merge to master deploys it"
  end

  @tag :requires_git
  test "install links atlas and atlas-ops, never atlas-dev, and only from the main clone" do
    home = Path.join(System.tmp_dir!(), "atlas-home-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    on_exit(fn -> File.rm_rf!(home) end)

    {common, 0} =
      System.cmd("git", ["-C", @root, "rev-parse", "--path-format=absolute", "--git-common-dir"])

    main = common |> String.trim() |> Path.dirname() |> real()
    {out, status} = ops(["install"], [{"HOME", home}])

    if main == real(@root) do
      assert status == 0, out
      bin = Path.join(home, ".local/bin")
      assert {:ok, target} = File.read_link(Path.join(bin, "atlas"))
      assert target == Path.join(real(@root), "bin/atlas")
      assert {:ok, target} = File.read_link(Path.join(bin, "atlas-ops"))
      assert target == Path.join(real(@root), "bin/atlas-ops")
      refute File.exists?(Path.join(bin, "atlas-dev"))

      # Through the link, atlas-ops still finds its checkout and bin/lib.
      assert {"test " <> _, 0} =
               System.cmd(Path.join(bin, "atlas-ops"), ["env", "--env", "test"],
                 env: [{"ATLAS_ENV_FILE", nil}],
                 cd: "/",
                 stderr_to_stdout: true
               )
    else
      assert status == 1, out
      assert out =~ "install from the main clone"
      refute File.exists?(Path.join(home, ".local/bin"))
    end
  end

  test "moving onto the data clients use on Fly needs --replace-live" do
    on_fly = [{"ATLAS_ENV_FILE", fly_file()}]
    assert {out, 1} = ops(["move-to-fly", "--from", "/", "--env", "test"], on_fly)
    assert out =~ "its data there is the live one"
    assert out =~ "add --replace-live"
  end

  test "fetch-from-fly needs a folder, and an environment on Fly" do
    on_fly = [{"ATLAS_ENV_FILE", fly_file()}]
    assert {out, 1} = ops(["fetch-from-fly", "--env", "test"], on_fly)
    assert out =~ "--to <folder>"
    assert {out, 1} = ops(["fetch-from-fly", "--to", "/", "--env", "test"], on_fly)
    assert out =~ "is not empty"

    local = [{"ATLAS_ENV_FILE", local_file()}]
    assert {out, 1} = ops(["fetch-from-fly", "--to", "/tmp/x", "--env", "test"], local)
    assert out =~ "does not run on Fly"
  end

  # Fly's command line, as fetch-from-fly finds it on PATH: here a stand-in that notes each
  # call and fails it, except the check for a hold or a pending move: for app A it prints the
  # file A.check of its folder, when the test wrote one.
  defp fake_fly do
    dir = Path.join(System.tmp_dir!(), "atlas-fake-fly-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    calls = Path.join(dir, "calls")
    fly = Path.join(dir, "fly")

    File.write!(fly, """
    #!/bin/sh
    echo "$*" >> '#{calls}'
    app=""; previous=""
    for arg in "$@"; do [ "$previous" = -a ] && app="$arg"; previous="$arg"; done
    case "$*" in
      *"echo checked"*) [ -f "#{dir}/$app.check" ] && exec cat "#{dir}/$app.check" ;;
    esac
    exit 1
    """)

    File.chmod!(fly, 0o755)
    on_exit(fn -> File.rm_rf!(dir) end)
    {dir, calls}
  end

  defp calls(file), do: if(File.exists?(file), do: File.read!(file), else: "")

  test "fetch-from-fly refuses a wrong call before it reaches Fly or makes its folder" do
    {fly_dir, calls} = fake_fly()
    env = [{"ATLAS_ENV_FILE", fly_file()}, {"PATH", fly_dir <> ":" <> System.get_env("PATH")}]
    to = Path.join(fly_dir, "backup")

    for args <- [["--to", to, "--keep"], ["--to"]] do
      assert {_, 2} = ops(["fetch-from-fly" | args] ++ ["--env", "test"], env),
             "fetch-from-fly #{Enum.join(args, " ")}"
    end

    refute File.exists?(calls)
    refute File.exists?(to)
  end

  # A restart would end a hold already there (a migration's) or apply a pending move, so
  # either one on either app stops the backup before it holds anything.
  test "fetch-from-fly refuses, before any hold, an app already held or with a pending move" do
    file = fly_file()

    %{"app" => core, "rela_app" => rela} =
      file |> File.read!() |> JSON.decode!() |> Map.get("fly")

    clean = "checked\n"

    for {core_check, rela_check, refused?} <- [
          {"/data/hold\nchecked\n", clean, true},
          {clean, "/data/incoming/rela.tar.gz\nchecked\n", true},
          {"/data/incoming/beam.tar.gz\n", clean, true},
          {nil, clean, true},
          {clean, clean, false}
        ] do
      {fly_dir, calls} = fake_fly()

      for {app, check} <- [{core, core_check}, {rela, rela_check}],
          check,
          do: File.write!(Path.join(fly_dir, "#{app}.check"), check)

      env = [{"ATLAS_ENV_FILE", file}, {"PATH", fly_dir <> ":" <> System.get_env("PATH")}]
      to = Path.join(fly_dir, "backup")
      assert {out, status} = ops(["fetch-from-fly", "--to", to, "--env", "test"], env)
      assert status != 0, out
      held? = calls(calls) =~ "touch /data/hold"
      assert held? == not refused?, "#{inspect({core_check, rela_check})}: #{calls(calls)}"
      refute calls(calls) =~ "restart"
      refute File.exists?(to)
    end
  end

  test "fetch-from-fly without Fly's command line refuses and makes no folder" do
    for dir <- ["/usr/bin", "/bin"],
        name <- ["fly", "flyctl"],
        do: refute(File.exists?(Path.join(dir, name)), "#{dir}/#{name} would be real Fly")

    {dir, _calls} = fake_fly()
    to = Path.join(dir, "backup")
    env = [{"ATLAS_ENV_FILE", fly_file()}, {"PATH", "/usr/bin:/bin"}]
    assert {_, 1} = ops(["fetch-from-fly", "--to", to, "--env", "test"], env)
    refute File.exists?(to)
  end
end
