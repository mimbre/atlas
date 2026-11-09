#!/usr/bin/env bash
# Every file of a data folder with its SHA-256, one per line, sorted by path: the same on
# a Mac and on Fly. move-to-fly compares the manifest of what it sent with the one
# platform/ops/apply-move.sh writes on arrival, so every item and every link is checked, byte for
# byte, not only counted.
#
#   manifest.sh <folder>
set -euo pipefail

cd "$1"
if command -v sha256sum >/dev/null; then sum=(sha256sum); else sum=(shasum -a 256); fi
find . -type f -print0 | LC_ALL=C sort -z | xargs -0 "${sum[@]}"
