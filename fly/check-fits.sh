#!/usr/bin/env bash
# Old-image preflight receives the proposed flat description and shared native helpers.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
data="${ATLAS_RELA_DATA:-${ATLAS_TEST_ROOT:-$HOME/.local/share/atlas/test}/rela}"
export ATLAS_RELA_BIN="${ATLAS_RELA_BIN:-${ATLAS_TEST_ROOT:-$HOME/.local/share/atlas/test}/bin}"
case "${1:-}" in
  same) cmp -s "$here/schema.yaml" "$data/schema.yaml" && cmp -s "$here/data-entry.yaml" "$data/data-entry.yaml" ;;
  fits) exec bash "$here/scripts/fits.sh" "$here" "$data" ;;
  *) echo 'usage: description.sh same|fits' >&2; exit 2 ;;
esac
