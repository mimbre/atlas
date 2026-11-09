#!/usr/bin/env bash
# The core of an Atlas environment on Fly (Bus, Facts, Flow, Control): the release, with
# Facts' own data on the volume (/data/beam) and the settings of fly/<env>/core.json.
#
# The machine joins the tailnet first (D-0089): every client reaches Control (and a Runtime
# node the Bus link) at <the Fly app's name>:<port> over it, and nowhere else. The node is
# persistent: tailscaled keeps its state on the app's volume (/data/tailscale), so a restart
# or a crash comes back as the same node with the same name. The key (TS_AUTHKEY) logs in
# only a node that has no login: the first boot, a wiped volume, or a node whose login the
# tailnet no longer accepts (removed from it), which drops to NeedsLogin after its `up` and
# then logs in again with the key, once. A stop never logs out. The key is on no command
# line and in no process's environment: `up` reads it from a private file, removed after.
#
# ATLAS_TS_STATE_DIR and ATLAS_TS_SOCKET_DIR move the state and the socket, ATLAS_APP_DIR the
# image's /app (the tests only).
set -euo pipefail

key="${TS_AUTHKEY:-}"
export -n key
unset TS_AUTHKEY

fail() { echo "core-run: $*" >&2; exit 1; }

# No tailnet, no core: there is no other way in, so a missing key stops the machine here.
[ -n "$key" ] || fail "TS_AUTHKEY is not set: fly secrets set it on this app from Infisical <env>:/tailscale (docs/guides/prod.md, \"Secrets\"); not starting"
[ -n "${FLY_APP_NAME:-}" ] || fail "FLY_APP_NAME is not set: not on a Fly machine; not starting"
case "${ATLAS_ENV:-}" in test|prod) ;; *) fail "ATLAS_ENV is '${ATLAS_ENV:-}', not test or prod; not starting" ;; esac

state_dir="${ATLAS_TS_STATE_DIR:-/data/tailscale}"
sock_dir="${ATLAS_TS_SOCKET_DIR:-/var/run/tailscale}"
app="${ATLAS_APP_DIR:-/app}"
sock="$sock_dir/tailscaled.sock"
ts() { tailscale --socket="$sock" "$@"; }
# BackendState of `tailscale status --json` (NoState, NeedsLogin, NeedsMachineAuth, Stopped,
# Starting, Running), or nothing while tailscaled does not answer. Read from the JSON only:
# the exit status of status differs between states and versions, so it decides nothing.
backend_state() { ts status --json 2>/dev/null | jq -r '.BackendState // empty' 2>/dev/null || true; }

# The state holds the node's private key: on the volume, readable by root only.
mkdir -p "$sock_dir" || fail "cannot create $sock_dir for tailscaled's socket; not starting"
mkdir -p "$state_dir" && chmod 700 "$state_dir" || fail "cannot create $state_dir for tailscaled's state (is the volume mounted at /data?); not starting"

# A kernel TUN when the machine has one (Fly's machines do); else userspace networking,
# which forwards what arrives over the tailnet to the local listeners (Control and the Bus
# link listen on ::).
if [ -c /dev/net/tun ]; then tun=(); else tun=(--tun=userspace-networking); fi
# From here the key is a shell variable only: no process started below inherits it.
tailscaled --statedir="$state_dir" --socket="$sock" ${tun[@]+"${tun[@]}"} &
tailscaled_pid=$!
child=""
key_file="$sock_dir/authkey"
cleanup() {
  trap - TERM INT
  [ -z "$child" ] || kill -TERM "$child" 2>/dev/null || true
  [ -z "$child" ] || wait "$child" 2>/dev/null || true
  kill -TERM "$tailscaled_pid" 2>/dev/null || true
  wait "$tailscaled_pid" 2>/dev/null || true
  rm -f "$key_file"
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

# tailscaled has read its state once it reports a state other than NoState.
state=""
for _ in $(seq 1 100); do
  state="$(backend_state)"
  case "$state" in ""|NoState) ;; *) break ;; esac
  kill -0 "$tailscaled_pid" 2>/dev/null || fail "tailscaled exited before it answered; not starting"
  sleep 0.1
