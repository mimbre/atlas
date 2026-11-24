#!/bin/zsh
# Run by launchd at login (com.mimbre.atlas-runtime): starts this Mac's standalone Runtime
# with its Bus link, as configured in ~/.config/atlas-runtime/machine.json. The Bus token
# exists on disk only between writing server.token and the service having loaded it.
set -e
umask 077
C=$HOME/.config/atlas-runtime
get() { /usr/bin/plutil -extract "$1" "${2:-raw}" -o - $C/machine.json }
export PATH=$(get path)
export ATLAS_RUNTIME_HOME=$(get runtime_home)
H=$ATLAS_RUNTIME_HOME
BUS_HOST=$(get bus.host)
BUS_PORT=$(get bus.port)
trap 'rm -f $H/server.token' EXIT
# After a reboot the network or the login keychain may not be ready yet: keep trying for 5 minutes.
for i in $(seq 1 30); do
  T=$($C/secret.sh ATLAS_BUS_LINK_TOKEN 2>/dev/null || true)
  [[ $T =~ '^[A-Za-z0-9._~+/=-]+$' ]] && break
  T=
  echo "$(date '+%F %T') no bus token yet (try $i), retrying in 10 s"; sleep 10
done
[ -n "$T" ] || { echo "$(date '+%F %T') no bus token"; exit 1; }
printf "%s" "$T" > $H/server.token; chmod 600 $H/server.token; unset T
cat > $H/server.json <<J
{"environment":"$(get environment)","host":"$BUS_HOST","port":$BUS_PORT,"machine":"$(get machine)","token_file":"server.token","workers":$(get workers json)}
J
# The Bus tunnel (com.mimbre.atlas-fly-proxy) may still be opening: wait up to 60 s for it.
for i in $(seq 1 60); do nc -z $BUS_HOST $BUS_PORT 2>/dev/null && break; sleep 1; done
set +e
atlas-runtime service start; rc=$?
rm -f $H/server.token
exit $rc
