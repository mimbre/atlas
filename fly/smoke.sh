#!/usr/bin/env bash
# The smoke check against an environment deployed on Fly; fly/deploy.sh runs it after
# every deploy. It reads only: it never writes the environment's data.
#
#   smoke.sh <env> [<image label>]
#
#  1. With a label: the core on Fly runs that image (the build just deployed).
#  2. bin/atlas opens a tunnel over WireGuard to Control on the private network, and
#     Control answers with the kinds of rela's description: Facts read it from rela.
#  3. Ordinary kinds list; description-declared restricted roles must return their
#     exact typed scope guard. Scoped record reads are covered by private Facts tests,
#     not by enumerating or creating live guidance records during deployment.
#
# It runs on a private copy of env/<env>.json with a tunnel of its own on a free port, so
# it works before the environment's clients use Fly ("in_use": false) and never meets a
# tunnel already open on this machine.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd -P)"
env="${1:?usage: smoke.sh <env> [<image label>]}"
label="${2:-}"
fail() { echo "smoke: $*" >&2; exit 1; }
fly="$(command -v fly || command -v flyctl)" || fail "no flyctl"
app="$(jq -r '.fly.app // empty' "$root/env/$env.json")"
[ -n "$app" ] || fail "env/$env.json has no fly.app: $env does not run on Fly"

dir="$(mktemp -d "${TMPDIR:-/tmp}/atlas-smoke.XXXXXX")"
port="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
jq --arg dir "$dir" --argjson port "$port" \
  '.fly.in_use = true | .fly.local = $dir | .control.port = $port' "$root/env/$env.json" >"$dir/$env.json"
ops() { ATLAS_ENV_FILE="$dir/$env.json" ATLAS_NO_UPDATE=1 "$root/bin/atlas-ops" "$@" --env "$env"; }
trap 'ops tunnel close >/dev/null 2>&1 || true; rm -rf "$dir"' EXIT

if [ -n "$label" ]; then
  running="$("$fly" status -a "$app" --json | jq -r '.Machines[0].image_ref.tag')"
  [ "$running" = "$label" ] || fail "$app runs $running, not $label"
  echo "smoke: $app runs $label"
fi

ATLAS_ENV_FILE="$dir/$env.json" ATLAS_NO_UPDATE=1 python3 "$root/fly/smoke-reads.py" \
  "$root/bin/atlas" "$root/rela/atlas.json" "$env" "$app"
