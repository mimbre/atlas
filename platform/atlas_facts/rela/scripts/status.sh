#!/usr/bin/env bash
# Show whether the Atlas test rela runs: pid, address, answer.
# Exit 0 when it runs and answers, 1 otherwise.
set -uo pipefail

root="${ATLAS_TEST_ROOT:-$HOME/.local/share/atlas/test}"
port="${ATLAS_RELA_PORT:-7690}"
pidfile="$root/rela-server.pid"
ok=0

# By its pid file only: nothing here lists processes (ps), which a sandboxed worker may not.
if [ -f "$pidfile" ] && pid="$(cat "$pidfile")" && kill -0 "$pid" 2>/dev/null; then
  echo "process: running, pid $pid (from $pidfile)"
else
  echo "process: not running (pid file: ${pid:-none})"; ok=1
fi
holder="$(lsof -nP -t -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | sort -u | tr '\n' ' ' | sed 's/ $//')"
if [ -n "$holder" ]; then echo "port $port: listening, pid $holder"; else echo "port $port: free"; fi
if curl -fsS -o /dev/null "http://127.0.0.1:$port/api/v1/_schema" 2>/dev/null; then
  echo "http: answers at http://127.0.0.1:$port"
else
  echo "http: no answer at http://127.0.0.1:$port"; ok=1
fi
echo "data: $root/rela"
echo "log:  $root/rela-server.log"
exit $ok
