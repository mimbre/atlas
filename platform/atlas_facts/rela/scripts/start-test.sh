#!/usr/bin/env bash
# Start an Atlas rela (test, or prod with bin/atlas --env prod) on this Mac: loopback
# only, its own dataset. bin/atlas sets the port, data and binaries per environment.
#
#   start-test.sh            # runs in the foreground; Ctrl-C stops it
#   start-test.sh install    # only install the pinned rela into $ATLAS_RELA_BIN (the Fly image)
#
# The description (schema.yaml, plus the data-entry.yaml rela-server needs)
# in $project is copied into the data
# directory on every start, so changing the description is: edit, restart.
# Data stays in $ATLAS_RELA_DATA and is never shared with another store.
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
# The Rela project the scripts serve: the product's generated description.
project="$here/../../../products/software_factory/targets/rela"
root="${ATLAS_TEST_ROOT:-$HOME/.local/share/atlas/test}"
data="${ATLAS_RELA_DATA:-$root/rela}"
bin="${ATLAS_RELA_BIN:-$root/bin}"
port="${ATLAS_RELA_PORT:-7690}"
# Loopback on a Mac; on Fly the private network (platform/ops/rela-run.sh sets it).
bind="${ATLAS_RELA_BIND:-127.0.0.1}"

version=26.11.3
# The archive for this machine: the MacBook and the Mac mini (darwin_arm64), CI (linux_amd64).
case "$(uname -s)_$(uname -m)" in
  Darwin_arm64)
    platform=darwin_arm64
    cli_archive_sha=a58f1c4b98788edd023ac9e0464bd4bb06beb2d9f95974512155e2e9b2a6477c
    server_archive_sha=e912966778186f21c54652729aacd7a8a0ce8b139f72df4cb719f416ff831c5f
    cli_sha=2d8968bf6bb00d96e90d937650bdb2488208653bb1e2f7615bb31e3a012b88d7
    server_sha=e093883dec14eefb561635b8b2e594b1acd751726feafe8f394410f565fa73aa
    sqlite_archive_sha=488fc2ecbbd9bff326a461c6646fe5d557a6710f1e9c237d22109c14970c0f67
    sqlite_sha=72e2f50a181e0f8b4c6a511f4f9f9399308109b8fb09f4f3b3bc9b2aa07e29af
    ;;
  Linux_x86_64)
    platform=linux_amd64
    cli_archive_sha=fcc2ff25d1137870af23c7b75ad426d28b324ce70a2ca35ca4ebf033afdd532b
    server_archive_sha=ff3e434c2dfbc353b70bfe404bb389c4a4450502beae84f1d74011c0e79dd1cd
    cli_sha=fc582d94cc21d20d72b25118f40aeb4e6e7adb638eed6e2061abf033db4f32d4
    server_sha=09906fa0fe550c40c119ba0f54998b2c47a25af73318d4e1c7c328ded4e7b9a6
    sqlite_archive_sha=4988a201bc06c115b9e815d01e7628a3eb765029ce3f056d798f9506b4b21b12
    sqlite_sha=c29587dcdb97dc48e5b5cd5d0b7cc8c0e9c58e8559b8dfe5504d87fd9564231b
    ;;
  *) echo "start-test: no rela $version archive known for $(uname -s) $(uname -m)" >&2; exit 1 ;;
esac
cli_archive="rela_${version}_${platform}.tar.gz"
server_archive="rela-headless-sqlite_${version}_${platform}.tar.gz"
sqlite_archive="rela-sqlite_${version}_${platform}.tar.gz"
server=rela-server-headless-sqlite
if command -v shasum >/dev/null; then sum=(shasum -a 256); else sum=(sha256sum); fi
matches() { [ -x "$2" ] && echo "$1  $2" | "${sum[@]}" -c - >/dev/null 2>&1; }

# The live agent store listens on 7612; never start on it.
if [ "$port" = 7612 ]; then echo "start-test: port 7612 is the live store" >&2; exit 1; fi

if ! matches "$cli_sha" "$bin/rela" || ! matches "$server_sha" "$bin/$server" || ! matches "$sqlite_sha" "$bin/rela-sqlite"; then
  echo "start-test: installing rela $version validation/SQLite CLIs and headless server into $bin"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/atlas-rela-install.XXXXXX")"
  trap 'rm -rf "$tmp"' EXIT
  for archive in "$cli_archive" "$server_archive" "$sqlite_archive"; do
    curl -fsSL -o "$tmp/$archive" \
      "https://github.com/sourcehaven-bv/rela/releases/download/v$version/$archive"
  done
  echo "$cli_archive_sha  $tmp/$cli_archive" | "${sum[@]}" -c -
  echo "$server_archive_sha  $tmp/$server_archive" | "${sum[@]}" -c -
  echo "$sqlite_archive_sha  $tmp/$sqlite_archive" | "${sum[@]}" -c -
  # The generic archive supplies ONLY the CLI; never extract its UI-capable server.
  tar -xzf "$tmp/$cli_archive" -C "$tmp" rela
  tar -xzf "$tmp/$server_archive" -C "$tmp" "$server"
  tar -xzf "$tmp/$sqlite_archive" -C "$tmp" rela-sqlite
  matches "$cli_sha" "$tmp/rela"
  matches "$server_sha" "$tmp/$server"
  matches "$sqlite_sha" "$tmp/rela-sqlite"
  mkdir -p "$bin"
  cp -p "$tmp/rela" "$tmp/$server" "$tmp/rela-sqlite" "$bin/"
  rm -rf "$tmp"
  trap - EXIT
fi
[ "${1:-}" != install ] || exit 0

"${ATLAS_CONFIG_PYTHON:-python3}" "$here/scripts/verify.py" "$project"
# Check existing state before replacing any of its description, including offline boot.
if bash "$here/scripts/data.sh" present "$data"; then
  ATLAS_RELA_BIN="$bin" bash "$here/scripts/description.sh" fits
else
  status=$?
  [ "$status" = 1 ] || exit "$status"
fi
mkdir -p "$data/entities" "$data/relations"
"${ATLAS_CONFIG_PYTHON:-python3}" "$here/scripts/config.py" copy --root "$project" --data "$data"
"$bin/rela" --project "$data" --quiet validate

# No acl.yaml and a loopback bind (on Fly: test's own private network, which only its core
# and admitted devices join): every caller there may read and write.
# RELA_DATAENTRY_USER names the writer in rela's audit log.
export RELA_DATAENTRY_USER="${RELA_DATAENTRY_USER:-atlas-${ATLAS_ENV:-test}}"
exec "$bin/$server" -project "$data" -bind "$bind" -port "$port" -quiet
