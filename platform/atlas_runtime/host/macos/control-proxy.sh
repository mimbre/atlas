#!/bin/zsh
# Run by launchd (com.mimbre.atlas-control-proxy, kept alive): keeps this machine's route to
# its environment's Control open, 127.0.0.1:control_proxy.port -> port
# control_proxy.remote_port of Fly app control_proxy.app (flyctl's WireGuard), as configured
# in ~/.config/atlas-runtime/machine.json. The agents the Runtime starts reach Control on it
# (bin/atlas with ATLAS_AGENT_ENV, IS-Atlas-56); their sandbox opens no tunnel of its own.
set -e
export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin
C=$HOME/.config/atlas-runtime
get() { plutil -extract "$1" raw -o - $C/machine.json }
FLY_API_TOKEN=$($C/secret.sh FLY_API_TOKEN)
[ ${#FLY_API_TOKEN} -gt 20 ] || { echo "$(date '+%F %T') no fly token"; exit 1; }
export FLY_API_TOKEN
exec fly proxy "$(get control_proxy.port):$(get control_proxy.remote_port)" -a "$(get control_proxy.app)" -q
