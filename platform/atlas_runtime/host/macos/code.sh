#!/bin/zsh
# code.sh build|run: this Mac's Code service from the Runtime's release (IS-Atlas-116), as
# configured in ~/.config/atlas-runtime/machine.json ("code": home, port) and code.build
# (the build install.sh chose: the one ~/.local/bin/atlas-runtime runs).
#
#   build  builds the atlas_code OTP release from that release's tree into
#          ~/.local/share/atlas-runtime/code/BUILD, once: kept when it is there. The tree
#          holds the umbrella's Hex dependencies, so it needs no network; Elixir comes from
#          machine.json's path (the asdf shims). install.sh runs it before it loads the agent.
#   run    run by launchd (com.mimbre.atlas-code, kept alive): builds when needed, then runs
#          Code in the foreground on its home (bin/atlas_code eval "AtlasCode.Server.run()").
#
# Code starts no distribution, so its cookie is no secret: a fixed one, so that no random
# cookie is on its command line (the release's eval passes it as an argument).
set -eu
C=$HOME/.config/atlas-runtime
get() { /usr/bin/plutil -extract "$1" raw -o - $C/machine.json }
export PATH=$(get path)
BUILD=$(<$C/code.build)
[[ $BUILD =~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' ]] || { echo "code: $C/code.build names no build" >&2; exit 1 }
DATA=$HOME/.local/share/atlas-runtime
[[ -n ${XDG_DATA_HOME:-} && $XDG_DATA_HOME == /* ]] && DATA=$XDG_DATA_HOME/atlas-runtime
TREE=$DATA/releases/$BUILD
OUT=$DATA/code/$BUILD

build() {
  [[ -x $OUT/bin/atlas_code ]] && return 0
  [[ -f $TREE/BUILD ]] || { echo "code: no release $BUILD in $TREE" >&2; exit 1 }
  mkdir -p $DATA/code
  rm -rf $OUT.tmp
  echo "$(date '+%F %T') building Code of release $BUILD"
  (cd $TREE/products/software_factory &&
     MIX_ENV=prod mix release atlas_code --path $OUT.tmp --overwrite --quiet) >&2
  rm -rf $OUT && mv $OUT.tmp $OUT
}

case ${1:-} in
  build) build ;;
  run)
    build
    export ATLAS_CODE_HOME=$(get code.home) RELEASE_COOKIE=atlas-code-starts-no-distribution
    exec $OUT/bin/atlas_code eval "AtlasCode.Server.run()" ;;
  *) echo "usage: code.sh build|run" >&2; exit 2 ;;
esac
