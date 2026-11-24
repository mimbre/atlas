#!/usr/bin/env bash
# rela of an Atlas environment on Fly: its data on the volume (/data/rela), this image's
# description. The app has no public address; on the environment's private network only
# the core may use it (IS-Atlas-80): rela listens on loopback, and rela-gate.py, on the
# private network, passes on only what carries the core's credential ($ATLAS_RELA_TOKEN,
# a Fly secret of both apps). The same start-test.sh as on a Mac, with other folders.
set -euo pipefail

/app/platform/ops/apply-move.sh rela

# Held (atlas-ops fetch-from-fly --hold, for a migration on a copy): the machine stays up, so
# its data can be read and a move can arrive, but nothing serves or writes it. A move ends
# the hold (apply-move.sh); so does: fly ssh console -C "rm /data/hold", then a restart.
if [ -e /data/hold ]; then
  echo "held: /data/hold is there; not starting rela until a move ends the hold"
  exec sleep infinity
fi

port="${ATLAS_RELA_PORT:-7690}"
inner=$((port + 1))

# rela's own GitHub sync (scripts/github.lua, run by rela's scheduler) reads its token as a
# rela secret: the app's Fly secret GITHUB_TOKEN, written to the project's
# .rela/secrets.yaml (only the owner may read it), never printed, and kept from rela's
# environment. Without it the sync does nothing.
if [ -n "${GITHUB_TOKEN:-}" ]; then
  mkdir -p /data/rela/.rela
  (umask 077 && printf 'github_token: "%s"\n' "$GITHUB_TOKEN" > /data/rela/.rela/secrets.yaml)
fi

# start-test checks existing SQLite or legacy data before changing its description,
# including boot after a move. It refuses when that data needs a migration first.
env -u ATLAS_RELA_TOKEN -u GITHUB_TOKEN ATLAS_RELA_DATA=/data/rela ATLAS_RELA_BIN=/app/bin ATLAS_RELA_PORT="$inner" \
  /app/platform/atlas_facts/rela/scripts/start-test.sh &
rela=$!
python3 /app/platform/ops/rela-gate.py "$port" "$inner" &
gate=$!

# Either one ending ends the machine (Fly restarts it); a stop stops rela cleanly.
stop() { kill -TERM "$rela" "$gate" 2>/dev/null || true; wait "$rela" 2>/dev/null || true; }
trap 'stop; exit 143' TERM INT
status=1
wait -n "$rela" "$gate" || status=$?
stop
exit "$status"
