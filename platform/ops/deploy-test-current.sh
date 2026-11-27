#!/usr/bin/env bash
# CI calls this only after acquiring the whole-pair fly-deploy-test slot.
# Admission is checked once; a head arriving afterward must not interrupt rela/core.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd -P)"
label="${1:?usage: deploy-test-current.sh develop-<full checkout SHA>}"
fail() { echo "deploy: test admission failed: $*" >&2; exit 1; }

checkout="$(git -C "$root" rev-parse --verify HEAD)" || fail 'cannot identify checkout'
[[ "$checkout" =~ ^[0-9a-f]{40}$ ]] || fail 'invalid checkout identity'
[ "$label" = "develop-$checkout" ] || fail 'build label does not identify this checkout'

# Use the checkout's existing read credentials.
remote="$(git -C "$root" ls-remote --exit-code origin refs/heads/develop)" ||
  fail 'cannot resolve current origin/develop'
[[ "$remote" =~ ^([0-9a-f]{40})[[:space:]]refs/heads/develop$ ]] ||
  fail 'ambiguous or invalid origin/develop identity'
current="${BASH_REMATCH[1]}"

if [ "$checkout" != "$current" ]; then
  echo "deploy: skipping stale test build $checkout; current develop is $current"
  exit 0
fi

# A push-relative filter loses changes when an older job was skipped as stale.
# Compare both deployed images inside the same slot, not against the previous push.
settings="$root/products/software_factory/environments/test.json"
fly_bin="$(command -v flyctl || command -v fly)" || fail 'flyctl not found'
app="$(jq -er .fly.app "$settings")" || fail 'cannot identify test core app'
rela_app="$(jq -er .fly.rela_app "$settings")" || fail 'cannot identify test rela app'
core_status="$(FLY_API_TOKEN="${ATLAS_FLY_TOKEN_CORE:?}" "$fly_bin" status -a "$app" --json)" ||
  fail 'cannot read test core status'
rela_status="$(FLY_API_TOKEN="${ATLAS_FLY_TOKEN_RELA:?}" "$fly_bin" status -a "$rela_app" --json)" ||
  fail 'cannot read test rela status'
core_tag="$(jq -er 'if (.Machines | type) == "array" then [.Machines[].image_ref.tag // ""] | unique | if length == 1 then .[0] else "" end else error("invalid Machines") end' <<<"$core_status")" ||
  fail 'invalid test core status'
rela_tag="$(jq -er 'if (.Machines | type) == "array" then [.Machines[].image_ref.tag // ""] | unique | if length == 1 then .[0] else "" end else error("invalid Machines") end' <<<"$rela_status")" ||
  fail 'invalid test rela status'
if [ "$core_tag" = "$rela_tag" ] && [[ "$core_tag" =~ ^develop-([0-9a-f]{40})$ ]]; then
  deployed="${BASH_REMATCH[1]}"
  verified="$(FLY_API_TOKEN="${ATLAS_FLY_TOKEN_RELA:?}" "$fly_bin" ssh console -q -a "$rela_app" \
    -C "sh -c 'if [ -f /data/test-deploy-verified ]; then cat /data/test-deploy-verified; fi'")" ||
    fail 'cannot read verified test deployment evidence'
  verified="${verified//$'\r'/}"
  if [ "$verified" = "$core_tag" ] && git -C "$root" cat-file -e "$deployed^{commit}" 2>/dev/null; then
    changed="$(git -C "$root" diff --no-renames --name-only "$deployed" "$checkout")" ||
      fail 'cannot compare deployed and tested trees'
    if ! printf '%s\n' "$changed" | grep -qvE '^($|docs/|skills/|platform/clients/apple/|\.github/)|\.md$'; then
      echo "deploy: test already has the Fly-relevant tree of $checkout ($deployed)"
      exit 0
    fi
  fi
fi

echo "deploy: admitted current test build $checkout; completing the whole pair"
exec "$root/platform/ops/deploy.sh" test "$label"
