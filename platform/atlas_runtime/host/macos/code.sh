#!/bin/zsh
# Run by launchd (com.mimbre.atlas-code, kept alive): runs this Mac's Code service from the
# atlas_code release of the installed Runtime release (IS-Atlas-116), with the Code home of
# ~/.config/atlas-runtime/machine.json ("code.home"). The release is the one
# ~/.local/bin/atlas-runtime belongs to (`atlas-runtime version` names its root), so the
# Code that runs is always the installed build's; never a checkout. The release carries no
# ERTS: it runs on the Erlang of machine.json's "path".
set -e
C=$HOME/.config/atlas-runtime
get() { /usr/bin/plutil -extract "$1" raw -o - $C/machine.json }
export PATH=$(get path)
export ATLAS_CODE_HOME=$(get code.home)
R=$(atlas-runtime version | /usr/bin/plutil -extract root raw -o - -)
B=$R/code/bin/atlas_code
[[ -x $B ]] || { echo "$(date '+%F %T') no atlas_code release in $R (install a released build: atlas-runtime service update --build BUILD)"; exit 1 }
# asdf picks Erlang by the working directory's .tool-versions: the release tree's.
cd $R
exec $B eval "AtlasCode.Server.run()"
