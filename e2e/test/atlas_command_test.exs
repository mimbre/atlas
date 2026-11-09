defmodule AtlasE2E.AtlasCommandTest do
  # What `bin/atlas` refuses or chooses before it starts anything: no rela, no core and no
  # prod data is touched here. prod is the default; automation passes --env test or a
  # private ATLAS_ENV_FILE, and a mismatch between the two is refused.
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  defp atlas(args, env \\ [], cd \\ @root) do
    System.cmd(Path.join(@root, "bin/atlas"), args,
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
    assert {"prod " <> file, 0} = atlas(["env"])
    assert String.trim(file) == Path.join(real(@root), "env/prod.json")
    assert {"test " <> file, 0} = atlas(["env", "--env", "test"])
    assert String.trim(file) == Path.join(real(@root), "env/test.json")
  end

  test "a private file is its own environment, and must agree with --env" do
    test_file = private_file("test")
    assert {"test " <> _, 0} = atlas(["env"], [{"ATLAS_ENV_FILE", test_file}])

    assert {out, 1} = atlas(["env", "--env", "prod"], [{"ATLAS_ENV_FILE", test_file}])
    assert out =~ "is for test, not prod"

    prod_file = private_file("prod")
    assert {out, 1} = atlas(["tui", "--env", "test"], [{"ATLAS_ENV_FILE", prod_file}])
    assert out =~ "is for prod, not test"
  end

  test "an unknown or empty environment is refused" do
    assert {out, 1} = atlas(["env", "--env", "staging"])
    assert out =~ "no environment 'staging'"
    assert {out, 2} = atlas(["env", "--env"])
    assert out =~ "--env needs test or prod"
    assert {_, 2} = atlas(["env", "--env="])
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

  test "atlas works from any folder: from /, and from inside another repository" do
    {common, 0} =
      System.cmd("git", ["-C", @root, "rev-parse", "--path-format=absolute", "--git-common-dir"])

    main = common |> String.trim() |> Path.dirname() |> real()

    other = Path.join(System.tmp_dir!(), "atlas-other-repo-#{System.unique_integer([:positive])}")
    File.mkdir_p!(other)
    on_exit(fn -> File.rm_rf!(other) end)
    {_, 0} = System.cmd("git", ["init", "-q", other])

    for cd <- ["/", other] do
      assert {out, 0} = atlas(["main-clone"], [], cd)
      assert String.trim(out) == main, "atlas main-clone from #{cd}: #{out}"
      assert {out, 0} = atlas(["where"], [], cd)
      assert String.trim(out) == real(@root), "atlas where from #{cd}: #{out}"
      assert {"prod " <> file, 0} = atlas(["env"], [], cd)
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
    # only the tunnels' ends and their files.
    assert test["fly"]["app"] == "eyra-atlas-test"
    assert prod["fly"]["app"] == "eyra-atlas"
    refute test["fly"]["rela_app"] == prod["fly"]["rela_app"]

    for settings <- [test, prod] do
      refute Map.has_key?(settings, "rela")
      refute Map.has_key?(settings, "state")
    end

    ports = [test["control"]["port"], prod["control"]["port"]]
    assert Enum.uniq(ports) == ports
    refute 7612 in ports
    # Not the ports the Mac's own cores used, which may still be listening.
    refute Enum.any?(ports, &(&1 in [7590, 7591, 7690, 7691]))
    refute test["fly"]["local"] == prod["fly"]["local"]
    refute test["fly"]["local"] =~ "/atlas/prod"
  end

  # A copy of env/test.json whose tunnel files go to a folder of its own.
  defp fly_file do
    dir = Path.join(System.tmp_dir!(), "atlas-fly-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    settings = @root |> Path.join("env/test.json") |> File.read!() |> JSON.decode!()
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
      "control" => %{"host" => "127.0.0.1", "port" => 1},
      "rela" => %{
        "url" => "http://127.0.0.1:2/api/v1",
        "port" => 2,
        "data" => Path.join(dir, "rela"),
        "bin" => Path.join(dir, "bin")
      },
      "state" => %{"data" => Path.join(dir, "beam")}
    }

    File.write!(file, JSON.encode!(settings))
    on_exit(fn -> File.rm_rf!(dir) end)
    file
  end

  test "an environment on Fly runs no core and no rela here, and takes no migration" do
    on_fly = [{"ATLAS_ENV_FILE", fly_file()}]

    assert {out, 1} = atlas(["up", "--env", "test"], on_fly)
    assert out =~ "runs on Fly (eyra-atlas-test and eyra-atlas-test-rela)"
    assert out =~ "no core to run here"
    assert {out, 1} = atlas(["rela-stop", "--env", "test"], on_fly)
    assert out =~ "rela keeps running there"
    assert {out, 1} = atlas(["migrate-done-owner", "--dry-run", "--env", "test"], on_fly)
    assert out =~ "the migration reads rela on this Mac"
    assert {out, 0} = atlas(["stop", "--env", "test"], on_fly)
    assert out =~ "closed this Mac's tunnel"
  end

  test "removed commands are unknown: they show the usage, exit 2 and run nothing" do
    on_fly = [{"ATLAS_ENV_FILE", fly_file()}]

    for args <- [
          ["migrate-completion"],
          ["migrate-owner", "--dry-run"],
          ["migrate-assignment", "--dry-run"],
          ["load-plan", "SCENES.md", "links.json"],
          ["playground", "init", "/nonexistent"],
          ["attach", "breaker", "--prototype", "/nonexistent"]
        ] do
      assert {out, 2} = atlas(args ++ ["--env", "test"], on_fly), "atlas #{Enum.join(args, " ")}"
      assert out =~ "atlas: try Atlas from any folder."
      refute out =~ "migrations read rela"
      refute out =~ "opening the tunnel"
    end
  end

  test "move-to-fly is only for an environment on Fly, and needs data to move" do
    local = [{"ATLAS_ENV_FILE", local_file()}]
    assert {out, 1} = atlas(["move-to-fly", "--dry-run", "--env", "test"], local)
    assert out =~ "does not run on Fly"

    empty = Path.join(System.tmp_dir!(), "atlas-move-#{System.unique_integer([:positive])}")
    File.mkdir_p!(empty)
    on_exit(fn -> File.rm_rf!(empty) end)

    on_fly = [{"ATLAS_ENV_FILE", fly_file()}]

    assert {out, 1} =
             atlas(["move-to-fly", "--from", empty, "--dry-run", "--env", "test"], on_fly)

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
    assert {out, 0} = atlas(["stop", "--env", "prod"], [{"ATLAS_ENV_FILE", prod_file(false)}])
    assert out =~ "core stopped (rela keeps running)"

    assert {out, 0} = atlas(["stop", "--env", "prod"], [{"ATLAS_ENV_FILE", prod_file(true)}])
    assert out =~ "closed this Mac's tunnel to eyra-atlas"
    assert out =~ "a merge to master deploys it"
  end

  test "moving onto the data clients use on Fly needs --replace-live" do
    on_fly = [{"ATLAS_ENV_FILE", fly_file()}]
    assert {out, 1} = atlas(["move-to-fly", "--from", "/", "--env", "test"], on_fly)
    assert out =~ "its data there is the live one"
    assert out =~ "add --replace-live"
  end

  test "fetch-from-fly needs a folder, and an environment on Fly" do
    on_fly = [{"ATLAS_ENV_FILE", fly_file()}]
    assert {out, 1} = atlas(["fetch-from-fly", "--env", "test"], on_fly)
    assert out =~ "--to <folder>"
    assert {out, 1} = atlas(["fetch-from-fly", "--to", "/", "--env", "test"], on_fly)
    assert out =~ "is not empty"

    local = [{"ATLAS_ENV_FILE", local_file()}]
    assert {out, 1} = atlas(["fetch-from-fly", "--to", "/tmp/x", "--env", "test"], local)
    assert out =~ "does not run on Fly"
  end
end
