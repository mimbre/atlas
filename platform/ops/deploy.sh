#!/usr/bin/env bash
# Deploy an Atlas environment to Fly: what CI runs on a merge (develop: test, master: prod).
#
#   deploy.sh <env> <image label>
#
# Each app with its own token, when given: ATLAS_FLY_TOKEN_RELA for the rela app,
# ATLAS_FLY_TOKEN_CORE for the core's (else flyctl's own login).
#
#  1. Generates the targets from the model (bin/generate model): the images carry the Rela
#     project it writes, which is not kept in git.
#  2. Before anything changes: does this build's description describe all the data rela
#     holds on Fly? It is checked on the rela machine itself, on a copy (what `atlas-ops
#     restart` checks on a Mac, IS-Atlas-73). And does the new model keep the flow and state
#     of every open run the running model has (platform/ops/runs-fit.py; a run continues by
#     its flow's and state's names, D-0102)? When either is not so, nothing is deployed, and the
#     environment keeps running the build before: that data needs a migration first
#     (docs/guides/test-on-fly.md, "A migration"), or those runs need to finish or move on.
#  3. Deploys rela, then the core, both labelled <image label>.
#  4. The smoke check (platform/ops/smoke.sh), which reads only.
#
# A held environment (atlas-ops fetch-from-fly --hold: a migration is under way) is deployed
# without waiting for health checks, and has no smoke check: it serves nothing until the
# migrated data arrives with atlas-ops move-to-fly.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd -P)"
env="${1:?usage: deploy.sh <env> <image label>}"
label="${2:?usage: deploy.sh <env> <image label>}"
settings="$root/products/software_factory/environments/$env.json"
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

# A label is not proof that post-deploy checks and cleanup completed. Invalidate
# before any test deployment, including direct invocations and failed preflights.
if [ "$env" = test ] && [ "$(machines rela "$rela_app")" -gt 0 ]; then
  as rela ssh console -q -a "$rela_app" -C "rm -f /data/test-deploy-verified" ||
    fail 'cannot invalidate test deployment evidence'
fi

# 1. The targets, generated from the model with the pinned toolchain.
"$root/bin/generate" model

held=""
empty=""
if [ "$(machines rela "$rela_app")" -gt 0 ]; then
  if as rela ssh console -q -a "$rela_app" -C "test -e /data/hold" 2>/dev/null; then
    held=1
    echo "deploy: $env is held (a migration is under way); deploying without health checks or smoke check"
  else
    # Resolve the whole selected closure locally before uploading anything. The deployed
    # old image may predate Python/includes, so preflight receives an equivalent flat
    # schema; the new image and local startup still use native includes.
    next="$(mktemp -d "${TMPDIR:-/tmp}/atlas-deploy.XXXXXX")"
    trap 'rm -rf "$next"' EXIT
    "${ATLAS_CONFIG_PYTHON:-python3}" "$root/platform/atlas_facts/rela/scripts/config.py" flat > "$next/schema.yaml"
    cp "$root/products/software_factory/model/targets/rela/data-entry.yaml" "$next/data-entry.yaml"
    as rela ssh console -q -a "$rela_app" -C "sh -c 'rm -rf /tmp/next && mkdir -p /tmp/next/scripts'" >/dev/null
    for file in schema.yaml data-entry.yaml; do
      as rela ssh sftp put -a "$rela_app" "$next/$file" "/tmp/next/$file" >/dev/null
    done
    # Stage current tools privately; the old image may have only a filesystem CLI.
    for script in start-test.sh data.sh fits.sh; do
      as rela ssh sftp put -a "$rela_app" -m 0755 "$root/platform/atlas_facts/rela/scripts/$script" "/tmp/next/scripts/$script" >/dev/null
    done
    as rela ssh sftp put -a "$rela_app" -m 0755 "$root/platform/ops/check-fits.sh" /tmp/next/scripts/description.sh >/dev/null
    if ! orphans="$(as rela ssh console -q -a "$rela_app" \
      -C "bash -c 'set -e; bin=/app/bin; if [ -e /data/rela/.rela/rela.db ]; then command -v sqlite3 >/dev/null || { echo \"preflight: SQLite data requires native sqlite3 (Debian package sqlite3); nothing deployed\" >&2; exit 1; }; ATLAS_RELA_BIN=/tmp/next/bin /tmp/next/scripts/start-test.sh install; bin=/tmp/next/bin; fi; ATLAS_RELA_DATA=/data/rela ATLAS_RELA_BIN=\$bin /tmp/next/scripts/description.sh fits'")"; then
      echo "deploy: this build's description no longer describes data rela $env holds on Fly:" >&2
      echo "$orphans" | tr -d '\r' | sed 's/^/  /' >&2
      fail "nothing deployed; $env keeps its build. Migrate that data first (docs/guides/test-on-fly.md, \"A migration\")"
    fi
    empty="$(echo "$orphans" | tr -d '\r' | sed -n 's/^\([^ ]*\) (empty, removed after deploy)$/\1/p' | tr '\n' ' ')"
    [ -z "$empty" ] || echo "deploy: removed fields that hold nothing, removed after deploy: $empty"
    echo "deploy: this build's description describes all of rela $env's data"

    # Every open run the running model has a place for must keep its flow and state in the
    # new model. The runs: rela's own API on the machine's loopback (the port behind
    # rela-gate.py: core.json's rela port + 1). The running model: the deployed core's
    # compiled one (none while the core has no machine). The new one: this build's.
    rela_port="$(jq -er .rela.url "$root/products/software_factory/environments/$env/core.json" | sed -E 's#^[a-z]+://[^/]*:([0-9]+)/.*#\1#')"
    [[ "$rela_port" =~ ^[0-9]+$ ]] || fail "no port in .rela.url of environments/$env/core.json"
    as rela ssh sftp put -a "$rela_app" "$root/platform/ops/runs-fit.py" /tmp/next/runs-fit.py >/dev/null
    as rela ssh console -q -a "$rela_app" -C "python3 /tmp/next/runs-fit.py open $((rela_port + 1))" | tr -d '\r' > "$next/runs.json"
    if [ "$(machines core "$app")" -gt 0 ]; then
      as core ssh console -q -a "$app" -C "/app/release/bin/atlas eval 'IO.puts(JSON.encode!(Map.new(Application.fetch_env!(:atlas, :model).subflows(:$env), fn m -> {m.name(), m.states()} end)))'" | tr -d '\r' | tail -n 1 > "$next/current.json"
    else
      echo '{}' > "$next/current.json"
    fi
    (cd "$root/products/software_factory/model/contract" && mix model.flows --env "$env") | tail -n 1 > "$next/flows.json"
    if ! misfits="$("${ATLAS_CONFIG_PYTHON:-python3}" "$root/platform/ops/runs-fit.py" check "$next/runs.json" "$next/current.json" "$next/flows.json")"; then
      echo "deploy: this build's model takes out the flow or state of open runs of $env:" >&2
      echo "$misfits" | sed 's/^/  /' >&2
      fail "nothing deployed; $env keeps its build. Let those runs finish or move them on first"
    fi
    echo "deploy: this build's model keeps the flow and state of every open run of $env"
  fi
