#!/usr/bin/env bash
# The core of an Atlas environment on Fly (Bus, Facts, Flow, Control): the release, with
# Facts' own data on the volume (/data/beam) and the settings of fly/<env>/core.json.
set -euo pipefail
set +x
# Remove enrollment material before apply-move, verification, hold, or any other child.
control_ts_key="${TS_AUTHKEY:-}"
export -n control_ts_key
unset TS_AUTHKEY
app="${ATLAS_APP_DIR:-/app}"

"$app/fly/apply-move.sh" beam

# Held (atlas-ops fetch-from-fly --hold, for a migration on a copy): the machine stays up, so
# its data can be read and a move can arrive, but nothing serves or writes it. A move ends
# the hold (apply-move.sh); so does: fly ssh console -C "rm /data/hold", then a restart.
if [ -e "${ATLAS_HOLD_FILE:-/data/hold}" ]; then
  control_ts_key=""
  echo "held: /data/hold is there; not starting the core until a move ends the hold"
  exec sleep infinity
fi

python3 "$app/rela/scripts/verify.py" "$app/rela"
case "${ATLAS_CONTROL_TAILSCALE:-0}" in
  0) control_ts_key=""; exec "$app/release/bin/atlas" start ;;
  1) . "$app/fly/control-tailscale.sh" ;;
  *) echo "core-run: ATLAS_CONTROL_TAILSCALE must be 0 or 1" >&2; exit 1 ;;
esac
