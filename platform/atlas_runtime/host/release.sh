#!/bin/sh
# Builds the Runtime's release, the build Atlas publishes (IS-Atlas-26): the archive that
# `atlas-runtime update --build BUILD` installs, for this machine's GOOS/GOARCH.
#
#   platform/atlas_runtime/host/release.sh BUILD OUT_DIR
#
# writes OUT_DIR/atlas-runtime-BUILD-GOOS-GOARCH.tar.gz and its .sha256. The archive holds,
# at its top:
#
#   release.json                              {"build", "goos", "goarch"}
#   bin/atlas-runtime                         the CLI, built with -X main.build=BUILD
#   build/lib/*/ebin, build/consolidated      the compiled service, as service start builds
#                                             it (MIX_ENV=test), its links resolved
#   products/software_factory/config/         the configuration host/boot.exs loads
#   platform/atlas_runtime/host/boot.exs, service.exs
#
# A release starts without Mix or Hex: service start finds release.json next to its bin/
# and runs the service from build/ (host/update.go, releaseLayout). It needs Erlang/Elixir
# as .tool-versions pins them on the machine, as a checkout does.
set -eu

[ $# -eq 2 ] || { echo "use: release.sh BUILD OUT_DIR" >&2; exit 2; }
build=$1
out=$2
case "$build" in
  [A-Za-z0-9]*) ;;
  *) echo "release.sh: BUILD must start with a letter or digit" >&2; exit 2 ;;
esac
root=$(cd "$(dirname "$0")/../../.." && pwd)
# GOOS and GOARCH may name another machine (CI builds the Mac's release on Linux): the
# service's code is BEAM bytecode, the same everywhere, and the CLI uses no cgo.
goos=$(go env GOOS)
goarch=$(go env GOARCH)
name="atlas-runtime-$build-$goos-$goarch"
mkdir -p "$out"
out=$(cd "$out" && pwd)

stage=$(mktemp -d "${TMPDIR:-/tmp}/atlas-runtime-release.XXXXXX")
trap 'rm -rf "$stage"' EXIT
release="$stage/release"
mkdir -p "$release/bin" "$release/build" "$release/products/software_factory" "$release/platform/atlas_runtime/host"

CGO_ENABLED=0 go -C "$root/platform/atlas_runtime/host" build -trimpath -ldflags "-X main.build=$build" \
  -o "$release/bin/atlas-runtime" .

# The same build service start makes from a checkout (host/main.go, serviceCommands).
(cd "$root/products/software_factory" &&
  MIX_ENV=test MIX_BUILD_PATH="$stage/mix-build" mix do deps.get + compile --warnings-as-errors)
# Mix links each app's priv into the checkout: the release holds copies.
cp -RL "$stage/mix-build/lib" "$release/build/lib"
cp -RL "$stage/mix-build/consolidated" "$release/build/consolidated"

cp -R "$root/products/software_factory/config" "$release/products/software_factory/config"
cp "$root/platform/atlas_runtime/host/boot.exs" "$root/platform/atlas_runtime/host/service.exs" \
  "$release/platform/atlas_runtime/host/"
printf '{"build":"%s","goos":"%s","goarch":"%s"}\n' "$build" "$goos" "$goarch" > "$release/release.json"

# The binary must say it is this build, as update checks (when it runs here).
if [ "$goos/$goarch" = "$(go env GOHOSTOS)/$(go env GOHOSTARCH)" ]; then
  "$release/bin/atlas-runtime" version | grep -q "\"build\":\"$build\"" ||
    { echo "release.sh: the built atlas-runtime does not report build $build" >&2; exit 1; }
fi

tar -C "$release" -czf "$out/$name.tar.gz" .
(cd "$out" && shasum -a 256 "$name.tar.gz" > "$name.tar.gz.sha256")
echo "$out/$name.tar.gz"
