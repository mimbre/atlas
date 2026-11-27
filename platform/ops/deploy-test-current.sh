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

echo "deploy: admitted current test build $checkout; completing the whole pair"
exec "$root/platform/ops/deploy.sh" test "$label"
