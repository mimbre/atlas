defmodule AtlasE2E.CoreSupervisionTest do
  use ExUnit.Case, async: false
  @root Path.expand("../..", __DIR__)

  defp executable(path, body) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "#!/bin/bash\n" <> body)
    File.chmod!(path, 0o700)
  end

  setup do
    dir =
      Path.join(System.tmp_dir!(), "atlas-owned-children-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "the first external setup child inherits neither exported key name", %{dir: dir} do
    executable(Path.join(dir, "mkdir"), """
    [ -z "${TS_AUTHKEY+x}" ] && [ -z "${key+x}" ] || exit 91
    echo earliest_child_key_absent
    exit 99
    """)

    {output, status} =
      System.cmd("bash", [Path.join(@root, "fly/core-run.sh")],
        env: [
          {"PATH", dir <> ":" <> System.get_env("PATH")},
          {"TS_AUTHKEY", "synthetic-key"},
          {"key", "inherited-exported-name"},
          {"FLY_APP_NAME", "fixture"},
          {"ATLAS_ENV", "test"}
        ],
        stderr_to_stdout: true
      )

    assert status == 1
    assert output =~ "earliest_child_key_absent"
  end

  for mode <- ["daemon-loss", "normal-term"] do
    test "owned processes are reaped after #{mode}", %{dir: dir} do
      mode = unquote(mode)

      executable(
        Path.join(dir, "bin/tailscaled"),
        "echo $$ > \"$PROOF_CORE/daemon.pid\"\nexec /bin/sleep 60\n"
      )

      executable(Path.join(dir, "bin/tailscale"), """
      [ -z "${TS_AUTHKEY+x}" ] || exit 91
      case "$*" in *"status --json") echo '{"BackendState":"Running"}' ;; esac
      """)

      executable(Path.join(dir, "app/fly/apply-move.sh"), "exit 0\n")
      File.mkdir_p!(Path.join(dir, "app/rela/scripts"))
      File.write!(Path.join(dir, "app/rela/scripts/verify.py"), "pass\n")

      executable(Path.join(dir, "app/release/bin/atlas"), """
      [ -z "${TS_AUTHKEY+x}" ] || exit 91
      trap 'echo terminated > "$PROOF_CORE/terminated"; exit 0' TERM
      echo $$ > "$PROOF_CORE/service.pid"
      while :; do /bin/sleep 0.05; done
      """)

      script = """
      set -u
      launcher=""; daemon=""; service=""
      cleanup() {
        [ -z "$launcher" ] || kill -TERM "$launcher" 2>/dev/null || true
        [ -z "$daemon" ] || kill -TERM "$daemon" 2>/dev/null || true
        [ -z "$service" ] || kill -TERM "$service" 2>/dev/null || true
        [ -z "$launcher" ] || wait "$launcher" 2>/dev/null || true
      }
      trap cleanup EXIT
      bash "$1" > "$PROOF_CORE/launcher.log" 2>&1 &
      launcher=$!
      for ((n=0; n<100; n++)); do
        [ ! -e "$PROOF_CORE/service.pid" ] || break
        /bin/sleep 0.05
      done
      [ -e "$PROOF_CORE/service.pid" ] || { cat "$PROOF_CORE/launcher.log"; exit 92; }
      daemon=$(cat "$PROOF_CORE/daemon.pid"); service=$(cat "$PROOF_CORE/service.pid")
      if [ "$2" = daemon-loss ]; then kill -TERM "$daemon"; else kill -TERM "$launcher"; fi
      for ((n=0; n<100; n++)); do
        kill -0 "$launcher" 2>/dev/null || break
        /bin/sleep 0.05
      done
      kill -0 "$launcher" 2>/dev/null && exit 93
      wait "$launcher"; status=$?
      [ "$status" -ne 0 ] || exit 94
      [ "$2" != normal-term ] || [ "$status" = 143 ] || exit 95
      [ "$2" != daemon-loss ] || [ "$status" = 1 ] || exit 95
      kill -0 "$daemon" 2>/dev/null && exit 96
      kill -0 "$service" 2>/dev/null && exit 97
      [ -e "$PROOF_CORE/terminated" ] || exit 98
      echo "$2: launcher=$status, application received TERM, owned children absent"
      """

      {output, status} =
        System.cmd("bash", ["-c", script, "proof", Path.join(@root, "fly/core-run.sh"), mode],
          env: [
            {"PROOF_CORE", dir},
            {"PATH", Path.join(dir, "bin") <> ":" <> System.get_env("PATH")},
            {"TS_AUTHKEY", "synthetic-key"},
            {"FLY_APP_NAME", "fixture"},
            {"ATLAS_ENV", "test"},
            {"ATLAS_TS_STATE_DIR", Path.join(dir, "state")},
            {"ATLAS_TS_SOCKET_DIR", Path.join(dir, "socket")},
            {"ATLAS_APP_DIR", Path.join(dir, "app")}
          ],
          stderr_to_stdout: true
        )

      assert status == 0, output
      assert output =~ "owned children absent"
    end
  end
end
