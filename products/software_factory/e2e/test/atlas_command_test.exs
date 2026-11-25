defmodule AtlasE2E.AtlasCommandTest do
  # What `bin/atlas` (the Control client) and `bin/atlas-ops` (operating) refuse or choose
  # before they start anything: no rela, no core and no prod data is touched here. prod is
  # the default; automation passes --env test or a private ATLAS_ENV_FILE, and a mismatch
  # between the two is refused. Both resolve the environment through bin/lib/env.sh.
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)

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

    settings =
      @root
      |> Path.join("products/software_factory/environments/test.json")
      |> File.read!()
      |> JSON.decode!()

    File.write!(file, JSON.encode!(%{settings | "env" => env}))
    on_exit(fn -> File.rm_rf!(dir) end)
    file
  end

  test "prod is the default; --env test chooses test" do
    assert {"prod " <> file, 0} = ops(["env"])

    assert String.trim(file) ==
             Path.join(real(@root), "products/software_factory/environments/prod.json")

    assert {"test " <> file, 0} = ops(["env", "--env", "test"])

    assert String.trim(file) ==
             Path.join(real(@root), "products/software_factory/environments/test.json")

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

      assert String.trim(file) ==
               Path.join(real(@root), "products/software_factory/environments/prod.json")
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
          do:
            @root
            |> Path.join("products/software_factory/environments/#{env}.json")
            |> File.read!()
            |> JSON.decode!()

    assert {test["env"], prod["env"]} == {"test", "prod"}

    # Both run on Fly (IS-Atlas-26, IS-Atlas-79), each its own pair of apps: this Mac has
    # only the tunnels' ends and their files.
    assert test["fly"]["app"] == "eyra-atlas-test"
    assert prod["fly"]["app"] == "eyra-atlas"
    refute test["fly"]["rela_app"] == prod["fly"]["rela_app"]

    for settings <- [test, prod] do
      refute Map.has_key?(settings, "rela")
      refute Map.has_key?(settings, "facts")
    end

    ports = [test["control"]["port"], prod["control"]["port"]]
    assert Enum.uniq(ports) == ports
    refute 7612 in ports
    # Not the ports the Mac's own cores used, which may still be listening.
    refute Enum.any?(ports, &(&1 in [7590, 7591, 7690, 7691]))
    refute test["fly"]["local"] == prod["fly"]["local"]
    refute test["fly"]["local"] =~ "/atlas/prod"
  end

  # A copy of products/software_factory/environments/test.json whose tunnel files go to a folder of its own.
  defp fly_file do
    dir = Path.join(System.tmp_dir!(), "atlas-fly-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    settings =
      @root
      |> Path.join("products/software_factory/environments/test.json")
      |> File.read!()
      |> JSON.decode!()

    file = Path.join(dir, "test.json")
    File.write!(file, JSON.encode!(put_in(settings, ["fly", "local"], dir)))
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
      assert out =~ "atlas-ops tunnel close --env test"
    end

    assert {out, 1} = atlas(["migrate-done-owner", "--dry-run", "--env", "test"], on_fly)
    assert out =~ "the migration reads rela on this Mac"
  end

  test "the tunnel on Fly is shown and closed by atlas-ops; a local environment has none" do
    on_fly = [{"ATLAS_ENV_FILE", fly_file()}]
    assert {out, 0} = ops(["tunnel", "status", "--env", "test"], on_fly)
    assert out =~ "tunnel: closed"
    assert {out, 0} = ops(["tunnel", "close", "--env", "test"], on_fly)
    assert out =~ "closed this machine's tunnel to eyra-atlas-test"
    assert {_, 2} = ops(["tunnel", "--env", "test"], on_fly)
    assert {_, 2} = ops(["tunnel", "open", "--env", "test"], on_fly)

    local = [{"ATLAS_ENV_FILE", local_file()}]
    assert {out, 1} = ops(["tunnel", "status", "--env", "test"], local)
    assert out =~ "does not run on Fly"
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
      refute out =~ "opening the tunnel"
      refute out =~ "closed this"
    end

    # atlas-ops takes no Control client word, and has no aliases for the old ones.
    for word <- ["tui", "get", "rela-stop", "rela-status", "e2e"] do
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
    prod =
      @root
      |> Path.join("products/software_factory/environments/prod.json")
      |> File.read!()
      |> JSON.decode!()

    assert %{"app" => "eyra-atlas", "rela_app" => "eyra-atlas-rela", "in_use" => true} =
             prod["fly"]

    assert prod["fly"]["move_from"] =~ "/atlas/prod"
    refute prod["fly"]["local"] == prod["fly"]["move_from"]
  end

  # A copy of products/software_factory/environments/prod.json on ports and folders of its own, so nothing reaches prod.
  defp prod_file(in_use) do
    dir = Path.join(System.tmp_dir!(), "atlas-prod-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    settings =
      @root
      |> Path.join("products/software_factory/environments/prod.json")
      |> File.read!()
      |> JSON.decode!()

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
    assert {out, 0} = ops(["tunnel", "close", "--env", "prod"], on_fly)
    assert out =~ "closed this machine's tunnel to eyra-atlas"
  end

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

  # IS-Atlas-56, IS-Atlas-57, IS-Atlas-65: an agent a Runtime starts (ATLAS_AGENT_ENV,
  # ATLAS_AS) reaches Control on its machine's route only. atlas opens no tunnel for it and
  # writes nothing outside the checkout: no tunnel pid or log in the environment's folder,
  # nothing in the user home. Its failures name the agent and the environment.

  # A Control on a free port of this machine that answers what `atlas get` asks: hello, the
  # agent's own fact, and every page as one item. It sends each hello's `as` to the test.
  defp machine_route do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, packet: :line, active: false, reuseaddr: true])

    {:ok, {_, port}} = :inet.sockname(listener)
    test = self()
    send_line = fn socket, map -> :gen_tcp.send(socket, JSON.encode!(map) <> "\n") end

    page = fn reason, path ->
      %{
        "op" => "page",
        "reason" => reason,
        "markup" => [],
        "path" => path,
        "title" => "Widget WI-01",
        "blocks" => [
          %{
            "id" => "item",
            "type" => "item",
            "props" => %{
              "title" => "Widget WI-01: read by an agent",
              "fields" => [%{"label" => "Title", "value" => "read by an agent"}]
            }
          }
        ]
      }
    end

    serve = fn serve, socket ->
      case :gen_tcp.recv(socket, 0) do
        {:ok, line} ->
          case JSON.decode!(line) do
            %{"op" => "hello"} = hello ->
              send(test, {:hello, hello["as"]})

              send_line.(socket, %{
                "op" => "welcome",
                "env" => hello["env"],
                "spec" => hello["spec"]
              })

              send_line.(socket, page.("open", "/"))

            %{"op" => "facts_read", "key" => "dev2"} ->
              send_line.(socket, %{
                "op" => "facts_read",
                "data" => %{"fact" => %{"key" => "dev2"}}
              })

            %{"op" => "facts_read"} ->
              send_line.(socket, %{"op" => "facts_read", "error" => "unknown kind or subject"})

            %{"op" => "open", "to" => to} ->
              send_line.(socket, page.("open", String.replace(to, "/k/_/", "/k/widget/")))

            _ ->
              :ok
          end

          serve.(serve, socket)

        {:error, _} ->
          :gen_tcp.close(socket)
      end
    end

    accept = fn accept ->
      case :gen_tcp.accept(listener) do
        {:ok, socket} ->
          pid = spawn(fn -> receive(do: (:go -> serve.(serve, socket))) end)
          :ok = :gen_tcp.controlling_process(socket, pid)
          send(pid, :go)
          accept.(accept)

        {:error, _} ->
          :ok
      end
    end

    acceptor = spawn(fn -> receive(do: (:go -> accept.(accept))) end)
    :ok = :gen_tcp.controlling_process(listener, acceptor)
    send(acceptor, :go)
    on_exit(fn -> :gen_tcp.close(listener) end)
    port
  end

  # A Fly environment's file whose control.port is `port`, its tunnel folder empty, and an
  # empty user home: what the agent's commands leave in either shows.
  defp agent_places(port) do
    file = fly_file()
    settings = file |> File.read!() |> JSON.decode!()
    File.write!(file, JSON.encode!(put_in(settings, ["control", "port"], port)))
    home = Path.join(Path.dirname(file), "home")
    File.mkdir_p!(home)
    %{file: file, tunnel: Path.dirname(file), home: home}
  end

  defp tree(dir), do: Path.wildcard(Path.join(dir, "**"), match_dot: true) |> Enum.sort()

  defp as_agent(places, as, extra \\ []) do
    [
      {"ATLAS_ENV_FILE", places.file},
      {"ATLAS_AGENT_ENV", "test"},
      {"ATLAS_AS", as},
      {"HOME", places.home}
      | extra
    ]
  end

  test "an agent's get reaches Control on its machine's route, as itself, and writes nothing outside the checkout" do
    places = agent_places(machine_route())
    tunnel_before = tree(places.tunnel)

    assert {out, 0} = atlas(["get", "WI-01"], as_agent(places, "dev2"))
    assert out =~ "read by an agent"
    assert_received {:hello, "dev2"}

    assert tree(places.home) == []
    assert tree(places.tunnel) == tunnel_before
    refute File.exists?(Path.join(places.tunnel, "tunnel.pid"))
    refute File.exists?(Path.join(places.tunnel, "tunnel.log"))
  end

  test "an agent with a wrong identity fails naming it and the environment, and does nothing" do
    places = agent_places(machine_route())

    for args <- [["get", "WI-01"], ["actions", "WI-01"], ["do", "WI-01", "Update"]] do
      assert {out, 2} = atlas(args, as_agent(places, "ghost"))
      assert out =~ "ATLAS_AS=ghost is no agent Control test knows", out
      assert out =~ "(as ATLAS_AS=ghost, on test)", out
    end

    assert tree(places.home) == []
  end

  test "without its machine's route an agent opens no tunnel; the failure names it and the environment" do
    {:ok, closed} = :gen_tcp.listen(0, [])
    {:ok, {_, port}} = :inet.sockname(closed)
    :gen_tcp.close(closed)
    places = agent_places(port)
    {fly_dir, calls} = fake_fly()
    tunnel_before = tree(places.tunnel)
    path = [{"PATH", fly_dir <> ":" <> System.get_env("PATH")}]

    assert {out, 2} = atlas(["get", "WI-01"], as_agent(places, "dev2", path))
    assert out =~ "atlas: dev2 on test: Control does not answer on 127.0.0.1:#{port}"
    assert out =~ "an agent opens no tunnel of its own"
    refute File.exists?(calls)
    assert tree(places.tunnel) == tunnel_before
    assert tree(places.home) == []
  end

  test "an agent works for its Runtime's environment and runs the agent commands only" do
    places = agent_places(1)

    assert {out, 2} = atlas(["get", "WI-01", "--env", "prod"], as_agent(places, "dev2"))
    assert out =~ "dev2 works for test (ATLAS_AGENT_ENV, set by its Runtime), not --env prod"

    for command <- [["tui"], ["discover", "--machine", "m"], ["migrate-done-owner", "--dry-run"]] do
      assert {out, 2} = atlas(command, as_agent(places, "dev2"))
      assert out =~ "is not an agent command", inspect(command)
    end
  end

  test "a person's atlas shares a route to Control the machine keeps open, rather than refusing its port" do
    places = agent_places(machine_route())
    {fly_dir, calls} = fake_fly()

    env = [
      {"ATLAS_ENV_FILE", places.file},
      {"ATLAS_AGENT_ENV", nil},
      {"ATLAS_AS", nil},
      {"PATH", fly_dir <> ":" <> System.get_env("PATH")}
    ]

    assert {out, 0} = atlas(["get", "WI-01"], env)
    assert out =~ "read by an agent"
    refute out =~ "is taken by pid"
    refute File.exists?(calls)
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
