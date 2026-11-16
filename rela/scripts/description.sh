#!/usr/bin/env bash
# Closure-aware, read-only comparison and compatibility check (IS-Atlas-73/97).
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
root="${ATLAS_TEST_ROOT:-$HOME/.local/share/atlas/test}"
data="${ATLAS_RELA_DATA:-$root/rela}"
bin="${ATLAS_RELA_BIN:-$root/bin}"
case "${1:-}" in
  same) exec "${ATLAS_CONFIG_PYTHON:-python3}" "$here/scripts/config.py" same --root "$here" --data "$data" ;;
  fits)
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/atlas-description.XXXXXX")"
    trap 'rm -rf "$tmp"' EXIT
    "${ATLAS_CONFIG_PYTHON:-python3}" "$here/scripts/verify.py" "$here"
    mkdir "$tmp/proposed"
    "${ATLAS_CONFIG_PYTHON:-python3}" "$here/scripts/config.py" flat --root "$here" >"$tmp/proposed/schema.yaml"
    cp "$here/data-entry.yaml" "$tmp/proposed/"
    ATLAS_RELA_BIN="$bin" bash "$here/scripts/fits.sh" "$tmp/proposed" "$data"
    ;;
  *) echo 'usage: description.sh same|fits' >&2; exit 2 ;;
esac
