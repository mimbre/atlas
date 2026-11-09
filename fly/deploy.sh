#!/usr/bin/env bash
# Deploy an Atlas environment to Fly: what CI runs on a merge (develop: test, master: prod).
#
#   deploy.sh <env> <image label>
#
# Each app with its own token, when given: ATLAS_FLY_TOKEN_RELA for the rela app,
# ATLAS_FLY_TOKEN_CORE for the core's (else flyctl's own login).
#
#  1. Before anything changes: does this build's description describe all the data rela
#     holds on Fly? It is checked on the rela machine itself, on a copy (what `atlas-ops
#     restart` checks on a Mac, IS-Atlas-73). When it does not, nothing is deployed, and
#     the environment keeps running the build before: that data needs a migration first
#     (docs/guides/test-on-fly.md, "A migration").
#  2. Deploys rela, then the core, both labelled <image label>.
#  3. The smoke check (fly/smoke.sh), which reads only.
#
# A held environment (atlas-ops fetch-from-fly --hold: a migration is under way) is deployed
# without waiting for health checks, and has no smoke check: it serves nothing until the
# migrated data arrives with atlas-ops move-to-fly.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd -P)"
env="${1:?usage: deploy.sh <env> <image label>}"
label="${2:?usage: deploy.sh <env> <image label>}"
settings="$root/env/$env.json"
app="$(jq -er .fly.app "$settings")"
rela_app="$(jq -er .fly.rela_app "$settings")"
fly_bin="$(command -v flyctl || command -v fly)"
fail() { echo "deploy: $*" >&2; exit 1; }

as() { # rela|core, then a flyctl command
  local token
  if [ "$1" = rela ]; then token="${ATLAS_FLY_TOKEN_RELA:-}"; else token="${ATLAS_FLY_TOKEN_CORE:-}"; fi
  shift
  if [ -n "$token" ]; then FLY_API_TOKEN="$token" "$fly_bin" "$@"; else "$fly_bin" "$@"; fi
}
machines() { as "$1" status -a "$2" --json | jq '.Machines | length'; }

# The description is generated from the model: refuse a stale one before anything is uploaded.
(cd "$root/model/contract" && mix model.gen --check)

held=""
if [ "$(machines rela "$rela_app")" -gt 0 ]; then
  if as rela ssh console -q -a "$rela_app" -C "test -e /data/hold" 2>/dev/null; then
    held=1
    echo "deploy: $env is held (a migration is under way); deploying without health checks or smoke check"
  else
    # Resolve the whole selected closure locally before uploading anything. The deployed
    # old image may predate Python/includes, so preflight receives an equivalent flat
    # schema; the new image and local startup still use native includes.
    next="$(mktemp -d)"
    trap 'rm -rf "$next"' EXIT
    "${ATLAS_CONFIG_PYTHON:-python3}" "$root/rela/scripts/config.py" flat > "$next/schema.yaml"
    cp "$root/rela/data-entry.yaml" "$next/data-entry.yaml"
    as rela ssh console -q -a "$rela_app" -C "sh -c 'rm -rf /tmp/next && mkdir -p /tmp/next/scripts'" >/dev/null
    for file in schema.yaml data-entry.yaml; do
      as rela ssh sftp put -a "$rela_app" "$next/$file" "/tmp/next/$file" >/dev/null
    done
    as rela ssh sftp put -a "$rela_app" -m 0755 "$root/fly/check-fits.sh" /tmp/next/scripts/description.sh >/dev/null
    if ! orphans="$(as rela ssh console -q -a "$rela_app" \
      -C "env ATLAS_RELA_DATA=/data/rela ATLAS_RELA_BIN=/app/bin /tmp/next/scripts/description.sh fits" 2>/dev/null)"; then
      echo "deploy: this build's description no longer describes data rela $env holds on Fly:" >&2
      echo "$orphans" | tr -d '\r' | sed 's/^/  /' >&2
      fail "nothing deployed; $env keeps its build. Migrate that data first (docs/guides/test-on-fly.md, \"A migration\")"
    fi
    echo "deploy: this build's description describes all of rela $env's data"
  fi
fi

# 2. rela, then the core.
strategy=()
[ -z "$held" ] || strategy=(--strategy immediate)
as rela deploy "$root" --config "$root/fly/$env/rela.toml" --dockerfile "$root/fly/rela.Dockerfile" \
  --remote-only --ha=false --image-label "$label" ${strategy[@]+"${strategy[@]}"}
as core deploy "$root" --config "$root/fly/$env/core.toml" --dockerfile "$root/fly/core.Dockerfile" \
  --remote-only --ha=false --image-label "$label" ${strategy[@]+"${strategy[@]}"}

# Check the actually deployed pair using each app's own token before the client smoke.
if [ -z "$held" ]; then
  expected="$(shasum -a 256 "$root/rela/atlas.manifest.json" | cut -d ' ' -f 1)"
  for side in rela core; do
    if [ "$side" = rela ]; then paired_app="$rela_app"; else paired_app="$app"; fi
    running="$(as "$side" status -a "$paired_app" --json | jq -r '.Machines[0].image_ref.tag')"
    [ "$running" = "$label" ] || fail "$paired_app runs $running, not $label"
    packaged="$(as "$side" ssh console -q -a "$paired_app" -C "sha256sum /app/rela/atlas.manifest.json" | tr -d '\r' | awk '{print $1}')"
    [ "$packaged" = "$expected" ] || fail "$paired_app has another description composition"
  done
  as rela ssh console -q -a "$rela_app" -C "env ATLAS_RELA_DATA=/data/rela /app/rela/scripts/description.sh same" || fail 'rela runs another schema closure'
fi

# 3. The smoke check, as the core's token.
if [ -n "$held" ]; then
  echo "deploy: $env is held; no smoke check. atlas-ops move-to-fly --env $env ends the hold."
else
  if [ -n "${ATLAS_FLY_TOKEN_CORE:-}" ]; then
    FLY_API_TOKEN="$ATLAS_FLY_TOKEN_CORE" "$root/fly/smoke.sh" "$env" "$label"
  else
    "$root/fly/smoke.sh" "$env" "$label"
  fi
fi
