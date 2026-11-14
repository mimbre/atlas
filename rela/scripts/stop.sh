#!/usr/bin/env bash
# Stop the Atlas test rela started by start-bg.sh, by its pid file, signalling that pid only.
# Nothing here lists processes (ps, pgrep, pkill), which a sandboxed worker may not.
set -euo pipefail

root="${ATLAS_TEST_ROOT:-$HOME/.local/share/atlas/test}"
port="${ATLAS_RELA_PORT:-7690}"
pidfile="$root/rela-server.pid"

if [ ! -f "$pidfile" ]; then
  echo "stop: no pid file at $pidfile; nothing started by start-bg.sh" >&2; exit 1
fi
pid="$(cat "$pidfile")"
if ! kill -0 "$pid" 2>/dev/null; then
  echo "stop: pid $pid is not running; removing the stale pid file"
  rm -f "$pidfile"; exit 0
fi
# Only ever stop the Atlas test rela, never another process that reused the pid: the pid
# start-bg.sh wrote must be the one listening on this rela's port.
own=""
for holder in $(lsof -nP -t -iTCP:"$port" -sTCP:LISTEN 2>/dev/null || true); do
  [ "$holder" = "$pid" ] && own=1
done
if [ -z "$own" ]; then
  echo "stop: pid $pid does not listen on port $port, so it is not the Atlas test rela; not stopping it" >&2
  exit 1
fi

kill "$pid"
for _ in $(seq 1 10); do
  kill -0 "$pid" 2>/dev/null || { rm -f "$pidfile"; echo "stop: stopped pid $pid"; exit 0; }
  sleep 1
done
kill -9 "$pid" 2>/dev/null || true
rm -f "$pidfile"
echo "stop: pid $pid did not stop in 10 s; killed it"
