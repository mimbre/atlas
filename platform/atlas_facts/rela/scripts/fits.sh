#!/usr/bin/env bash
# One check against the resolved flat description, locally and on an old image.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
proposed="${1:?usage: fits.sh PROPOSED DATA}"
data="${2:?data folder required}"
bin="${ATLAS_RELA_BIN:?fits: ATLAS_RELA_BIN must name the pinned tools}"
bin="$(cd "$bin" && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/atlas-fits.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
bash "$here/data.sh" snapshot "$data" "$tmp/snapshot"
mkdir "$tmp/check"
cp "$proposed/schema.yaml" "$proposed/data-entry.yaml" "$tmp/check/"
# Proposed is configuration only; data comes solely from the successful snapshot.
for part in entities relations attachments; do
  if [ -d "$tmp/snapshot/markdown/$part" ]; then cp -R "$tmp/snapshot/markdown/$part" "$tmp/check/"; fi
done
"$bin/rela" --project "$tmp/check" --quiet validate
"$bin/rela" --project "$tmp/check" --quiet migrate gc --scan >"$tmp/scan"
sed -n 's/^  \([A-Za-z0-9_.-]*\)$/\1/p' "$tmp/scan" >"$tmp/fields"
: >"$tmp/orphans"
# A removed field holding nothing (null, ~, "" or '' in every entity that has it) does
# not block: after the deploy, deploy.sh has rela's own `migrate gc` remove it. Any real
# value, or an orphan no entity file shows, still blocks.
while IFS= read -r orphan; do
  held=""
  case "$orphan" in
    ?*.?*) held="$(find "$tmp/check/entities" -type f -name '*.md' -exec awk -v q="'" \
      -v kind="${orphan%%.*}" -v field="${orphan#*.}" '
      function flush() {
        if (type == kind && found) print (value == "" || value == "null" || value == "~" || value == "\"\"" || value == q q) ? "empty" : "value"
      }
      FNR == 1 { flush(); fence = 0; type = ""; found = 0; open = 0 }
      /^---[[:space:]]*$/ { fence++; next }
      fence != 1 { next }
      open && /^[[:space:]]+[^[:space:]]/ { value = "nested" }
      { open = 0 }
      /^type:/ { type = $0; sub(/^type:[[:space:]]*/, "", type); sub(/[[:space:]]+$/, "", type); gsub(/["\047]/, "", type) }
      index($0, field ":") == 1 {
        found = 1; value = substr($0, length(field) + 2)
        sub(/^[[:space:]]+/, "", value); sub(/[[:space:]]+$/, "", value)
        if (value == "" || value == "|" || value == ">") open = 1
      }
      END { flush() }' {} + | sort -u | tr '\n' ' ')" ;;
  esac
  if [ "$held" = "empty " ]; then
    echo "$orphan (empty, removed after deploy)" >>"$tmp/empty"
  else
    echo "$orphan" >>"$tmp/orphans"
  fi
done <"$tmp/fields"
# The proposed schema is config.py's resolved flat YAML, also used by old images
# without Python/jq. Native validation/GC handles fields; these checks additionally
# catch populated kinds and relations which the new schema would not load at all.
for folder in "$tmp/check/entities"/*/; do
  [ -d "$folder" ] && [ -n "$(find "$folder" -type f -print -quit)" ] || continue
  name="$(basename "$folder")"
  if ! grep -Fxq "    plural: $name" "$tmp/check/schema.yaml" &&
     ! grep -Fxq "    plural: \"$name\"" "$tmp/check/schema.yaml" &&
     ! grep -Fxq "    plural: '$name'" "$tmp/check/schema.yaml"; then
    echo "$name (a kind this build has no more)" >>"$tmp/orphans"
  fi
done
# Canonical names and inverse IDs belong to relations, not same-named entities/types.
sed -n '/^relations:$/,/^[^[:space:]#]/{
  /^relations:$/d
  /^[^[:space:]#]/d
  p
}' "$tmp/check/schema.yaml" >"$tmp/relations"
find "$tmp/check/relations" -type f -name '*.md' >"$tmp/relation-files"
while IFS= read -r file; do
  name="$(basename "$file" | sed -n 's/^.*--\([A-Za-z0-9_-]*\)--.*\.md$/\1/p')"
  [ -n "$name" ] || continue
  if ! grep -Fxq "  $name:" "$tmp/relations" &&
     ! grep -Fxq "  '$name':" "$tmp/relations" &&
     ! grep -Fxq "  \"$name\":" "$tmp/relations" &&
     ! grep -Fxq "      id: $name" "$tmp/relations" &&
     ! grep -Fxq "      id: \"$name\"" "$tmp/relations" &&
     ! grep -Fxq "      id: '$name'" "$tmp/relations"; then
    echo "$name (a relation this build has no more)" >>"$tmp/orphans"
  fi
done <"$tmp/relation-files"
if [ -s "$tmp/orphans" ]; then sort -u "$tmp/orphans"; [ ! -s "$tmp/empty" ] || sort -u "$tmp/empty"; exit 1; fi
"$bin/rela" --project "$tmp/check" --quiet validate --check=all
[ ! -s "$tmp/empty" ] || sort -u "$tmp/empty"
