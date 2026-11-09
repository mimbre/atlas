#!/usr/bin/env bash
# The smoke check against an environment deployed on Fly; fly/deploy.sh runs it after
# every deploy. It reads only: it never writes the environment's data.
#
#   smoke.sh <env> [<image label>]
#
#  1. With a label: the core on Fly runs that image (the build just deployed).
#  2. bin/atlas reaches Control over the tailnet (control.host and control.port of
#     env/<env>.json, D-0089), and Control answers with the kinds of rela's description:
#     Facts read it from rela. This machine must be on the tailnet (CI joins it first).
#  3. Ordinary kinds list; description-declared restricted roles must return their
#     exact typed scope guard. Scoped record reads are covered by private Facts tests,
#     not by enumerating or creating live guidance records during deployment.
#
# It runs on a private copy of env/<env>.json that says the clients use Fly, so it works
# before the environment's clients do ("in_use": false), with its own folder for the
# clients' files.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd -P)"
env="${1:?usage: smoke.sh <env> [<image label>]}"
label="${2:-}"
fail() { echo "smoke: $*" >&2; exit 1; }
fly="$(command -v fly || command -v flyctl)" || fail "no flyctl"
app="$(jq -r '.fly.app // empty' "$root/env/$env.json")"
[ -n "$app" ] || fail "env/$env.json has no fly.app: $env does not run on Fly"

dir="$(mktemp -d)"
trap 'rm -rf "$dir"' EXIT
jq --arg dir "$dir" '.fly.in_use = true | .fly.local = $dir' "$root/env/$env.json" >"$dir/$env.json"

if [ -n "$label" ]; then
  running="$("$fly" status -a "$app" --json | jq -r '.Machines[0].image_ref.tag')"
  [ "$running" = "$label" ] || fail "$app runs $running, not $label"
  echo "smoke: $app runs $label"
fi

ATLAS_ENV_FILE="$dir/$env.json" ATLAS_NO_UPDATE=1 python3 "$root/fly/smoke-reads.py" \
  "$root/bin/atlas" "$root/rela/atlas.json" "$env" "$app"
