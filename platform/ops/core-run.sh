#!/usr/bin/env bash
# The core of an Atlas environment on Fly (Bus, Facts, Flow, Control): the release, with
# Facts' own data on the volume (/data/beam) and the settings of products/software_factory/environments/<env>/core.json.
set -euo pipefail
set +x
# Remove enrollment material before apply-move, verification, hold, or any other child.
control_ts_key="${TS_AUTHKEY:-}"
export -n control_ts_key
unset TS_AUTHKEY
# The Runtime backend token goes only to the release (as an env prefix), never to another child or argv.
runtime_backend_token="${ATLAS_RUNTIME_BACKEND_TOKEN:-}"
export -n runtime_backend_token
unset ATLAS_RUNTIME_BACKEND_TOKEN
# Remote Runtime access needs core's own tailscaled (its outbound proxy); check before any child starts.
runtime_remote="${ATLAS_RUNTIME_REMOTE:-0}"
export -n runtime_remote
case "$runtime_remote" in
  0) runtime_backend_token="" ;;
  1) [ "${ATLAS_CONTROL_TAILSCALE:-0}" = 1 ] ||
       { echo "core-run: ATLAS_RUNTIME_REMOTE=1 requires ATLAS_CONTROL_TAILSCALE=1" >&2; exit 1; }
     [ -n "$runtime_backend_token" ] ||
       { echo "core-run: ATLAS_RUNTIME_REMOTE=1 requires a non-empty ATLAS_RUNTIME_BACKEND_TOKEN" >&2; exit 1; } ;;
  *) echo "core-run: ATLAS_RUNTIME_REMOTE must be 0 or 1" >&2; exit 1 ;;
esac
app="${ATLAS_APP_DIR:-/app}"

"$app/platform/ops/apply-move.sh" beam

# Held (atlas-ops fetch-from-fly --hold, for a migration on a copy): the machine stays up, so
# its data can be read and a move can arrive, but nothing serves or writes it. A move ends
# the hold (apply-move.sh); so does: fly ssh console -C "rm /data/hold", then a restart.
if [ -e "${ATLAS_HOLD_FILE:-/data/hold}" ]; then
  control_ts_key=""; runtime_backend_token=""
  echo "held: /data/hold is there; not starting the core until a move ends the hold"
  exec sleep infinity
fi

python3 "$app/platform/atlas_facts/rela/scripts/verify.py" "$app/products/software_factory/model/targets/rela"
case "${ATLAS_CONTROL_TAILSCALE:-0}" in
  0) control_ts_key=""; runtime_backend_token=""; exec "$app/release/bin/atlas" start ;;
  1) . "$app/platform/ops/control-tailscale.sh" ;;
  *) echo "core-run: ATLAS_CONTROL_TAILSCALE must be 0 or 1" >&2; exit 1 ;;
esac
