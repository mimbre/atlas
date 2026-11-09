#!/usr/bin/env bash
# Check that the Atlas test rela answers for every entity described so far:
# create, read, list, update, delete each item type, and link each child to
# its parent. Uses fresh codes per run (a deleted code stays reserved for
# rela's undo window) and deletes what it made.
#
#   check.sh                 # against http://127.0.0.1:7690
# This standalone backend probe writes Rela directly and does not notify Facts.
# Use a disposable store with Facts stopped. If Facts is running, its copies may
# retain these changes until the configured freshness bound (normally five seconds).
set -euo pipefail

url="${ATLAS_RELA_URL:-http://127.0.0.1:${ATLAS_RELA_PORT:-7690}}/api/v1"
run="$(date +%s)"
json='Content-Type: application/json'
fail() { echo "FAIL: $*" >&2; exit 1; }
status() { curl -sS -o /dev/null -w '%{http_code}' "$@"; }
etag() { curl -sS -D - -o /dev/null "$url/$1/$2" | awk -F': ' 'tolower($1)=="etag"{print $2}' | tr -d '\r'; }
create() { # plural id properties-json [relations-json]
  [ "$(status -X POST "$url/$1" -H "$json" -d "{\"id\":\"$2\",\"properties\":$3${4:+,\"relations\":$4}}")" = 201 ] || fail "create $2"
}
link() { # plural id relation target-type target-id...
  local plural=$1 id=$2 rel=$3 type=$4; shift 4
  local data="" t; for t in "$@"; do data="$data${data:+,}{\"type\":\"$type\",\"id\":\"$t\"}"; done
  status -X PATCH "$url/$plural/$id" -H "$json" -d "{\"relations\":{\"$rel\":{\"data\":[$data]}}}"
}
children() { # parent-plural parent-id relation  -> ids of children, one per line
  curl -sS "$url/$1/$2/relations/$3?direction=incoming" | python3 -c 'import json,sys; [print(r["id"]) for r in json.load(sys.stdin)]'
}

[ "$(status "$url/_schema")" = 200 ] || fail "rela does not answer at $url"
echo "ok   answers at $url"

# An item with a required field and a state-like enum field. Same checks for
# every such type.
check_item() { # plural prefix required-field value enum-field first-value second-value
  local plural=$1 code="$2Check-$run" req=$3 val=$4 field=$5 v1=$6 v2=$7
  curl -sS "$url/_schema" | grep -q "\"plural\":\"$plural\"" || fail "description has no $plural"

  local dry; dry="$(curl -sS -X POST "$url/$plural?dry_run=true" -H "$json" -d "{\"id\":\"$code\",\"properties\":{\"$field\":\"done\"}}")"
  echo "$dry" | grep -q required_property_unset || fail "$plural: dry run did not flag the missing $req"
  echo "$dry" | grep -q property_value_invalid || fail "$plural: dry run did not flag the bad $field"
  [ "$(status "$url/$plural/$code")" = 404 ] || fail "$plural: dry run stored $code"

  create "$plural" "$code" "{\"$req\":\"$val\",\"$field\":\"$v1\"}"
  [ "$(status -X POST "$url/$plural" -H "$json" -d "{\"id\":\"$code\",\"properties\":{\"$req\":\"$val\"}}")" = 422 ] \
    || fail "$plural: a second create of $code was not refused"
  curl -sS "$url/$plural/$code" | grep -q "\"$req\":\"$val\"" || fail "$plural: read $code"
  curl -sS "$url/$plural?per_page=100" | grep -q "\"id\":\"$code\"" || fail "$plural: list does not show $code"

  local tag; tag="$(etag "$plural" "$code")"
  [ "$(status -X PATCH "$url/$plural/$code" -H "$json" -H "If-Match: $tag" -d "{\"properties\":{\"$field\":\"$v2\"}}")" = 200 ] \
    || fail "$plural: update $code"
  curl -sS "$url/$plural/$code" | grep -q "\"$field\":\"$v2\"" || fail "$plural: update not stored"
  [ "$(status -X PATCH "$url/$plural/$code" -H "$json" -H "If-Match: $tag" -d "{\"properties\":{\"$field\":\"$v1\"}}")" = 412 ] \
    || fail "$plural: an update with a stale ETag was not refused"

  [ "$(status -X DELETE "$url/$plural/$code")" = 204 ] || fail "$plural: delete $code"
  [ "$(status "$url/$plural/$code")" = 404 ] || fail "$plural: $code still readable after delete"
  echo "ok   $plural: dry run, create, second create refused, read, list, update, stale update refused, delete"
}

# A parent with 0..* children; a child has at most one parent.
check_link() { # child-plural child-prefix relation parent-plural parent-type parent-prefix [child-properties-json]
  local cp=$1 cc="$2$3-child-$run" rel=$3 pp=$4 pt=$5 pa="$6$3-a-$run" pb="$6$3-b-$run" props=${7:-'{"title":"Check child"}'}
  create "$pp" "$pa" '{"title":"Check parent A"}'
  create "$pp" "$pb" '{"title":"Check parent B"}'
  create "$cp" "$cc" "$props" "{\"$rel\":{\"data\":[{\"type\":\"$pt\",\"id\":\"$pa\"}]}}"
  [ "$(children "$pp" "$pa" "$rel")" = "$cc" ] || fail "$pp $pa does not list $cc"
  [ -z "$(children "$pp" "$pb" "$rel")" ] || fail "$pp $pb lists children it should not have"

  [ "$(link "$cp" "$cc" "$rel" "$pt" "$pa" "$pb")" = 422 ] || fail "$cc linked to two parents"
  [ "$(link "$cp" "$cc" "$rel" "$pt" "$6$3-missing-$run")" = 422 ] || fail "$cc linked to a parent that does not exist"
  [ "$(link "$cp" "$cc" "$rel" "$pt" "$pb")" = 200 ] || fail "move $cc to $pb"
  [ -z "$(children "$pp" "$pa" "$rel")" ] && [ "$(children "$pp" "$pb" "$rel")" = "$cc" ] || fail "move $cc did not take"
  [ "$(link "$cp" "$cc" "$rel" "$pt")" = 200 ] || fail "unlink $cc"
  [ -z "$(children "$pp" "$pb" "$rel")" ] || fail "unlink $cc did not take"

  [ "$(link "$cp" "$cc" "$rel" "$pt" "$pa")" = 200 ] || fail "relink $cc"
  [ "$(status -X DELETE "$url/$pp/$pa")" = 204 ] || fail "delete $pa"
  [ "$(status "$url/$cp/$cc")" = 200 ] || fail "deleting $pa removed $cc"
  [ "$(status -X DELETE "$url/$cp/$cc")" = 204 ] || fail "delete $cc"
  [ "$(status -X DELETE "$url/$pp/$pb")" = 204 ] || fail "delete $pb"
  echo "ok   $cp $rel $pp: link, list children, two parents refused, missing parent refused, move, unlink, parent delete keeps child"
}

pr_url() { echo "https://github.com/eyra/atlas-check/pull/$run$1"; }

check_item scenes SC- title "Check item" status refine ready_to_pick_up
check_item use_cases UC- title "Check item" status refine ready_to_pick_up
check_item issues IS- title "Check item" stage specification development
check_item pull_requests PR- url "$(pr_url 1)" state open merged
check_link use_cases UC- in_scene scenes scene SC-
check_link issues IS- in_use_case use_cases use_case UC-
check_link pull_requests PR- in_issue issues issue IS- "{\"url\":\"$(pr_url 2)\"}"

# A pull request URL is one record: a second id with the same URL is refused.
create pull_requests "PR-check-url-$run" "{\"url\":\"$(pr_url 3)\"}"
[ "$(status -X POST "$url/pull_requests" -H "$json" -d "{\"id\":\"PR-check-url2-$run\",\"properties\":{\"url\":\"$(pr_url 3)\"}}")" = 422 ] \
  || fail "a second pull request with the same URL was not refused"
dry="$(curl -sS -X POST "$url/pull_requests?dry_run=true" -H "$json" -d "{\"id\":\"PR-check-bad-$run\",\"properties\":{\"url\":\"https://example.com/x\"}}")"
echo "$dry" | grep -q property_value_invalid || fail "dry run did not flag a URL that is not a GitHub pull request"
[ "$(status -X DELETE "$url/pull_requests/PR-check-url-$run")" = 204 ] || fail "delete PR-check-url-$run"
echo "ok   pull_requests: same URL twice refused, non-GitHub URL flagged"

echo "PASS"
