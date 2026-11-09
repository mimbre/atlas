#!/usr/bin/env bash
# Capture or explicitly recover the one-machine image/config pair. No data copies.
set -euo pipefail
mode="${1:?capture|recover}"
record="${2:?protected recovery directory}"
fail() { echo "image-pair: $*" >&2; exit 1; }
fly_bin="$(command -v flyctl || command -v fly)"
as() {
  local side="$1" token
  shift
  if [ "$side" = rela ]; then token="${ATLAS_FLY_TOKEN_RELA:-}"; else token="${ATLAS_FLY_TOKEN_CORE:-}"; fi
  if [ -n "$token" ]; then FLY_API_TOKEN="$token" "$fly_bin" "$@"; else "$fly_bin" "$@"; fi
}
immutable() {
  jq -er 'if length == 1 then .[0].image_ref else error("require exactly one machine") end |
    select(.registry != null and .repository != null and (.digest | test("^sha256:[0-9a-f]{64}$"))) |
    .registry + "/" + .repository + "@" + .digest' "$1"
}
case "$mode" in
  capture)
    env="${3:?environment}"; core="${4:?core app}"; rela="${5:?rela app}"
    [ ! -e "$record" ] || fail "record already exists; refusing to overwrite"
    umask 077
    mkdir "$record"
    for side in rela core; do
      if [ "$side" = rela ]; then app="$rela"; else app="$core"; fi
      as "$side" machine list -a "$app" --json > "$record/$side.json"
      immutable "$record/$side.json" > "$record/$side.image" || fail "no immutable $side image; nothing deployable captured"
      jq -er '.[0].id' "$record/$side.json" > "$record/$side.id"
      jq -e '.[0].config | objects' "$record/$side.json" > "$record/$side.config.json"
      printf '%s\n' "$app" > "$record/$side.app"
    done
    printf '%s\n' "$env" > "$record/environment"
    printf 'pre-deploy\n' > "$record/phase"
    ;;
  recover)
    [ "${ATLAS_RECOVERY_COMPATIBLE:-}" = 1 ] || fail "verify previous pair against current authoritative data and held clients; set ATLAS_RECOVERY_COMPATIBLE=1 only after review"
    [ -x "${ATLAS_RECOVERY_SMOKE:-}" ] || fail "ATLAS_RECOVERY_SMOKE must name a held-client/proxy reachability check"
    [ -s "$record/environment" ] || fail "incomplete capture"
    # Refuse replaced/multiple machines instead of guessing ownership.
    for side in rela core; do
      app="$(cat "$record/$side.app")"
      as "$side" machine list -a "$app" --json > "$record/$side.current.json"
      [ "$(jq -er 'if length == 1 then .[0].id else empty end' "$record/$side.current.json")" = "$(cat "$record/$side.id")" ] || fail "machine changed: $app; keep client holds and recover manually"
      [ "$(immutable "$record/$side.json")" = "$(cat "$record/$side.image")" ] || fail "invalid saved image"
      jq -S '.[0].config.mounts // [] | sort_by(.path)' "$record/$side.json" > "$record/$side.saved-mounts.json"
      jq -S '.[0].config.mounts // [] | sort_by(.path)' "$record/$side.current.json" > "$record/$side.current-mounts.json"
      cmp -s "$record/$side.saved-mounts.json" "$record/$side.current-mounts.json" || fail "data mounts changed: $app; refusing to reattach a previous volume"
    done
    # Quiesce candidate writes before restoring a compatible server pair. Volumes,
    # their current authority, and tailnet node state are never reverted.
    as core machine stop "$(cat "$record/core.id")" -a "$(cat "$record/core.app")"
    for side in rela core; do
      app="$(cat "$record/$side.app")"
      as "$side" machine update "$(cat "$record/$side.id")" -a "$app" \
        --machine-config "$record/$side.config.json" --image "$(cat "$record/$side.image")" --yes
      as "$side" machine list -a "$app" --json > "$record/$side.restored.json"
      [ "$(immutable "$record/$side.restored.json")" = "$(cat "$record/$side.image")" ] || fail "$app restoration unverified; keep client holds"
      jq -e '.[0].state == "started"' "$record/$side.restored.json" >/dev/null || fail "$app is not started"
    done
    "$ATLAS_RECOVERY_SMOKE" "$(cat "$record/environment")" || fail "held-client reachability failed; keep holds and proxy configuration"
    printf 'recovered-and-checked\n' > "$record/phase"
    echo "image-pair: previous pair reachable; client holds remain for explicit release"
    ;;
  *) fail "expected capture or recover" ;;
esac