fi

# 3. rela, then the core.
strategy=()
[ -z "$held" ] || strategy=(--strategy immediate)
as rela deploy "$root" --config "$root/products/software_factory/environments/$env/rela.toml" --dockerfile "$root/platform/ops/rela.Dockerfile" \
  --remote-only --ha=false --image-label "$label" ${strategy[@]+"${strategy[@]}"}
as core deploy "$root" --config "$root/products/software_factory/environments/$env/core.toml" --dockerfile "$root/platform/ops/core.Dockerfile" \
  --remote-only --ha=false --image-label "$label" ${strategy[@]+"${strategy[@]}"}

# Check the actually deployed pair using each app's own token before the client smoke.
if [ -z "$held" ]; then
  expected="$(shasum -a 256 "$root/products/software_factory/model/targets/rela/atlas.manifest.json" | cut -d ' ' -f 1)"
  for side in rela core; do
    if [ "$side" = rela ]; then paired_app="$rela_app"; else paired_app="$app"; fi
    running="$(as "$side" status -a "$paired_app" --json | jq -r '.Machines[0].image_ref.tag')"
    [ "$running" = "$label" ] || fail "$paired_app runs $running, not $label"
    packaged="$(as "$side" ssh console -q -a "$paired_app" -C "sha256sum /app/products/software_factory/model/targets/rela/atlas.manifest.json" | tr -d '\r' | awk '{print $1}')"
    [ "$packaged" = "$expected" ] || fail "$paired_app has another description composition"
  done
  as rela ssh console -q -a "$rela_app" -C "env ATLAS_RELA_DATA=/data/rela /app/platform/atlas_facts/rela/scripts/description.sh same" || fail 'rela runs another schema closure'
  if [ -n "$empty" ]; then
    removed="$(as rela ssh console -q -a "$rela_app" -C "env ATLAS_RELA_DATA=/data/rela ATLAS_RELA_BIN=/app/bin /app/platform/atlas_facts/rela/scripts/description.sh gc $empty")" ||
      fail "rela's gc did not remove the empty fields $empty: $removed"
    echo "deploy: rela's gc removed the empty fields:"
    echo "$removed" | tr -d '\r' | sed 's/^/  /'
  fi
fi

# 4. The smoke check, as the core's token.
if [ -n "$held" ]; then
  echo "deploy: $env is held; no smoke check. atlas-ops move-to-fly --env $env ends the hold."
else
  if [ -n "${ATLAS_FLY_TOKEN_CORE:-}" ]; then
    FLY_API_TOKEN="$ATLAS_FLY_TOKEN_CORE" "$root/platform/ops/smoke.sh" "$env" "$label"
  else
    "$root/platform/ops/smoke.sh" "$env" "$label"
  fi
fi

if [ "$env" = test ] && [ -z "$held" ] && [[ "$label" =~ ^develop-[0-9a-f]{40}$ ]]; then
  as rela ssh console -q -a "$rela_app" \
    -C "sh -c 'printf \"%s\\n\" \"$label\" > /data/test-deploy-verified.tmp && mv /data/test-deploy-verified.tmp /data/test-deploy-verified'" ||
    fail 'cannot record verified test deployment'
fi
