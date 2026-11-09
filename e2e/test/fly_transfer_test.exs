defmodule AtlasE2E.FlyTransferTest do
  use ExUnit.Case, async: true
  @root Path.expand("../..", __DIR__)
  @moduletag :tmp_dir

  defp executable(file, body) do
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, "#!/bin/bash\nset -euo pipefail\n" <> body)
    File.chmod!(file, 0o755)
  end

  defp bytes(dir) do
    Path.wildcard(Path.join(dir, "**/*"), match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Map.new(&{Path.relative_to(&1, dir), File.read!(&1)})
  end

  defp store(dir) do
    for {name, contents} <- [
          {"rela/.rela/rela.db", "durable database"},
          {"rela/.rela/rela.db-wal", "committed WAL"},
          {"rela/.rela/rela.db-shm", "original SHM"},
          {"rela/.rela/audit/events", "retained history"},
          {"beam/facts", "ownership and answered facts"}
        ] do
      file = Path.join(dir, name)
      File.mkdir_p!(Path.dirname(file))
      File.write!(file, contents)
    end
  end

  setup %{tmp_dir: dir} do
    root = Path.join(dir, "app")
    tools = Path.join(dir, "tools")
    source = Path.join(dir, "source")
    remote = Path.join(dir, "remote")
    File.mkdir_p!(Path.join(root, "fly"))
    File.mkdir_p!(tools)
    store(source)

    for {name, role} <- [{"rela", "rela"}, {"beam", "core"}] do
      File.mkdir_p!(Path.join(remote, role))
      File.cp_r!(Path.join(source, name), Path.join([remote, role, name]))
    end

    for name <- ~w(move-to-fly.sh fetch-from-fly.sh manifest.sh) do
      File.cp!(Path.join(@root, "fly/#{name}"), Path.join(root, "fly/#{name}"))
    end

    executable(Path.join(root, "rela/scripts/start-test.sh"), "exit 0\n")

    # Simulate SQLite's observable side effect on a check target. Assertions compare
    # complete raw file contents, including SHM, not helper calls or selected counts.
    mutate = """
    printf reconstructed > "$data/.rela/rela.db-shm"
    printf '%s\\n' "$data" >> "$CHECKED"
    """

    executable(Path.join(root, "rela/scripts/description.sh"), """
    data="$ATLAS_RELA_DATA"
    #{mutate}
    exit "${FAIL_FITS:-0}"
    """)

    executable(Path.join(root, "fly/counts.sh"), """
    data="$1"
    #{mutate}
    [ "${FAIL_COUNTS:-0}" = 0 ] || exit "$FAIL_COUNTS"
    printf 'notes 2\\nlinks related 1\\nlinks 1\\n'
    """)

    executable(Path.join(tools, "pgrep"), """
    [ "${SERVED:-0}" = 1 ] || exit 1
    echo '123 rela-server-headless-sqlite'
    """)

    executable(Path.join(tools, "sleep"), "exit 0\n")

    executable(Path.join(tools, "tar"), """
    [ "${SERVED:-0}" = 0 ] || { echo 'raw copy of live store' >&2; exit 86; }
    exec "#{System.find_executable("tar")}" "$@"
    """)

    executable(Path.join(tools, "fly"), ~S"""
    printf '%s\n' "$*" >> "$EVENTS"
    case "$1 $2" in
      'ssh console')
        shift 2
        app='' command=''
        while [ $# -gt 0 ]; do
          case "$1" in
            -a) app="$2"; shift 2 ;;
            -C) command="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        role="${app#rehearsal-}"
        volume="$REMOTE/$role"
        case "$command" in
          'test -x '*) exit 0 ;;
          '/app/fly/counts.sh '*) printf 'notes 2\nlinks related 1\nlinks 1\n' ;;
          'mkdir -p /data/incoming') mkdir -p "$volume/incoming" ;;
          'mv /data/incoming/'*) mv "$volume/incoming/"*.part "$volume/incoming/${role/core/beam}.tar.gz" ;;
          'cat /data/'*) cat "$volume/$(basename "${command#cat }")" ;;
          "sh -c 'cd /data"*) echo checked ;;
          'touch /data/hold') touch "$volume/hold" ;;
          'test -e /data/hold') test -e "$volume/hold" ;;
          'rm -f /data/hold') rm -f "$volume/hold" ;;
          'tar -czf /tmp/'*)
            name="${role/core/beam}"
            tar -czf "$volume/$name.tar.gz" -C "$volume/$name" . ;;
          'rm -f /tmp/'*) rm -f "$volume/"*.tar.gz ;;
          *) echo "unexpected console: $command" >&2; exit 90 ;;
        esac ;;
      'ssh sftp')
        role="${5#rehearsal-}"
        if [ "$3" = put ]; then
          cp "$6" "$REMOTE/$role/incoming/$(basename "$7")"
        else
          cp "$REMOTE/$role/$(basename "$6")" "$7"
        fi ;;
      'machine restart')
        role="${5#rehearsal-}"
        name="${role/core/beam}"
        volume="$REMOTE/$role"
        if [ -f "$volume/incoming/$name.tar.gz" ]; then
          rm -rf "$volume/$name"
          mkdir "$volume/$name"
          tar -xzf "$volume/incoming/$name.tar.gz" -C "$volume/$name"
          "$APP/fly/manifest.sh" "$volume/$name" > "$volume/$name.manifest"
          cp "$volume/incoming/$name.tar.gz" "$volume/sent.tar.gz"
          rm "$volume/incoming/$name.tar.gz"
        fi ;;
      'status -a') printf '{"Machines":[{"id":"fixture","state":"started","checks":[]}]}' ;;
      *) exit 91 ;;
    esac
    """)

    env = [
      {"PATH", tools <> ":" <> System.get_env("PATH")},
      {"ATLAS_FLY_APP", "rehearsal-core"},
      {"ATLAS_FLY_RELA_APP", "rehearsal-rela"},
      {"ATLAS_ENV", "test"},
      {"ATLAS_FLY_IN_USE", "false"},
      {"ATLAS_FLY_LOCAL", Path.join(dir, "local")},
      {"SERVED", "0"},
      {"FAIL_FITS", "0"},
      {"FAIL_COUNTS", "0"},
      {"REMOTE", remote},
      {"APP", root},
      {"EVENTS", Path.join(dir, "events")},
      {"CHECKED", Path.join(dir, "checked")}
    ]

    %{root: root, dir: dir, source: source, remote: remote, env: env}
  end

  defp move(c, args \\ [], env \\ []) do
    System.cmd("bash", [Path.join(c.root, "fly/move-to-fly.sh"), "--from", c.source] ++ args,
      env: c.env ++ env,
      stderr_to_stdout: true
    )
  end

  test "stopped validation preserves all source and arrival bytes including SHM", c do
    before = bytes(c.source)
    {out, status} = move(c)
    assert status == 0, out
    assert bytes(c.source) == before

    for {name, role} <- [{"rela", "rela"}, {"beam", "core"}] do
      arrived = Path.join([c.remote, role, name])
      assert bytes(arrived) == bytes(Path.join(c.source, name))
      assert {expected, 0} = System.cmd("bash", [Path.join(c.root, "fly/manifest.sh"), arrived])
      assert File.read!(Path.join([c.remote, role, "#{name}.manifest"])) == expected
    end

    assert File.read!(Path.join(c.dir, "checked")) != ""
    assert out =~ "every file of rela/ arrived as sent"
  end

  test "fetch returns raw stopped bytes while its counter rebuilds private SHM", c do
    before = bytes(c.remote)
    to = Path.join(c.dir, "fetched")

    {out, status} =
      System.cmd("bash", [Path.join(c.root, "fly/fetch-from-fly.sh"), "--to", to, "--hold"],
        env: c.env,
        stderr_to_stdout: true
      )

    assert status == 0, out
    assert bytes(to) == bytes(c.source)
    assert bytes(c.remote) |> Map.drop(["core/hold", "rela/hold"]) == before
    assert File.read!(Path.join(c.dir, "checked")) != ""
  end

  test "failed fetch count preserves the raw backup and leaves both holds", c do
    to = Path.join(c.dir, "fetched")

    {_, status} =
      System.cmd("bash", [Path.join(c.root, "fly/fetch-from-fly.sh"), "--to", to],
        env: c.env ++ [{"FAIL_COUNTS", "42"}],
        stderr_to_stdout: true
      )

    assert status != 0
    assert bytes(to) == bytes(c.source)
    assert File.read!(Path.join(c.dir, "checked")) != ""
    for role <- ["core", "rela"], do: assert(File.exists?(Path.join([c.remote, role, "hold"])))
  end

  for failure <- ["FAIL_FITS", "FAIL_COUNTS"] do
    test "#{failure} refuses before transport without changing source", c do
      before = bytes(c.source)
      {_, status} = move(c, [], [{unquote(failure), "42"}])
      assert status != 0
      assert File.read!(Path.join(c.dir, "checked")) != ""
      assert bytes(c.source) == before
      refute File.exists?(Path.join(c.dir, "events"))
    end
  end

  test "served source refuses real transfer, but live dry-run never raw-copies it", c do
    before = bytes(c.source)
    assert {_, 1} = move(c, [], [{"SERVED", "1"}])
    assert bytes(c.source) == before
    refute File.exists?(Path.join(c.dir, "events"))

    # The tar fixture refuses any raw copying of a served store. The helper seam
    # models online snapshot reads; stopped-source cases exercise real tar archives.
    {out, status} = move(c, ["--dry-run"], [{"SERVED", "1"}])
    assert status == 0, out

    refute File.read!(Path.join([c.source, "rela/.rela/rela.db-shm"])) ==
             Map.fetch!(before, "rela/.rela/rela.db-shm")

    events = File.read!(Path.join(c.dir, "events"))
    refute events =~ "sftp"
    refute events =~ "machine restart"
  end
end
