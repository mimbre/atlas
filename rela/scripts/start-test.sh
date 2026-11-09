#!/usr/bin/env bash
# Start an Atlas rela (test, or prod with bin/atlas --env prod) on this Mac: loopback
# only, its own dataset. bin/atlas sets the port, data and binaries per environment.
#
#   start-test.sh            # runs in the foreground; Ctrl-C stops it
#   start-test.sh install    # only install the pinned rela into $ATLAS_RELA_BIN (the Fly image)
#
# The description (schema.yaml, plus the data-entry.yaml rela-server needs)
# next to scripts/ is copied into the data
# directory on every start, so changing the description is: edit, restart.
# Data stays in $ATLAS_RELA_DATA and is never shared with another store.
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
root="${ATLAS_TEST_ROOT:-$HOME/.local/share/atlas/test}"
data="${ATLAS_RELA_DATA:-$root/rela}"
bin="${ATLAS_RELA_BIN:-$root/bin}"
port="${ATLAS_RELA_PORT:-7690}"
# Loopback on a Mac; on Fly the private network (fly/rela/run.sh sets it).
bind="${ATLAS_RELA_BIND:-127.0.0.1}"

version=26.11.2
# The archive for this machine: the MacBook and the Mac mini (darwin_arm64), CI (linux_amd64).
case "$(uname -s)_$(uname -m)" in
  Darwin_arm64) platform=darwin_arm64; sha256=340a9787dbf395e20ef2248d7a367dde91cba4f4c6e546f600635f84ed815c76 ;;
  Linux_x86_64) platform=linux_amd64; sha256=b11d3dd5aa8f584a62acde4d396c491ff052487eb199e8d78c3b447b093dc3f2 ;;
  *) echo "start-test: no rela $version archive known for $(uname -s) $(uname -m)" >&2; exit 1 ;;
esac
archive="rela_${version}_${platform}.tar.gz"

# The live agent store listens on 7612; never start on it.
if [ "$port" = 7612 ]; then echo "start-test: port 7612 is the live store" >&2; exit 1; fi

if [ ! -x "$bin/rela-server" ] || [ "$("$bin/rela" version)" != "rela version $version" ]; then
  echo "start-test: installing rela $version into $bin"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/atlas-rela-install.XXXXXX")"
  curl -fsSL -o "$tmp/$archive" \
    "https://github.com/sourcehaven-bv/rela/releases/download/v$version/$archive"
  if command -v shasum >/dev/null; then sum="shasum -a 256"; else sum=sha256sum; fi
  echo "$sha256  $tmp/$archive" | $sum -c -
  mkdir -p "$bin"
  tar -xzf "$tmp/$archive" -C "$bin" rela rela-server
  rm -rf "$tmp"
fi
[ "${1:-}" != install ] || exit 0

"${ATLAS_CONFIG_PYTHON:-python3}" "$here/scripts/verify.py" "$here"
mkdir -p "$data/entities" "$data/relations"
"${ATLAS_CONFIG_PYTHON:-python3}" "$here/scripts/config.py" copy --root "$here" --data "$data"
"$bin/rela" --project "$data" --quiet validate

# No acl.yaml and a loopback bind (on Fly: test's own private network, which only its core
# and admitted devices join): every caller there may read and write.
# RELA_DATAENTRY_USER names the writer in rela's audit log.
export RELA_DATAENTRY_USER="${RELA_DATAENTRY_USER:-atlas-${ATLAS_ENV:-test}}"
exec "$bin/rela-server" -project "$data" -bind "$bind" -port "$port" -quiet
