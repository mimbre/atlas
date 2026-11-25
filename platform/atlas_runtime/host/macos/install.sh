#!/bin/zsh
# Installs, or brings up to date, this Mac's Runtime launch agents from this checkout or the
# release it is part of (atlas-runtime-install.sh runs it from the release, IS-Atlas-116):
#   ~/.config/atlas-runtime/{start,secret,fly-proxy,code}.sh copies of the scripts next to this one
#   ~/Library/LaunchAgents/com.mimbre.atlas-runtime.plist    runs start.sh at login
#   ~/Library/LaunchAgents/com.mimbre.atlas-fly-proxy.plist  keeps fly-proxy.sh running (only
#                                                            with "fly_proxy" in machine.json)
#   ~/Library/LaunchAgents/com.mimbre.atlas-code.plist       keeps the Code service running, the
#                                                            atlas_code release of the build
#                                                            atlas-runtime runs (only with "code")
# Machine-specific settings stay in ~/.config/atlas-runtime/machine.json (machine.example.json).
# With "source" (the work source the Runtime pulls from, its credential in
# <runtime_home>/sources/<name>/token) it writes the Runtime's starting policy.json, and with
# "code" Code's home and the Runtime's code.json, each only when it is not there: from then on
# Control sets the policy (the machinery's configuration) and Code keeps its home.
# Idempotent: unchanged files are left alone; an agent is (re)loaded only when its plist changed
# (for Code: or its build) or it is not loaded. It never stops or restarts a running Runtime.
# No secret is ever an argument: the Infisical credentials go to infisical by environment.
# Usage: install.sh [--dry-run]   (--dry-run checks and shows what would change)
set -eu
SRC=${0:A:h}
C=$HOME/.config/atlas-runtime
LA=$HOME/Library/LaunchAgents
LOGS=$HOME/Library/Logs
M=$C/machine.json
RUNTIME=com.mimbre.atlas-runtime
PROXY=com.mimbre.atlas-fly-proxy
CODE=com.mimbre.atlas-code
DATA=$HOME/.local/share/atlas-runtime
[[ -n ${XDG_DATA_HOME:-} && $XDG_DATA_HOME == /* ]] && DATA=$XDG_DATA_HOME/atlas-runtime
DRY=
case "${1:-}" in --dry-run) DRY=1 ;; "") ;; *) echo "usage: $0 [--dry-run]" >&2; exit 2 ;; esac

die() { echo "install: $*" >&2; exit 1 }
[[ $(uname) == Darwin ]] || die "macOS only"
[[ -f $M ]] || die "no $M; start from $SRC/machine.example.json"
has() { /usr/bin/plutil -extract "$1" json -o /dev/null "$M" >/dev/null 2>&1 }
get() { /usr/bin/plutil -extract "$1" "${2:-raw}" -o - "$M" 2>/dev/null || die "$M: no $1" }
word() { local v; v=$(get $1); [[ $v =~ '^[A-Za-z0-9._/:-]+$' ]] || die "$M: $1 '$v' is not a plain name"; print -r -- $v }

MACHINE=$(word machine)
ENVIRONMENT=$(word environment)
[[ $ENVIRONMENT == (test|prod) ]] || die "$M: environment must be test or prod"
HOME_DIR=$(word runtime_home)
[[ $HOME_DIR == /* && -d $HOME_DIR ]] || die "$M: runtime_home $HOME_DIR is not an existing absolute directory"
WORKERS=$(get workers json)
[[ $WORKERS =~ '^\["[A-Za-z0-9._-]+"(,"[A-Za-z0-9._-]+")*\]$' ]] || die "$M: workers must be a nonempty list of worker IDs"
https() { [[ $1 =~ '^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$' ]] }
# The Bus link (server.json, lifecycle reporting) is optional: a Runtime installed through
# Control pulls its work from the work source ("source") and needs none. Infisical holds the
# Bus link token and the Fly token, so it is needed with either.
if has bus; then
  word bus.host >/dev/null
  [[ $(get bus.port) == <1-65535> ]] || die "$M: bus.port must be a port number"
fi
if has bus || has fly_proxy; then
  for k in domain project_id env path; do word infisical.$k >/dev/null; done
fi
if has source; then
  SOURCE=$(word source.name)
  [[ $SOURCE =~ '^[a-z][a-z0-9_-]{0,63}$' && $SOURCE != local ]] || die "$M: source.name must be a plain lower-case name, not local"
  https "$(get source.url)" || die "$M: source.url must be an https:// URL"
  https "$(get source.git_url)" || die "$M: source.git_url must be an https:// URL"
  TOKEN=$HOME_DIR/sources/$SOURCE/token
  [[ -f $TOKEN && ! -L $TOKEN && $(stat -f %Lp $TOKEN) == 600 ]] ||
    die "no work source credential $TOKEN (mode 600): run the command Control gave (atlas runtime install)"
fi
has bus || has source || die "$M: no bus and no source: the Runtime would take no work"
PATH_FOR_RUNTIME=$(get path)
PATH=$PATH_FOR_RUNTIME whence -p atlas-runtime >/dev/null || die "atlas-runtime is not on machine.json's path"
if has bus || has fly_proxy; then
  PATH=/opt/homebrew/bin:/usr/local/bin:$PATH whence -p infisical >/dev/null || die "infisical CLI not installed"
fi
if has fly_proxy; then
  word fly_proxy.app >/dev/null
  [[ $(get fly_proxy.remote_port) == <1-65535> ]] || die "$M: fly_proxy.remote_port must be a port number"
  PATH=/opt/homebrew/bin:/usr/local/bin:$PATH whence -p fly >/dev/null || die "flyctl (fly) not installed"
fi
if has code; then
  CODE_HOME=$(word code.home)
  [[ $CODE_HOME == /* ]] || die "$M: code.home must be an absolute path"
  CODE_PORT=$(get code.port)
  [[ $CODE_PORT == <1024-65535> ]] || die "$M: code.port must be a port number"
  # Code runs from the release the Runtime runs (code.sh): a CLI built from a checkout has none.
  VERSION=$(PATH=$PATH_FOR_RUNTIME atlas-runtime version)
  CODE_BUILD=${${VERSION#*\"build\":\"}%%\"*}
  [[ $CODE_BUILD != checkout && $CODE_BUILD =~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' && -f $DATA/releases/$CODE_BUILD/BUILD ]] ||
    die "the Code service runs from a release, and atlas-runtime is not one: atlas-runtime service update --build BUILD"
  PATH=$PATH_FOR_RUNTIME whence -p mix >/dev/null || die "mix (Elixir) is not on machine.json's path: Code's release is built with it"
fi
if has bus || has fly_proxy; then
  for s in atlas-infisical-client-id atlas-infisical-client-secret; do
    security find-generic-password -a "$MACHINE" -s $s >/dev/null 2>&1 ||
      die "no keychain item $s for account $MACHINE: security add-generic-password -a $MACHINE -s $s -w"
  done
fi
[[ -z ${ATLAS_RUNTIME_HOME:-} || ${ATLAS_RUNTIME_HOME:A} == ${HOME_DIR:A} ]] ||
  echo "install: warning: shell ATLAS_RUNTIME_HOME=$ATLAS_RUNTIME_HOME differs from runtime_home $HOME_DIR" >&2

T=$(mktemp -d "${TMPDIR:-/tmp}/atlas-install.XXXXXX"); trap 'rm -rf $T' EXIT
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
# agent LABEL SCRIPT [KeepAlive XML] [log suffix] [argument]: the launch agent's plist.
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
		<string>$C/$2</string>${5:+
		<string>$5</string>}
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

# A file of the Runtime home or Code's home that is not there yet: written once, never replaced.
# seed FILE: its content on stdin.
seed() {
  [[ -e $1 ]] && { cat >/dev/null; return 0 }
  if [[ -n $DRY ]]; then echo "would write $1"; cat >/dev/null; return 0; fi
  cat > $1.tmp && chmod 600 $1.tmp && mv $1.tmp $1 && echo "wrote $1"
}

# The Runtime's starting policy: its work source and slots, no profile yet. Control's
# configuration (the machinery's, IS-Atlas-27) replaces it on the first poll; it keeps this
# source, which a configuration may not add, remove or move.
if has source; then
  slots=${${WORKERS#\[}%\]}
  seed $HOME_DIR/policy.json <<J
{"version": 1, "changed_by": "install.sh", "slots": [$slots], "profiles": {},
 "sources": [{"name": "$SOURCE", "kind": "remote", "url": "$(get source.url)",
   "credential_file": "sources/$SOURCE/token", "git_url": "$(get source.git_url)",
   "priority": 1, "max_slots": ${#${(s:,:)slots}}, "max_store_bytes": 2147483648}]}
J
fi

# The Code service: the atlas_code release of the build the Runtime runs, on its own home.
if has code; then
  if [[ -z $DRY ]]; then mkdir -p -m 700 $CODE_HOME; fi
  seed $CODE_HOME/config.json <<J
{"port": $CODE_PORT, "repositories": {"github.com/mimbre/atlas": {"url": "https://github.com/mimbre/atlas.git", "credentials": "none"}}}
J
  [[ -e $CODE_HOME/runtime.token ]] || openssl rand -base64 32 | tr -d '\n=' | tr '+/' '-_' | seed $CODE_HOME/runtime.token
  seed $HOME_DIR/code.json <<J
{"url": "http://127.0.0.1:$CODE_PORT", "token_file": "$CODE_HOME/runtime.token"}
J
  place $SRC/code.sh $C/code.sh 700
  print -r -- $CODE_BUILD > $T/code.build
  place $T/code.build $C/code.build 600 $CODE
  if [[ -z $DRY ]]; then
    PATH=$PATH_FOR_RUNTIME /bin/zsh $C/code.sh build || die "the Code release of $CODE_BUILD did not build"
  elif [[ ! -x $DATA/code/$CODE_BUILD/bin/atlas_code ]]; then
    echo "would build the Code release of $CODE_BUILD"
  fi
  agent $CODE code.sh '
	<key>KeepAlive</key>
	<true/>
	<key>ThrottleInterval</key>
	<integer>10</integer>' '' run > $T/code.plist
  place $T/code.plist $LA/$CODE.plist 644 $CODE
  load $CODE
fi
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
