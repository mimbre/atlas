#!/usr/bin/env bash
# atlas-ops move-to-fly: copy an environment's data from this Mac to its apps on Fly
# (IS-Atlas-26, IS-Atlas-79). bin/atlas-ops runs it for an environment whose settings have a
# "fly" section.
#
#   atlas-ops move-to-fly --env test|prod [--from <folder>] [--dry-run] [--replace-live]
#
# <folder> holds rela/ (rela's data folder) and beam/ (Facts' own data), as
# ~/.local/share/atlas/<env> does; by default the folder in the settings' fly.move_from.
# Point --from at a backup of it to move from the backup.
#
#  1. Checks, and sends nothing when one fails: rela/ and beam/ are there; no rela serves
#     rela/ right now (a copy of a store in use can catch a half-written file); this build's
#     description describes all of its data (what `atlas-ops restart` checks too); and counts
#     the items per kind and the links per relation (every Assignment, every accepted_by).
#  2. Sends rela/ to the rela app and beam/ to the core app, as /data/incoming/<name>.tar.gz.
#  3. Restarts both machines, rela first. At boot fly/apply-move.sh moves what was there
#     to /data/before-move/<time>-<name> (kept), puts the copy in its place, writes the
#     manifest of what arrived (fly/manifest.sh: every file and its SHA-256), and ends a
#     hold (atlas-ops fetch-from-fly --hold).
#  4. Compares, item by item: the manifests on Fly with those of what was sent, for rela/
#     and beam/, and the counts on Fly with step 1.
#
# --dry-run does step 1, shows what Fly holds now, and sends nothing. When the
# environment's clients already use Fly ("in_use" is not false), Fly's data is the live
# one, and a real run needs --replace-live.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd -P)"
app="${ATLAS_FLY_APP:?run through bin/atlas-ops move-to-fly}"
rela_app="${ATLAS_FLY_RELA_APP:?run through bin/atlas-ops move-to-fly}"
env="${ATLAS_ENV:?run through bin/atlas-ops move-to-fly}"
from="${ATLAS_MOVE_FROM:-}"
dry=""
replace_live=""
while [ $# -gt 0 ]; do
  case "$1" in
    --from) [ -n "${2:-}" ] || { echo "move-to-fly: --from needs a folder" >&2; exit 2; }; from="$2"; shift 2 ;;
    --from=?*) from="${1#--from=}"; shift ;;
    --dry-run) dry=1; shift ;;
    --replace-live) replace_live=1; shift ;;
    *) echo "move-to-fly: unknown option $1; see atlas-ops --help" >&2; exit 2 ;;
  esac
done
fail() { echo "move-to-fly: $*" >&2; exit 1; }
if [ -z "$dry" ] && [ "${ATLAS_FLY_IN_USE:-true}" != false ] && [ -z "$replace_live" ]; then
  fail "$env's clients use Fly, so its data there is the live one; to replace it (it is kept in /data/before-move), add --replace-live"
fi
from="${from/#\~/$HOME}"
[ -n "$from" ] && [ -d "$from" ] || fail "no folder to move from ($from)"
from="$(cd "$from" && pwd -P)"

echo "From:  $from (this Mac)"
echo "To:    $rela_app (rela/) and $app (beam/), on Fly"
echo

# 1. Checks.
[ -d "$from/rela/entities" ] || fail "$from/rela has no rela data (no entities/)"
[ -d "$from/beam" ] || fail "$from/beam is missing: Facts' own data (who set each link, which facts were answered) moves too"

serving="$(pgrep -fl "rela-server -project $from/rela( |$)" 2>/dev/null || true)"
if [ -n "$serving" ]; then
  pid="${serving%% *}"
  if [ -z "$dry" ]; then
    fail "a rela still serves $from/rela (pid $pid); stop it first, or move from a backup with --from"
  fi
  echo "Note:  a rela still serves $from/rela (pid $pid); a real run refuses until it is stopped, or use --from <backup>"
fi

# The pinned rela, for the description check; installed in the clients' folder (fly.local).
bin="${ATLAS_FLY_LOCAL:?}/bin"
ATLAS_RELA_BIN="$bin" "$root/rela/scripts/start-test.sh" install >&2
if ! orphans="$(ATLAS_RELA_DATA="$from/rela" ATLAS_RELA_BIN="$bin" "$root/rela/scripts/description.sh" fits)"; then
  echo "move-to-fly: this build's description no longer describes data in $from/rela:" >&2
  echo "$orphans" | sed 's/^/  /' >&2
  fail "migrate that data first, on this Mac, then move it"
