#!/bin/zsh
# Run by launchd (com.mimbre.atlas-fly-proxy, kept alive): keeps the private Bus tunnel open,
# 127.0.0.1:bus.port -> port fly_proxy.remote_port of Fly app fly_proxy.app (flyctl's
# WireGuard), as configured in ~/.config/atlas-runtime/machine.json.
set -e
export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin
C=$HOME/.config/atlas-runtime
get() { plutil -extract "$1" raw -o - $C/machine.json }
FLY_API_TOKEN=$($C/secret.sh FLY_API_TOKEN)
[ ${#FLY_API_TOKEN} -gt 20 ] || { echo "$(date '+%F %T') no fly token"; exit 1; }
export FLY_API_TOKEN
exec fly proxy "$(get bus.port):$(get fly_proxy.remote_port)" -a "$(get fly_proxy.app)" -q
