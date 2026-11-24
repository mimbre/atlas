#!/bin/zsh
# Installs, or brings up to date, this Mac's Runtime launch agents from this checkout:
#   ~/.config/atlas-runtime/{start,secret,fly-proxy}.sh     copies of the scripts next to this one
#   ~/Library/LaunchAgents/com.mimbre.atlas-runtime.plist    runs start.sh at login
#   ~/Library/LaunchAgents/com.mimbre.atlas-fly-proxy.plist  keeps fly-proxy.sh running (only
#                                                            with "fly_proxy" in machine.json)
# Machine-specific settings stay in ~/.config/atlas-runtime/machine.json (machine.example.json).
# Idempotent: unchanged files are left alone; an agent is (re)loaded only when its plist changed
# or it is not loaded. It never stops or restarts a running Runtime.
# Usage: install.sh [--dry-run]   (--dry-run checks and shows what would change)
set -eu
SRC=${0:A:h}
C=$HOME/.config/atlas-runtime
LA=$HOME/Library/LaunchAgents
LOGS=$HOME/Library/Logs
M=$C/machine.json
RUNTIME=com.mimbre.atlas-runtime
PROXY=com.mimbre.atlas-fly-proxy
DRY=
case "${1:-}" in --dry-run) DRY=1 ;; "") ;; *) echo "usage: $0 [--dry-run]" >&2; exit 2 ;; esac

die() { echo "install: $*" >&2; exit 1 }
[[ $(uname) == Darwin ]] || die "macOS only"
[[ -f $M ]] || die "no $M; start from $SRC/machine.example.json"
has() { /usr/bin/plutil -extract "$1" json -o /dev/null "$M" 2>/dev/null }
get() { /usr/bin/plutil -extract "$1" "${2:-raw}" -o - "$M" 2>/dev/null || die "$M: no $1" }
word() { local v; v=$(get $1); [[ $v =~ '^[A-Za-z0-9._/:-]+$' ]] || die "$M: $1 '$v' is not a plain name"; print -r -- $v }

MACHINE=$(word machine)
ENVIRONMENT=$(word environment)
[[ $ENVIRONMENT == (test|prod) ]] || die "$M: environment must be test or prod"
HOME_DIR=$(word runtime_home)
[[ $HOME_DIR == /* && -d $HOME_DIR ]] || die "$M: runtime_home $HOME_DIR is not an existing absolute directory"
WORKERS=$(get workers json)
[[ $WORKERS =~ '^\["[A-Za-z0-9._-]+"(,"[A-Za-z0-9._-]+")*\]$' ]] || die "$M: workers must be a nonempty list of worker IDs"
word bus.host >/dev/null
[[ $(get bus.port) == <1-65535> ]] || die "$M: bus.port must be a port number"
for k in domain project_id env path; do word infisical.$k >/dev/null; done
PATH_FOR_RUNTIME=$(get path)
PATH=$PATH_FOR_RUNTIME whence -p atlas-runtime >/dev/null || die "atlas-runtime is not on machine.json's path"
PATH=/opt/homebrew/bin:/usr/local/bin:$PATH whence -p infisical >/dev/null || die "infisical CLI not installed"
if has fly_proxy; then
  word fly_proxy.app >/dev/null
  [[ $(get fly_proxy.remote_port) == <1-65535> ]] || die "$M: fly_proxy.remote_port must be a port number"
  PATH=/opt/homebrew/bin:/usr/local/bin:$PATH whence -p fly >/dev/null || die "flyctl (fly) not installed"
fi
for s in atlas-infisical-client-id atlas-infisical-client-secret; do
  security find-generic-password -a "$MACHINE" -s $s >/dev/null 2>&1 ||
    die "no keychain item $s for account $MACHINE: security add-generic-password -a $MACHINE -s $s -w"
done
[[ -z ${ATLAS_RUNTIME_HOME:-} || ${ATLAS_RUNTIME_HOME:A} == ${HOME_DIR:A} ]] ||
  echo "install: warning: shell ATLAS_RUNTIME_HOME=$ATLAS_RUNTIME_HOME differs from runtime_home $HOME_DIR" >&2

T=$(mktemp -d); trap 'rm -rf $T' EXIT
typeset -A CHANGED
# place FILE DEST MODE [LABEL]: installs FILE as DEST unless identical; marks LABEL changed.
place() {
  cmp -s "$1" "$2" 2>/dev/null && return 0
  [[ -n ${4:-} ]] && CHANGED[$4]=1
  if [[ -n $DRY ]]; then
    echo "would write $2"; [[ -f $2 ]] && { diff -u "$2" "$1" || true }
  else
    install -m $3 "$1" "$2"; echo "wrote $2"
  fi
}
# agent LABEL SCRIPT [KeepAlive XML]: the launch agent's plist.
agent() {
  cat <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$1</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/zsh</string>
		<string>$C/$2</string>
	</array>
	<key>EnvironmentVariables</key>
	<dict>
		<key>HOME</key>
		<string>$HOME</string>
	</dict>
	<key>RunAtLoad</key>
	<true/>$3
	<key>StandardOutPath</key>
	<string>$LOGS/${1#com.mimbre.}${4:-}.log</string>
	<key>StandardErrorPath</key>
	<string>$LOGS/${1#com.mimbre.}${4:-}.log</string>
</dict>
</plist>
P
}
loaded() { launchctl print gui/$UID/$1 >/dev/null 2>&1 }
load() {
  [[ -z ${CHANGED[$1]:-} ]] && loaded $1 && return 0
  if [[ -n $DRY ]]; then echo "would (re)load $1"; return 0; fi
  launchctl bootout gui/$UID/$1 2>/dev/null || true
  for i in {1..50}; do loaded $1 || break; sleep 0.1; done
  launchctl bootstrap gui/$UID $LA/$1.plist
  echo "loaded $1"
}
unload() {
  [[ -f $LA/$1.plist ]] || loaded $1 || return 0
  if [[ -n $DRY ]]; then echo "would unload and remove $1"; return 0; fi
  launchctl bootout gui/$UID/$1 2>/dev/null || true
  rm -f $LA/$1.plist; echo "removed $1"
}

if [[ -z $DRY ]]; then mkdir -p -m 700 $C; mkdir -p $LA $LOGS; fi
place $SRC/secret.sh $C/secret.sh 700
place $SRC/start.sh $C/start.sh 700
agent $RUNTIME start.sh '
	<key>AbandonProcessGroup</key>
	<true/>' -start > $T/runtime.plist
place $T/runtime.plist $LA/$RUNTIME.plist 644 $RUNTIME
if has fly_proxy; then
  place $SRC/fly-proxy.sh $C/fly-proxy.sh 700
  agent $PROXY fly-proxy.sh '
	<key>KeepAlive</key>
	<true/>
	<key>ThrottleInterval</key>
	<integer>10</integer>' > $T/proxy.plist
  place $T/proxy.plist $LA/$PROXY.plist 644 $PROXY
  load $PROXY
else
  unload $PROXY
  [[ -n $DRY || ! -f $C/fly-proxy.sh ]] || rm -f $C/fly-proxy.sh
fi
load $RUNTIME
