#!/usr/bin/env bash
# Start the Atlas test rela in the background, detached from the shell or agent
# session that starts it: own session (setsid), no hangup, stdin closed. It
# keeps running when that session ends, until stop.sh or a reboot.
#
#   start-bg.sh              # log: $root/rela-server.log, pid: $root/rela-server.pid
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
root="${ATLAS_TEST_ROOT:-$HOME/.local/share/atlas/test}"
port="${ATLAS_RELA_PORT:-7690}"
log="$root/rela-server.log"
pidfile="$root/rela-server.pid"

if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
  echo "start-bg: already running, pid $(cat "$pidfile")" >&2; exit 1
fi
if holder="$(lsof -nP -t -iTCP:"$port" -sTCP:LISTEN 2>/dev/null)" && [ -n "$holder" ]; then
  echo "start-bg: port $port is already in use by pid $holder" >&2; exit 1
fi

mkdir -p "$root"
echo "--- start-bg $(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$log"
# perl's setsid puts rela in its own session, so a signal to the starter's
# process group does not reach it; start-test.sh execs rela-server-headless-sqlite, so the
# pid below is rela-server-headless-sqlite's.
nohup perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV or die "exec: $!"' \
  "$here/scripts/start-test.sh" >>"$log" 2>&1 </dev/null &
pid=$!
echo "$pid" >"$pidfile"

for _ in $(seq 1 30); do
  if curl -fsS -o /dev/null "http://127.0.0.1:$port/api/v1/_schema" 2>/dev/null; then
    echo "start-bg: running, pid $pid, http://127.0.0.1:$port, log $log"
    exit 0
  fi
  kill -0 "$pid" 2>/dev/null || break
  sleep 1
done
echo "start-bg: rela did not come up; last log lines:" >&2
tail -n 20 "$log" >&2
exit 1
