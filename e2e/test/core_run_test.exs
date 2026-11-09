defmodule AtlasE2E.CoreRunTest do
  # fly/core-run.sh joins the tailnet before anything else (D-0089), and without its key
  # starts nothing. Its node is persistent: the key logs in only a node without a login.
  # tailscale and tailscaled are stand-ins on PATH that note each call; `tailscale status
  # --json` answers the BackendState in the file before (until an up), after (after an up
  # without the key) or keyed (after an up with it). No tailnet, Fly machine or core is
  # involved. Past the tailnet the core comes: its first step, fly/apply-move.sh, is a
  # stand-in too that notes its call and stops the script with @joined.
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @joined 42

  setup do
    dir = Path.join(System.tmp_dir!(), "atlas-core-run-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    calls = Path.join(dir, "calls")

    states = for name <- ["before", "after", "keyed"], into: %{}, do: {name, Path.join(dir, name)}

    stubs = %{
      "tailscaled" => "",
      "app/fly/apply-move.sh" => "exit #{@joined}",
      "tailscale" => """
      for a in "$@"; do
        case "$a" in
          --auth-key=file:*) f="${a#--auth-key=file:}"
            echo "key file $(ls -l "$f" | cut -c1-10) $(cat "$f")" >> '#{calls}' ;;
        esac
      done
      case "$*" in
        *" status --json")
          if grep -q "auth-key" '#{calls}'; then s=$(cat '#{states["keyed"]}')
          elif grep -q " up " '#{calls}'; then s=$(cat '#{states["after"]}')
          else s=$(cat '#{states["before"]}'); fi
          printf '{"Version":"stub","BackendState":"%s"}\\n' "$s" ;;
      esac
      """
    }

    for {name, body} <- stubs do
      file = Path.join(dir, name)
      File.mkdir_p!(Path.dirname(file))

      File.write!(file, """
      #!/bin/sh
      echo "#{name} ${TS_AUTHKEY:+(key in env)} $*" >> '#{calls}'
      #{body}
      """)

      File.chmod!(file, 0o755)
    end

    File.write!(states["before"], "NeedsLogin")
    File.write!(states["after"], "Running")
    File.write!(states["keyed"], "Running")

    %{
      dir: dir,
      calls: calls,
      before: states["before"],
      later: states["after"],
      keyed: states["keyed"]
    }
  end

  defp core_run(dir, env) do
    System.cmd("bash", [Path.join(@root, "fly/core-run.sh")],
      env:
        [
          {"PATH", dir <> ":" <> System.get_env("PATH")},
          {"TS_AUTHKEY", nil},
          {"FLY_APP_NAME", "private-app"},
          {"ATLAS_ENV", "test"},
          {"ATLAS_TS_STATE_DIR", Path.join(dir, "state")},
          {"ATLAS_TS_SOCKET_DIR", Path.join(dir, "run")},
          {"ATLAS_APP_DIR", Path.join(dir, "app")}
        ] ++ env,
      stderr_to_stdout: true
    )
  end

  defp lines(file),
    do:
      if(File.exists?(file), do: file |> File.read!() |> String.split("\n", trim: true), else: [])

  defp up(dir, env, extra \\ ""),
    do:
      "tailscale  --socket=#{dir}/run/tailscaled.sock up #{extra}--hostname=private-app " <>
        "--advertise-tags=tag:atlas-#{env} --accept-dns=false --timeout=60s"

  defp key_flag(dir), do: "--auth-key=file:#{dir}/run/authkey "

  test "without TS_AUTHKEY, an app name or a test or prod environment, the machine starts nothing",
       %{dir: dir, calls: calls} do
    key = {"TS_AUTHKEY", "private-key"}

    for env <- [
          [{"TS_AUTHKEY", nil}],
          [{"TS_AUTHKEY", ""}],
          [key, {"FLY_APP_NAME", nil}],
          [key, {"ATLAS_ENV", "staging"}]
        ] do
      assert {_out, 1} = core_run(dir, env)
      assert lines(calls) == []
      refute File.exists?(Path.join(dir, "state"))
    end
  end

  test "a first boot logs in with the key, as the app, tagged with its environment, keeping Fly's DNS",
       %{dir: dir, calls: calls} do
    assert {out, @joined} = core_run(dir, [{"TS_AUTHKEY", "private-key"}, {"ATLAS_ENV", "prod"}])
    refute out =~ "private-key"

    # The state on the volume, private; the socket's folder made before tailscaled starts.
    assert File.dir?(Path.join(dir, "run"))
    assert %{mode: mode} = File.stat!(Path.join(dir, "state"))
    assert Bitwise.band(mode, 0o777) == 0o700

    lines = lines(calls)
    # up reads the key from a file only its owner can read, which is gone afterwards. The key
    # is in no process's environment (tailscaled's included) and on no command line.
    assert Enum.any?(
             lines,
             &(&1 =~
                 ~r"^tailscaled  --statedir=#{dir}/state --socket=#{dir}/run/tailscaled.sock( --tun=userspace-networking)?$")
           )

    assert up(dir, "prod", key_flag(dir)) in lines
    assert "key file -rw------- private-key" in lines
    refute File.exists?(Path.join(dir, "run/authkey"))
    # Then the core, without the key in its environment.
    assert List.last(lines) == "app/fly/apply-move.sh  beam"

    refute Enum.any?(
             lines,
             &(&1 =~ ~r"\(key in env\)|=private-key|logout|--state=mem:|ephemeral")
           )
  end

  test "a restart with state reuses the node: same name, no key", %{
    dir: dir,
    calls: calls,
    before: before
  } do
    for state <- ["Starting", "Running", "Stopped"] do
      File.rm(calls)
      File.write!(before, state)
      assert {_out, @joined} = core_run(dir, [{"TS_AUTHKEY", "private-key"}])
      lines = lines(calls)
      assert up(dir, "test") in lines
      refute Enum.any?(lines, &(&1 =~ ~r"auth-key|private-key|key in env|logout"))
    end
  end

  test "a node the tailnet no longer accepts logs in again with the key, once", %{
    dir: dir,
    calls: calls,
    before: before,
    later: later
  } do
    File.write!(before, "Starting")
    File.write!(later, "NeedsLogin")
    assert {out, @joined} = core_run(dir, [{"TS_AUTHKEY", "private-key"}])
    refute out =~ "private-key"

    ups = calls |> lines() |> Enum.filter(&(&1 =~ " up "))
    assert ups == [up(dir, "test"), up(dir, "test", key_flag(dir) <> "--force-reauth ")]
    assert "key file -rw------- private-key" in lines(calls)
    refute File.exists?(Path.join(dir, "run/authkey"))
  end

  test "the machine is on the tailnet only when the backend runs, whatever up exits with", %{
    dir: dir,
    calls: calls,
    keyed: keyed
  } do
    # The stand-in up exits 0; the backend still needs a login after the key was used, and
    # tailscaled is gone: no second login, no core.
    File.write!(keyed, "NeedsLogin")
    assert {out, 1} = core_run(dir, [{"TS_AUTHKEY", "private-key"}])
    refute out =~ "private-key"
    assert calls |> lines() |> Enum.count(&(&1 =~ " up ")) == 1
    refute Enum.any?(lines(calls), &(&1 =~ "apply-move"))
    refute File.exists?(Path.join(dir, "run/authkey"))
  end
end
