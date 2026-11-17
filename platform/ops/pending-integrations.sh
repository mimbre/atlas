#!/usr/bin/env bash
# pending-integrations: before a deploy that changes `code.repositories`, list the integrate
# requests in Code's journal (`<code.data>/effects/<id>.json`, AtlasCode.Effects) that are
# not finished yet for one repository. Once a repository leaves the allow-list, these stay
# `working` with no GitHub call until it is allowed again, so settle them first, or keep the
# repository in the list for now (docs/guides/prod.md, "Before changing code.repositories").
#
# It only reports. On Fly it runs one read-only command over `fly ssh console`
# (cd, test, printf, cat), like fetch-from-fly's checks; it writes, holds or restarts nothing.
#
#   pending-integrations.sh [--repository owner/repo] [--app <fly app>] [--data <dir>]
#   pending-integrations.sh --journal <local effects folder> [--repository owner/repo]
#
#   --repository  the repository to look for (default eyra/atlas, the one leaving prod)
#   --app         the core's Fly app (default: "fly"."app" of environments/prod.json)
#   --data        code.data on that app (default /data/code)
#   --journal     read a local copy of an effects folder instead of Fly (a dry run)
#
# Exit 0: none unfinished. 1: some are unfinished (listed). 2: usage, or the journal could
# not be read whole.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd -P)"
repository="eyra/atlas"
app=""
data="/data/code"
journal=""
fail() { echo "pending-integrations: $*" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --repository|--app|--data|--journal)
      [ -n "${2:-}" ] || fail "$1 needs a value"
      case "$1" in
        --repository) repository="$2" ;; --app) app="$2" ;; --data) data="$2" ;; --journal) journal="$2" ;;
      esac
      shift 2 ;;
    -h|--help) sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) fail "unknown option $1; see --help" ;;
  esac
done
[[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "--repository must be owner/repo"
[[ "$data" =~ ^/[A-Za-z0-9_./-]*$ ]] || fail "--data must be an absolute path"

# Prints "missing" when there is no journal, else one line per record, "<file> <json>",
# then "checked", so a cut-off answer is told from an empty journal. Reads only, and has no
# single quote, so it goes inside sh -c '...' as fetch-from-fly's checks do.
listing() {
  echo "cd $1 2>/dev/null || { echo missing; echo checked; exit 0; }; for f in *.json; do [ -f \"\$f\" ] && { printf \"%s \" \"\$f\"; cat \"\$f\"; echo; }; done; echo checked"
}

if [ -n "$journal" ]; then
  [ -d "$journal" ] || fail "$journal is no folder"
  source_name="$journal"
  dir="$(cd "$journal" && pwd -P)"
  [[ "$dir" =~ ^/[A-Za-z0-9_./-]*$ ]] || fail "$dir: use a path of letters, digits and _ . / - only"
  answer="$(sh -c "$(listing "$dir")")"
else
  if [ -z "$app" ]; then
    app="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["fly"]["app"])' \
      "$root/products/software_factory/environments/prod.json")" || fail "no fly.app in environments/prod.json; pass --app"
  fi
  fly="$(command -v fly || command -v flyctl)" || fail "install flyctl first (brew install flyctl), then: fly auth login"
  source_name="$app:$data/effects"
  answer="$("$fly" ssh console -q -a "$app" -C "sh -c '$(listing "$data/effects")'" 2>/dev/null | tr -d '\r')" ||
    fail "could not read $source_name (is it running? fly status -a $app)"
fi

printf '%s\n' "$answer" | python3 -I -c '
import json, re, sys
repository, source = sys.argv[1], sys.argv[2]
lines = sys.stdin.read().splitlines()
if not lines or lines[-1] != "checked":
    print(f"pending-integrations: the answer from {source} was cut off; nothing can be said", file=sys.stderr)
    sys.exit(2)
lines = [l for l in lines[:-1] if l.strip()]
if lines == ["missing"]:
    print(f"pending-integrations: {source}: no journal; 0 unfinished integrate requests for {repository}")
    sys.exit(0)
address = re.compile(r"\Ahttps://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/pull/([0-9]+)\Z")
pending, unreadable, others = [], [], 0
for line in lines:
    name, _, body = line.partition(" ")
    try:
        record = json.loads(body)
        request = record["request"]
    except (ValueError, KeyError, TypeError):
        unreadable.append(name)
        continue
    match = address.match(str(request.get("target", "")))
    slug = f"{match.group(1)}/{match.group(2)}" if match else None
    if "outcome" in record or request.get("operation") != "integrate" or slug != repository:
        others += 1
        continue
    line_heads = record.get("line") or []
    pending.append({
        "id": request.get("id", name.removesuffix(".json")),
        "phase": record.get("phase"),
        "merge_attempted": record.get("merge_attempted", record.get("phase") == "merging"),
        "run": request.get("run"),
        "subject": request.get("subject"),
        "target": request.get("target"),
        "head": line_heads[-1] if line_heads else None,
    })
print(f"pending-integrations: {source}: {len(pending)} unfinished integrate request(s) for {repository}"
      f" ({others} other record(s) finished or for other repositories, {len(unreadable)} unreadable)")
for p in sorted(pending, key=lambda p: (str(p["run"]), str(p["id"]))):
    print("  " + "  ".join(f"{k}={p[k]}" for k in ["id", "phase", "merge_attempted", "run", "subject", "target", "head"]))
for name in unreadable:
    print(f"  unreadable {name}: check it by hand", file=sys.stderr)
sys.exit(2 if unreadable else 1 if pending else 0)
' "$repository" "$source_name"