done
case "$state" in ""|NoState) fail "tailscaled did not answer within 10 s; not starting" ;; esac

# DNS stays Fly's: the core resolves rela's .internal name, and no tailnet name. The same
# flags on every boot, so `up` on a node that is logged in only restates its settings.
flags=(--hostname="$FLY_APP_NAME" --advertise-tags="tag:atlas-$ATLAS_ENV" --accept-dns=false --timeout=60s)
# A login with the key, at most once per boot: `up` reads it from a file only root can read
# (beside tailscaled's socket, not on the volume), which goes as soon as up returns.
logged_in=""
login() {
  logged_in=1
  (umask 077 && printf '%s' "$key" >"$key_file") || fail "cannot write the key for tailscale up; not starting"
  ts up --auth-key="file:$key_file" "$@" "${flags[@]}" && up=0 || up=$?
  rm -f "$key_file"
}
if [ "$state" = NeedsLogin ]; then
  echo "core-run: no tailnet login in $state_dir; logging in with TS_AUTHKEY"
  login
else
  echo "core-run: the node in $state_dir is logged in ($state); TS_AUTHKEY is not used"
  ts up "${flags[@]}" && up=0 || up=$?
fi

# On the tailnet once the backend runs, whatever up exited with. A node the tailnet no longer
# accepts (removed from it) needs a login after all: once, with the key, within the bound.
for _ in $(seq 1 60); do
  state="$(backend_state)"
  [ "$state" = Running ] && break
  if [ "$state" = NeedsLogin ] && [ -z "$logged_in" ]; then
    echo "core-run: the tailnet did not accept the node's login (NeedsLogin); logging in with TS_AUTHKEY"
    login --force-reauth
    continue
  fi
  kill -0 "$tailscaled_pid" 2>/dev/null || fail "tailscaled exited while joining the tailnet; not starting"
  sleep 1
done
key=""
[ "$state" = Running ] ||
  fail "not on the tailnet after 60 s (state ${state:-unknown}, tailscale up exited $up): the key, its tag tag:atlas-$ATLAS_ENV, or the tailnet; not starting"
echo "core-run: on the tailnet as $FLY_APP_NAME (tag:atlas-$ATLAS_ENV)"

# Run until Fly stops the machine (SIGTERM), then stop tailscaled, which keeps its state:
# no logout, so the next boot is the same node.
run() {
  kill -0 "$tailscaled_pid" 2>/dev/null || fail "tailscaled exited; not starting application"
  "$@" &
  child=$!
  local status=0
  # Bash on supported developer Macs has no wait -n. Observe both owned children;
  # EXIT cleanup delivers TERM and reaps them, including after ordinary SIGTERM.
  while kill -0 "$child" 2>/dev/null; do
    kill -0 "$tailscaled_pid" 2>/dev/null || fail "tailscaled exited; shutting down application"
    sleep 0.1
  done
  wait "$child" && status=0 || status=$?
  kill -0 "$tailscaled_pid" 2>/dev/null || fail "tailscaled exited; shutting down application"
  exit "$status"
}

"$app/fly/apply-move.sh" beam

# Held (atlas-ops fetch-from-fly --hold, for a migration on a copy): the machine stays up, so
# its data can be read and a move can arrive, but nothing serves or writes it. A move ends
# the hold (apply-move.sh); so does: fly ssh console -C "rm /data/hold", then a restart.
if [ -e /data/hold ]; then
  echo "held: /data/hold is there; not starting the core until a move ends the hold"
  run sleep infinity
fi

python3 "$app/rela/scripts/verify.py" "$app/rela"
run "$app/release/bin/atlas" start
