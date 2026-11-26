#!/usr/bin/env bash
# Closure-aware, read-only comparison and compatibility check (IS-Atlas-73/97).
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
# The Rela project the scripts serve: the product's generated description (bin/generate model
# writes it; it is not kept in git).
project="$here/../../../products/software_factory/model/targets/rela"
root="${ATLAS_TEST_ROOT:-$HOME/.local/share/atlas/test}"
data="${ATLAS_RELA_DATA:-$root/rela}"
bin="${ATLAS_RELA_BIN:-$root/bin}"
case "${1:-}" in
  same) exec "${ATLAS_CONFIG_PYTHON:-python3}" "$here/scripts/config.py" same --root "$project" --data "$data" ;;
  fits)
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/atlas-description.XXXXXX")"
    trap 'rm -rf "$tmp"' EXIT
    "${ATLAS_CONFIG_PYTHON:-python3}" "$here/scripts/verify.py" "$project"
    mkdir "$tmp/proposed"
    "${ATLAS_CONFIG_PYTHON:-python3}" "$here/scripts/config.py" flat --root "$project" >"$tmp/proposed/schema.yaml"
    cp "$project/data-entry.yaml" "$tmp/proposed/"
    ATLAS_RELA_BIN="$bin" bash "$here/scripts/fits.sh" "$tmp/proposed" "$data"
    ;;
  gc)
    # After a deploy or move: rela's own gc removes the removed fields `fits` reported
    # empty (the arguments, kind.field), and only those; any other orphan stops it.
    shift
    rela="$bin/rela"
    [ ! -e "$data/.rela/rela.db" ] || rela="$bin/rela-sqlite"
    cd "$data" && unset RELA_PROJECT
    pending="$("$rela" --project "$data" --quiet migrate gc --scan | sed -n 's/^pending \([^ ]*\) .*$/\1/p' | sort -u)"
    expected="$(printf '%s\n' "$@" | sed '/^$/d' | sort -u)"
    if [ "$pending" != "$expected" ]; then
      echo "description: rela holds other orphans than the empty fields ${*:-(none)}; nothing removed:" >&2
      echo "$pending" >&2
      exit 1
    fi
    [ -z "$pending" ] || "$rela" --project "$data" --quiet migrate gc --apply --grace=1ns
    ;;
  *) echo 'usage: description.sh same|fits|gc [kind.field...]' >&2; exit 2 ;;
esac
