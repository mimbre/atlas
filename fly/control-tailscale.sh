# Sourced only by core-run after apply-move, hold and Rela verification.
# Foreground Serve owns only Control ingress; userspace networking adds no kernel routes.
fail() { echo "control-tailscale: $*" >&2; exit 1; }
umask 077
state_dir="${ATLAS_CONTROL_TS_STATE_DIR:-/data/control-tailscale}"
sock_dir="${ATLAS_CONTROL_TS_SOCKET_DIR:-/var/run/atlas-control-tailscale}"
mkdir -p "$state_dir" "$sock_dir"
chmod 700 "$state_dir" "$sock_dir"
sock="$sock_dir/tailscaled.sock"
[ ! -e "$sock" ] || fail "socket already exists; refusing to adopt another daemon"
daemon_pid=""; serve_pid=""; core_pid=""; key_file=""
cleanup() {
  trap - TERM INT
  for pid in "$serve_pid" "$core_pid" "$daemon_pid"; do
    [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null || true
  done
  for _ in {1..30}; do
    alive=""
    for pid in "$serve_pid" "$core_pid" "$daemon_pid"; do
      if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then alive=1; fi
    done
    [ -n "$alive" ] || break
    sleep 0.1
  done
  for pid in "$serve_pid" "$core_pid" "$daemon_pid"; do
    [ -z "$pid" ] || kill -KILL "$pid" 2>/dev/null || true
    [ -z "$pid" ] || wait "$pid" 2>/dev/null || true
  done
  [ -z "$key_file" ] || rm -f "$key_file"
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
ts() { tailscale --socket="$sock" "$@"; }
backend_state() {
  ts status --json 2>/dev/null | python3 -c 'import sys,json; print(json.load(sys.stdin).get("BackendState", ""))' 2>/dev/null || true
}
case "${ATLAS_ENV:-}" in test|prod) ;; *) fail "ATLAS_ENV must be test or prod" ;; esac
settings="${ATLAS_ENV_FILE:-$app/env/$ATLAS_ENV.json}"
# Use exactly the release's settings; never guess a port or forward a nonloopback backend.
control_port="$(python3 -c '
import json,sys
s=json.load(open(sys.argv[1])); c=s["control"]
assert s["env"]==sys.argv[2]
assert c["host"] in ("::", "0.0.0.0", "::1", "127.0.0.1")
p=c["port"]; assert type(p) is int and 1 <= p <= 65535
print(p)
' "$settings" "$ATLAS_ENV")" || fail "settings require an existing loopback-reachable Control listener"
tls_port="${ATLAS_CONTROL_TLS_PORT:-443}"
[[ "$tls_port" =~ ^[0-9]{1,5}$ ]] || fail "invalid TLS port"
(( 10#$tls_port >= 1 && 10#$tls_port <= 65535 )) || fail "invalid TLS port"
tailscaled --tun=userspace-networking --statedir="$state_dir" --socket="$sock" &
daemon_pid=$!
state=""
for _ in {1..100}; do
  kill -0 "$daemon_pid" 2>/dev/null || fail "owned tailscaled exited"
  state="$(backend_state)"
  case "$state" in ""|NoState|Starting) sleep 0.1 ;; *) break ;; esac
done
case "$state" in
  Running) ;; # Reuse an authorized node without requiring or consuming a key.
  Stopped)
    ts up --accept-dns=false --accept-routes=false --timeout=60s >/dev/null 2>&1 ||
      fail "cannot resume persisted node without login"
    ;;
  NeedsLogin)
    [ -n "$control_ts_key" ] || fail "node needs operator-authorized login"
    key_file="$(mktemp "$sock_dir/authkey.XXXXXX")"
    printf '%s' "$control_ts_key" >"$key_file"
    control_ts_key=""
    # Suppress login output: neither success nor failure may echo enrollment material.
    if ! ts up --auth-key="file:$key_file" --accept-dns=false --accept-routes=false --timeout=60s >/dev/null 2>&1; then
      fail "operator-authorized login failed"
    fi
    rm -f "$key_file"; key_file=""
    ;;
  *) fail "node is not authorized and running" ;;
esac
control_ts_key=""
[ "$(backend_state)" = Running ] || fail "node is not Running"
# Restate the restricted preferences for persisted nodes as well. No tags, routes or SSH.
ts set --accept-dns=false --accept-routes=false --ssh=false \
  --advertise-routes= --advertise-tags= --advertise-exit-node=false ||
  fail "cannot restrict node preferences"
"$app/release/bin/atlas" start &
core_pid=$!
ready=""
for _ in {1..100}; do
  kill -0 "$daemon_pid" 2>/dev/null || fail "owned tailscaled exited"
  kill -0 "$core_pid" 2>/dev/null || fail "core exited before Control listened"
  if python3 -c 'import socket,sys; s=socket.create_connection(("localhost",int(sys.argv[1])),.1); s.close()' "$control_port" 2>/dev/null; then
    ready=1; break
  fi
  sleep 0.1
done
[ -n "$ready" ] || fail "Control did not become loopback-reachable"
# No --bg: the route lives only with this supervised process. No Funnel.
tailscale --socket="$sock" serve --tls-terminated-tcp="$tls_port" "tcp://localhost:$control_port" &
serve_pid=$!
while :; do
  kill -0 "$daemon_pid" 2>/dev/null || fail "owned tailscaled exited"
  kill -0 "$serve_pid" 2>/dev/null || fail "Serve exited"
  kill -0 "$core_pid" 2>/dev/null || fail "core exited"
  sleep 0.2
done
