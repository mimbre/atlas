#!/usr/bin/env bash
# A private markdown view for compatibility/counting; never a replacement store.
set -euo pipefail
operation="${1:?usage: data.sh present|snapshot DATA [DEST]}"
data="${2:?data folder required}"
case "$operation" in
  present)
    # Matches upstream KeepsMarkdownData: an existing database wins, even beside markdown.
    if [ -e "$data/.rela/rela.db" ] || [ -L "$data/.rela/rela.db" ]; then exit 0; fi
    for part in entities relations; do
      if [ -d "$data/$part" ]; then
        found="$(find "$data/$part" ! -type d -print -quit)" || exit 2
        [ -z "$found" ] || exit 0
      fi
    done
    exit 1
    ;;
  snapshot) ;;
  *) echo "data: unknown command $operation" >&2; exit 2 ;;
esac
dest="${3:?new snapshot folder required}"
[ -d "$data" ] || { echo "data: missing source $data" >&2; exit 1; }
[ ! -e "$dest" ] || { echo "data: snapshot destination already exists: $dest" >&2; exit 1; }
mkdir "$dest"
dest="$(cd "$dest" && pwd)"
if [ -e "$data/.rela/rela.db" ] || [ -L "$data/.rela/rela.db" ]; then
  [ -f "$data/.rela/rela.db" ] && [ -r "$data/.rela/rela.db" ] || { echo "data: unreadable SQLite source" >&2; exit 1; }
  command -v sqlite3 >/dev/null || { echo "data: sqlite3 is required (macOS system tool; Linux package sqlite3)" >&2; exit 1; }
  bin="${ATLAS_RELA_BIN:?data: ATLAS_RELA_BIN must name the pinned tools}"
  bin="$(cd "$bin" && pwd)"
  [ -x "$bin/rela-sqlite" ] || { echo "data: missing pinned rela-sqlite in $bin" >&2; exit 1; }
  private="$dest/original"
  mkdir "$private" "$private/.rela"
  # Only original project configuration. In particular, never copy live DB/WAL/SHM.
  tar -C "$data" --exclude='./.rela' --exclude='./entities' --exclude='./relations' --exclude='./attachments' -cf - . |
    tar -C "$private" -xf -
  backup="$private/.rela/rela.db"
  quoted="${backup//\\/\\\\}"
  quoted="${quoted//\"/\\\"}"
  printf '.timeout 5000\n.backup "%s"\n' "$quoted" | sqlite3 -bail -readonly "$data/.rela/rela.db"
  [ -s "$backup" ] || { echo "data: SQLite backup produced no database" >&2; exit 1; }
  # db dump discovers cwd; --project alone is not honored by the published CLI.
  # Export only the coherent private backup, with its ORIGINAL layered description.
  (cd "$private" && unset RELA_PROJECT && "$bin/rela-sqlite" db dump "$dest/markdown" --data) >&2
  [ -d "$dest/markdown" ] || { echo "data: native export produced no directory" >&2; exit 1; }
else
  mkdir "$dest/markdown"
  for part in entities relations attachments; do
    if [ -d "$data/$part" ]; then cp -R "$data/$part" "$dest/markdown/"; fi
  done
fi
# Empty successful exports need not contain either directory.
for part in entities relations; do
  [ -d "$dest/markdown/$part" ] || mkdir "$dest/markdown/$part"
done
