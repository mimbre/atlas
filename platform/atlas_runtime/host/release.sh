#!/bin/sh
# release.sh BUILD OUT [GOOS GOARCH]: packs the Runtime release BUILD (IS-Atlas-26) from this
# checkout into OUT, as atlas-runtime-BUILD-GOOS-GOARCH.tar.gz and its .sha256, which CI
# publishes as the GitHub release atlas-runtime-BUILD (job deploy-runtime-release) and
# `atlas-runtime service update --build BUILD` installs.
#
# The release is the Atlas tree at this checkout's revision, with what the Runtime builds
# from that git does not hold (the generated targets: run bin/generate first; the umbrella's
# Hex dependencies: run mix deps.get in products/software_factory first, so the Runtime's
# first start needs no network), plus BUILD and bin/atlas-runtime: the CLI, built without
# a checkout location, so it runs the Runtime from the release it is in. Next to it in OUT:
# atlas-runtime-install.sh (macos/), the installer the command of `atlas runtime install`
# fetches from the release (IS-Atlas-116).
set -eu
[ $# -ge 2 ] || { echo "usage: release.sh BUILD OUT [GOOS GOARCH]" >&2; exit 2; }
build=$1 out=$2 goos=${3:-darwin} goarch=${4:-arm64}
printf '%s' "$build" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' || { echo "release.sh: $build is no build name" >&2; exit 2; }
root=$(cd "$(dirname "$0")/../../.." && pwd)
[ -d "$root/products/software_factory/deps" ] || { echo "release.sh: run mix deps.get in products/software_factory first" >&2; exit 1; }
[ -f "$root/products/software_factory/model/targets/rela/atlas.json" ] || { echo "release.sh: run bin/generate first" >&2; exit 1; }

stage=$(mktemp -d "${TMPDIR:-/tmp}/atlas-runtime-release.XXXXXX")
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/tree/bin" "$out"

# The tracked tree at HEAD, then the generated targets and the umbrella's dependencies.
git -C "$root" archive --format=tar HEAD | tar -x -C "$stage/tree"
(cd "$root" && git ls-files --others --ignored --exclude-standard --directory \
  products/software_factory/model/targets platform/atlas_control/backend/targets \
  platform/atlas_runtime platform/atlas_code/boundary/targets products/software_factory/deps \
  | grep -v -E '(^|/)(_build|\.elixir_ls)/' | grep -v -E '^platform/atlas_[a-z_]+/(deps|tmp)/' \
  | tar -c -T - -f -) | tar -x -C "$stage/tree"

printf '%s\n' "$build" >"$stage/tree/BUILD"
CGO_ENABLED=0 GOOS=$goos GOARCH=$goarch go -C "$root/platform/atlas_runtime/host" build -trimpath -o "$stage/tree/bin/atlas-runtime" .

name="atlas-runtime-$build-$goos-$goarch.tar.gz"
tar -C "$stage/tree" -czf "$out/$name" .
cp "$root/platform/atlas_runtime/host/macos/atlas-runtime-install.sh" "$out/atlas-runtime-install.sh"
(cd "$out" && { command -v sha256sum >/dev/null && sha256sum "$name" || shasum -a 256 "$name"; } >"$name.sha256")
echo "$out/$name"
