#!/usr/bin/env bash
# What a rela data folder holds: the number of items per kind (a folder under entities/,
# named by its plural) and of links per relation (files <from>--<relation>--<to>.md under
# relations/). move-to-fly compares the two sides with it; the rela image has it too, so
# Fly's side is counted the same way.
#
#   counts.sh <rela data folder>    "<plural> <count>" per kind, "links <relation> <count>"
#                                   per relation, then "links <count>" in all
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/atlas-counts.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
ATLAS_RELA_BIN="${ATLAS_RELA_BIN:-/app/bin}" bash "$root/platform/atlas_facts/rela/scripts/data.sh" snapshot "$1" "$tmp/snapshot"
cd "$tmp/snapshot/markdown"
for folder in entities/*/; do
  [ -d "$folder" ] || continue
  echo "$(basename "$folder") $(find "$folder" -type f | wc -l | tr -d ' ')"
done
if [ -d relations ]; then
  find relations -type f -name '*--*--*' | sed 's/^.*--\(.*\)--.*$/\1/' | LC_ALL=C sort | uniq -c |
    while read -r count name; do echo "links $name $count"; done
fi
echo "links $(find relations -type f 2>/dev/null | wc -l | tr -d ' ')"