fi
echo "Check: this build's description describes all of it"

here="$("$root/fly/counts.sh" "$from/rela")"

# The checks above are this Mac's; from here on it talks to Fly.
fly="$(command -v fly || command -v flyctl)" || fail "install flyctl first (brew install flyctl), then: fly auth login"
remote() { "$fly" ssh console -q -a "$1" -C "$2" 2>/dev/null | tr -d '\r'; }
there="$(remote "$rela_app" "/app/fly/counts.sh /data/rela" || echo "(could not read: is $rela_app running? atlas-ops status)")"
echo
echo "Here, to send:"
echo "$here" | sed 's/^/  /'
echo "On Fly now (a real run keeps it there in /data/before-move):"
echo "$there" | sed 's/^/  /'
echo

if [ -n "$dry" ]; then
  echo "Dry run: nothing sent. A real run sends this, restarts $rela_app and $app, and checks every file and count."
  exit 0
fi

# 2. Send. A half-sent archive is never applied: it is renamed only once complete. What is
# sent is unpacked here too, for the manifests to compare with.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
for name in rela beam; do
  COPYFILE_DISABLE=1 tar -czf "$tmp/$name.tar.gz" --exclude '*.log' --exclude '*.pid' -C "$from/$name" .
  mkdir -p "$tmp/sent/$name"
  tar -xzf "$tmp/$name.tar.gz" -C "$tmp/sent/$name"
  "$root/fly/manifest.sh" "$tmp/sent/$name" >"$tmp/$name.manifest"
done
send() { # app name
  echo "Sending $2/ to $1 ($(du -h "$tmp/$2.tar.gz" | cut -f1 | tr -d ' '), $(wc -l <"$tmp/$2.manifest" | tr -d ' ') files)"
  "$fly" ssh console -q -a "$1" -C "mkdir -p /data/incoming" >/dev/null
  "$fly" ssh sftp put -a "$1" "$tmp/$2.tar.gz" "/data/incoming/$2.tar.gz.part" >/dev/null
  "$fly" ssh console -q -a "$1" -C "mv /data/incoming/$2.tar.gz.part /data/incoming/$2.tar.gz" >/dev/null
}
send "$rela_app" rela
send "$app" beam

# 3. Restart, rela first, so the core starts on the moved data.
machine() { "$fly" status -a "$1" --json | jq -r '.Machines[0].id'; }
passing() { "$fly" status -a "$1" --json | jq -e '.Machines[0] | .state == "started" and all(.checks[]?; .status == "passing")' >/dev/null; }
for target in "$rela_app" "$app"; do
  echo "Restarting $target"
  "$fly" machine restart "$(machine "$target")" -a "$target" --skip-health-checks >/dev/null
  for _ in $(seq 1 60); do passing "$target" && break; sleep 2; done
  passing "$target" || fail "$target did not come back; see: fly logs -a $target"
done

# 4. Compare: every file, then the counts.
problems=""
for pair in "$rela_app:rela" "$app:beam"; do
  target="${pair%%:*}" name="${pair##*:}"
  remote "$target" "cat /data/$name.manifest" >"$tmp/$name.arrived"
  if cmp -s "$tmp/$name.manifest" "$tmp/$name.arrived"; then
    echo "Check: every file of $name/ arrived as sent ($(wc -l <"$tmp/$name.manifest" | tr -d ' ') files, SHA-256)"
  else
    echo "move-to-fly: $name/ on $target differs from what was sent:" >&2
    diff "$tmp/$name.manifest" "$tmp/$name.arrived" | head -20 >&2 || true
    problems=1
  fi
done
there="$(remote "$rela_app" "/app/fly/counts.sh /data/rela")"
if [ "$here" = "$there" ]; then
  echo "Check: the counts per kind and per relation on Fly are the ones sent:"
  echo "$there" | sed 's/^/  /'
else
  echo "move-to-fly: the counts on Fly differ from the ones sent:" >&2
  diff <(echo "$here") <(echo "$there") >&2 || true
  problems=1
fi
[ -z "$problems" ] || fail "the earlier data on Fly is in /data/before-move on both apps"

echo "Moved. The earlier data on Fly is in /data/before-move."
if [ "${ATLAS_FLY_IN_USE:-true}" = false ]; then
  echo "$env's clients still use this Mac's core. Switch them once you have checked the move:"
  echo "  configure the verified full Control hostname and required TLS, then set fly.in_use=true; docs/guides/private-transport.md (no live cutover without approval)"
fi
