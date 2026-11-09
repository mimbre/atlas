#!/usr/bin/env bash
# atlas-ops fetch-from-fly: copy an environment's data on Fly to this Mac (IS-Atlas-79): a
# backup, or the copy a migration runs on. bin/atlas-ops runs it for an environment whose
# settings have a "fly" section.
#
#   atlas-ops fetch-from-fly --env test|prod --to <folder> [--hold]
#
#  0. Refuses, changing nothing, when either app already has a hold (/data/hold) or a
#     pending move (/data/incoming/*.tar.gz): a restart would end that hold or apply that move.
#  1. Holds both apps (/data/hold, then a restart; the core first, so nothing writes): the
#     machines stay up but serve nothing, so the copy is whole.
#  2. Copies /data/rela and /data/beam into <folder>/rela and <folder>/beam, the layout
#     move-to-fly and a private instance on this Mac (ATLAS_ENV_FILE) use; counts it.
#  3. Ends the hold and restarts rela, then the core. With --hold they stay held: for a
#     migration on the copy, which `atlas-ops move-to-fly --from <folder>` then brings back
#     (that ends the hold). Until then the environment serves nothing.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd -P)"
app="${ATLAS_FLY_APP:?run through bin/atlas-ops fetch-from-fly}"
rela_app="${ATLAS_FLY_RELA_APP:?run through bin/atlas-ops fetch-from-fly}"
env="${ATLAS_ENV:?run through bin/atlas-ops fetch-from-fly}"
to=""
keep_held=""
while [ $# -gt 0 ]; do
  case "$1" in
    --to) [ -n "${2:-}" ] || { echo "fetch-from-fly: --to needs a folder" >&2; exit 2; }; to="$2"; shift 2 ;;
    --to=?*) to="${1#--to=}"; shift ;;
    --hold) keep_held=1; shift ;;
    *) echo "fetch-from-fly: unknown option $1; see atlas-ops --help" >&2; exit 2 ;;
  esac
done
fail() { echo "fetch-from-fly: $*" >&2; exit 1; }
[ -n "$to" ] || fail "say where to: --to <folder> (a new or empty folder)"
to="${to/#\~/$HOME}"
if [ -e "$to" ] && [ -n "$(ls -A "$to")" ]; then fail "$to is not empty; fetch into a new folder"; fi
fly="$(command -v fly || command -v flyctl)" || fail "install flyctl first (brew install flyctl), then: fly auth login"

remote() { "$fly" ssh console -q -a "$1" -C "$2" 2>/dev/null | tr -d '\r'; }
machine() { "$fly" status -a "$1" --json | jq -r '.Machines[0].id'; }
started() { "$fly" status -a "$1" --json | jq -e '.Machines[0].state == "started"' >/dev/null; }
passing() { "$fly" status -a "$1" --json | jq -e '.Machines[0] | .state == "started" and all(.checks[]?; .status == "passing")' >/dev/null; }
restart() { # app, then: started|passing
  "$fly" machine restart "$(machine "$1")" -a "$1" --skip-health-checks >/dev/null
  for _ in $(seq 1 60); do "$2" "$1" && return 0; sleep 2; done
  fail "$1 did not come back; see: fly logs -a $1"
}

# 0. Refuse, before any hold or restart, when an app already has a hold (a migration's
#    --hold: releasing it here would put that environment back in service mid-migration) or
#    a pending move, /data/incoming/<name>.tar.gz (a restart applies it at boot, before the
#    hold check, and replaces the data there). Both apps are asked; the last line, "checked",
#    shows the answer came whole.
found=""
for target in "$app" "$rela_app"; do
  answer="$(remote "$target" "sh -c 'cd /data && for f in hold incoming/*.tar.gz; do [ -e \$f ] && echo /data/\$f; done; echo checked'" || true)"
  case "$answer" in *checked) ;; *) fail "could not check $target for a hold or a pending move; nothing was held (is it running? atlas-ops status --env $env)" ;; esac
  while IFS= read -r path; do
    case "$path" in
      checked|"") ;;
      */hold) found="$found
  $target holds $path: a hold is in place (a migration under way?); end it with its move-to-fly first" ;;
      *) found="$found
  $target has $path: a pending move, which a restart would apply; finish that move first" ;;
    esac
  done <<<"$answer"
done
[ -z "$found" ] || fail "refusing to hold $env, nothing was changed:$found"

# 1. Hold: the core first, so nothing writes to rela while it is copied.
for target in "$app" "$rela_app"; do
  echo "Holding $target"
  remote "$target" "touch /data/hold" >/dev/null
  restart "$target" started
done
# A restarted machine runs its start script again; held, that is a sleep. Give it a moment.
sleep 3
for target in "$app" "$rela_app"; do
  remote "$target" "test -e /data/hold" >/dev/null || fail "$target is not held"
done

# 2. Copy.
mkdir -p "$to"
for pair in "$rela_app:rela" "$app:beam"; do
  target="${pair%%:*}" name="${pair##*:}"
  remote "$target" "tar -czf /tmp/$name.tar.gz -C /data/$name ." >/dev/null
  "$fly" ssh sftp get -a "$target" "/tmp/$name.tar.gz" "$to/$name.tar.gz" >/dev/null
  remote "$target" "rm -f /tmp/$name.tar.gz" >/dev/null
  mkdir -p "$to/$name"
  tar -xzf "$to/$name.tar.gz" -C "$to/$name"
  rm -f "$to/$name.tar.gz"
  echo "Copied $target:/data/$name to $to/$name ($(find "$to/$name" -type f | wc -l | tr -d ' ') files)"
done
echo "What it holds:"
"$root/fly/counts.sh" "$to/rela" | sed 's/^/  /'

# 3. Release, or keep held for a migration.
if [ -n "$keep_held" ]; then
  echo "$env on Fly stays held: it serves nothing until atlas-ops move-to-fly --env $env --from <migrated folder>."
  exit 0
fi
for target in "$rela_app" "$app"; do
  echo "Releasing $target"
  remote "$target" "rm -f /data/hold" >/dev/null
  restart "$target" passing
done
echo "$env on Fly serves again."
