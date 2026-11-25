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
# The Rela project the scripts serve: the product's generated description (bin/generate model
# writes it; it is not kept in git).
project="$here/../../../products/software_factory/model/targets/rela"
root="${ATLAS_TEST_ROOT:-$HOME/.local/share/atlas/test}"
data="${ATLAS_RELA_DATA:-$root/rela}"
bin="${ATLAS_RELA_BIN:-$root/bin}"
port="${ATLAS_RELA_PORT:-7690}"

version=26.11.9
# The archive for this machine: the MacBook and the Mac mini (darwin_arm64), CI (linux_amd64).
case "$(uname -s)_$(uname -m)" in
  Darwin_arm64)
    platform=darwin_arm64
    cli_archive_sha=9154163deaeba99ed2a4ee44a6ee7d8489c9a43412358aad7ac7074d54dd31aa
    server_archive_sha=0c800303d43e00835c60cb97064a93cb02976edf3ed88f4e33a38770735aa31b
    cli_sha=f5d5a24af08a88a6ea0a6fe2bd97677957ba16d3374813ec04743707e4972896
    server_sha=46eb1b09b8240f2793b3313fc189db28fc6b821857f62ea920fae9b6bfa8e38b
    sqlite_archive_sha=9ba610947262adf47913317631ba7b0ef531c2ed7acea4c44c510ff16bf5d9d2
    sqlite_sha=7566e66382de2bc1e16ecef0ddc11250ae8603145d6da0226a6361b296012a64
    ;;
  Linux_x86_64)
    platform=linux_amd64
    cli_archive_sha=dc7e005265eb3f155f4fe2c1c498228f85ca9509cf23195ea3c7b9f9d8c20a1b
    server_archive_sha=1eb170a955665cec5a3caadb3c32954f31eca0b9215590e74691dc42c6ea29c6
    cli_sha=08bc2e47432ab45ce7e1e93aef93b4c8d1ae00438fbc03f3972b872c1cfc29f1
    server_sha=7e579600d86a3b1a5a4bf0948ae8233a925c68d30b89ebab6b974879059eacd1
    sqlite_archive_sha=2510bfcd2d3fde2e098ba6372e915709673c1aca7a13bca2b3d4e236e98cd51c
    sqlite_sha=e2b1c0b20720c576c349ef24c442269b0c767d054c53ee2789ac91e72a52cf5d
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

# Loopback only, here and on Fly (where platform/ops/rela-run.sh puts rela-gate.py, which
# lets only the core in, on the private network): no acl.yaml, every caller may read and
# write. RELA_DATAENTRY_USER names the writer in rela's audit log.
export RELA_DATAENTRY_USER="${RELA_DATAENTRY_USER:-atlas-${ATLAS_ENV:-test}}"
exec "$bin/$server" -project "$data" -bind 127.0.0.1 -port "$port" -quiet
