#!/usr/bin/env bash
# The core of an Atlas environment on Fly (Bus, Facts, Flow, Control): the release, with
# Facts' own data on the volume (/data/beam) and the settings of fly/<env>/core.json.
set -euo pipefail

/app/fly/apply-move.sh beam

# Held (atlas-ops fetch-from-fly --hold, for a migration on a copy): the machine stays up, so
# its data can be read and a move can arrive, but nothing serves or writes it. A move ends
# the hold (apply-move.sh); so does: fly ssh console -C "rm /data/hold", then a restart.
if [ -e /data/hold ]; then
  echo "held: /data/hold is there; not starting the core until a move ends the hold"
  exec sleep infinity
fi

python3 /app/rela/scripts/verify.py /app/rela
exec /app/release/bin/atlas start
