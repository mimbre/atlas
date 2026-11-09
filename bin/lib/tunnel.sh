# The tunnel to an environment on Fly, shared by bin/atlas (which opens it when a command
# needs Control) and bin/atlas-ops (which shows and closes it). Sourced after env.sh, once
# resolve_places has run. It is `fly proxy` from this machine's control.port to Control on
# the environment's private network, over WireGuard, and runs in the background.
tunnel_pidfile() { echo "$ATLAS_TEST_ROOT/tunnel.pid"; }
tunnel_log() { echo "$ATLAS_TEST_ROOT/tunnel.log"; }
control_ready() {
  probe_error="$(python3 "$root/fly/control-ready.py" "$settings" "$root/bff/targets/json/blocks.json" 2>&1)"
}
fly_cli() {
  command -v fly || command -v flyctl || {
    echo "$prog: $env runs on Fly; install flyctl (brew install flyctl), then: fly auth login" >&2
    exit 1
  }
}
tunnel_pid() {
  local pid; pid="$(cat "$(tunnel_pidfile)" 2>/dev/null || true)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && echo "$pid"
}
stop_tunnel() {
  local pid; pid="$(tunnel_pid || true)"
  if [ -n "$pid" ]; then
    kill -TERM "$pid" 2>/dev/null || true
    for _ in $(seq 1 20); do listening || break; sleep 0.1; done
  fi
  rm -f "$(tunnel_pidfile)"
}
ensure_tunnel() {
  local fly holder deadline probe_error=""
  if tunnel_pid >/dev/null; then
    if control_ready; then return 0; fi
    echo "$prog: the tunnel to $fly_app is not reaching Control; reopening it ($probe_error)" >&2
  fi
  stop_tunnel
  if listening; then
    holder="$(lsof -nP -t -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | head -1 || true)"
    echo "$prog: port $port is taken by pid ${holder:-?}, not by atlas's tunnel to $fly_app; stop it first" >&2
    exit 1
  fi
  fly="$(fly_cli)"
  mkdir -p "$ATLAS_TEST_ROOT"
  echo "$prog: opening the tunnel to $env's Control on Fly ($fly_app, over WireGuard)" >&2
  nohup "$fly" proxy "$port:$fly_port" -a "$fly_app" -q >"$(tunnel_log)" 2>&1 </dev/null &
  echo $! >"$(tunnel_pidfile)"
  deadline=$((SECONDS + 60))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if listening && control_ready; then return 0; fi
    if ! kill -0 "$(cat "$(tunnel_pidfile)")" 2>/dev/null; then
      echo "$prog: the tunnel to $fly_app did not open; the last lines of $(tunnel_log):" >&2
      tail -5 "$(tunnel_log)" >&2
      echo "$prog: is flyctl logged in to the eyra organisation? fly auth whoami" >&2
      exit 1
    fi
    sleep 0.5
  done
  echo "$prog: Control on $fly_app did not answer through the tunnel within a minute: $probe_error; see $(tunnel_log)" >&2
  stop_tunnel
  exit 1
}
