#!/bin/zsh
# bootstrap.sh: installs a Runtime on this Mac from a build Atlas released, with its Fly
# proxy and Code service (IS-Atlas-116, UC-Atlas-50). It is the command a supervisor runs on
# a Mac that has no Runtime; published next to the release as install-macos.sh (release.sh).
#
#   INFISICAL_UNIVERSAL_AUTH_CLIENT_ID=… INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET=… \
#   ATLAS_WORK_SOURCE_TOKEN=… zsh install-macos.sh --build BUILD --environment test|prod \
#     --machine NAME --workers dev1,dev2 --source-url https://… [options]
#
# Secrets come only from the environment, never from an argument (`ps` shows none):
#   INFISICAL_UNIVERSAL_AUTH_CLIENT_ID/_SECRET  this machine's Infisical identity; stored in
#                                               the login keychain for secret.sh
#   ATLAS_WORK_SOURCE_TOKEN                     the credential the work source admits this
#                                               Runtime with; stored as
#                                               RUNTIME_HOME/sources/SOURCE/token (0600)
# Each may be left out once it is stored. What it does, each step skipped when done already:
#   1. the keychain items, the Runtime home with its source credential, and a first
#      policy.json (version 1: the work source and the slots, no profile) when there is none.
#      Control's configuration of the machinery (version 2 and up) replaces it on the first
#      poll; the source itself is fixed at install (a configuration cannot move it);
#   2. the released build: downloads atlas-runtime-BUILD, checks its SHA-256 and installs it
#      with its own `atlas-runtime service update --build BUILD --restart none`
#      (~/.local/share/atlas-runtime/releases/BUILD, ~/.local/bin/atlas-runtime). A Mac
#      that runs another build is left alone: upgrade it through Control;
#   3. ~/.config/atlas-runtime/machine.json from the arguments, and ATLAS_RUNTIME_HOME in
#      ~/.zshenv when that names none;
#   4. the release's install.sh: the Runtime, Fly proxy and Code launch agents, loaded.
# Running it again with the same arguments changes nothing. --dry-run shows what it would do.
#
# Options (defaults in brackets):
#   --source-name NAME [flow]  --git-url URL  --source-max-slots N [number of workers]
#   --runtime-home DIR [~/.local/state/atlas-runtime]  --path PATH [~/.local/bin:$PATH]
#   --bus-host HOST [127.0.0.1]  --bus-port PORT [7595]
#   --fly-app APP --fly-remote-port PORT        (both, or neither: the Bus without a tunnel)
#   --infisical-domain URL [https://eu.infisical.com] --infisical-project-id ID
#   --infisical-env ENV [the environment] --infisical-path PATH [/runtimes/MACHINE]
#   --code-home DIR [~/.local/state/atlas-code]  --code-port PORT [7596]
#   --code-repository NAME=REMOTE (repeatable) [github.com/mimbre/atlas=https://github.com/mimbre/atlas.git]
#   --no-code                     (no Code service)
#   --releases URL|DIR [https://github.com/mimbre/atlas/releases/download]
set -eu
die() { echo "install: $*" >&2; exit 1 }
[[ $(uname) == Darwin && $(uname -m) == arm64 ]] || die "an Apple silicon Mac only (the release is darwin-arm64)"

typeset -A O
O=(source-name flow runtime-home $HOME/.local/state/atlas-runtime path "$HOME/.local/bin:$PATH"
  bus-host 127.0.0.1 bus-port 7595 infisical-domain https://eu.infisical.com
  code-home $HOME/.local/state/atlas-code code-port 7596
  releases https://github.com/mimbre/atlas/releases/download)
typeset -a REPOS
DRY= CODE=1
while (( $# )); do
  case $1 in
    --dry-run) DRY=1; shift ;;
    --no-code) CODE=; shift ;;
    --code-repository) (( $# > 1 )) || die "$1 needs a value"; REPOS+=$2; shift 2 ;;
    --(build|environment|machine|workers|source-url|source-name|git-url|source-max-slots|runtime-home|path|bus-host|bus-port|fly-app|fly-remote-port|infisical-domain|infisical-project-id|infisical-env|infisical-path|code-home|code-port|releases))
      (( $# > 1 )) || die "$1 needs a value"; O[${1#--}]=$2; shift 2 ;;
    *) die "unknown argument $1 (see the head of this script)" ;;
  esac
done
for k in build environment machine workers source-url infisical-project-id; do
  [[ -n ${O[$k]:-} ]] || die "--$k is required"
done
: ${O[infisical-env]:=${O[environment]}} ${O[infisical-path]:=/runtimes/${O[machine]}}
(( ${#REPOS} )) || REPOS=(github.com/mimbre/atlas=https://github.com/mimbre/atlas.git)

plain() { [[ $2 =~ '^[A-Za-z0-9._/:-]+$' ]] || die "--$1 '$2' is not a plain value" }
port() { [[ $2 == <1-65535> ]] || die "--$1 must be a port number" }
https() { [[ $2 =~ '^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~/-]*)?$' ]] || die "--$1 must be an https:// URL" }
B=${O[build]}; [[ $B =~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' ]] || die "--build $B is no build name"
[[ ${O[environment]} == (test|prod) ]] || die "--environment must be test or prod"
plain machine ${O[machine]}
[[ ${O[workers]} =~ '^[A-Za-z0-9._-]+(,[A-Za-z0-9._-]+)*$' ]] || die "--workers must be worker IDs, comma separated"
WORKERS=(${(s:,:)O[workers]})
[[ ${O[source-name]} =~ '^[a-z][a-z0-9_-]{0,63}$' && ${O[source-name]} != local ]] || die "--source-name must be a plain lower-case name, not local"
https source-url ${O[source-url]}
[[ -z ${O[git-url]:-} ]] || https git-url ${O[git-url]}
: ${O[source-max-slots]:=${#WORKERS}}
[[ ${O[source-max-slots]} == <0-> ]] || die "--source-max-slots must be a number"
H=${O[runtime-home]}; [[ $H == /* ]] || die "--runtime-home must be absolute"
[[ ${O[path]} =~ '^[A-Za-z0-9._/:@+-]+$' ]] || die "--path holds characters a PATH here may not (only letters, digits and ._/:@+-)"
for k in runtime-home code-home; do plain $k ${O[$k]}; done
plain bus-host ${O[bus-host]}; port bus-port ${O[bus-port]}
if [[ -n ${O[fly-app]:-}${O[fly-remote-port]:-} ]]; then
  plain fly-app ${O[fly-app]:-}; port fly-remote-port ${O[fly-remote-port]:-}
fi
https infisical-domain ${O[infisical-domain]}
for k in infisical-project-id infisical-env infisical-path; do plain $k ${O[$k]}; done
if [[ -n $CODE ]]; then
  [[ ${O[code-home]} == /* ]] || die "--code-home must be absolute"; port code-port ${O[code-port]}
  for r in $REPOS; do
    [[ $r =~ '^github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+=[^"\\[:space:]]+$' ]] || die "--code-repository $r is not github.com/OWNER/REPO=REMOTE"
  done
fi
[[ ${O[releases]} == (https://*|/*) ]] || die "--releases must be an https:// URL or an absolute folder"
MACHINE=${O[machine]} SOURCE=${O[source-name]}
C=$HOME/.config/atlas-runtime
BIN=$HOME/.local/bin/atlas-runtime
SHARE=${XDG_DATA_HOME:-$HOME/.local/share}/atlas-runtime
RELEASE=$SHARE/releases/$B
note() { echo "install: $*" }
act() { if [[ -n $DRY ]]; then note "would $1"; return 1; fi; note "$1" }

# Tools the Runtime and its scripts need, on the Runtime's path.
for t in elixir erl; do PATH=${O[path]} whence -p $t >/dev/null || die "$t is not on --path (install Erlang and Elixir, e.g. with asdf)"; done
PATH=/opt/homebrew/bin:/usr/local/bin:$PATH whence -p infisical >/dev/null || die "the Infisical CLI is not installed (brew install infisical/get-cli/infisical)"
[[ -z ${O[fly-app]:-} ]] || PATH=/opt/homebrew/bin:/usr/local/bin:$PATH whence -p fly >/dev/null || die "flyctl (fly) is not installed"
PATH=${O[path]} whence -p codex >/dev/null || PATH=${O[path]} whence -p claude >/dev/null ||
  note "warning: neither codex nor claude is on --path; the Runtime runs no turn without one"

# 1. Keychain items, from the environment. `security -i` reads its command on stdin (print
# is a shell builtin), so the value is no process argument.
keychain() {
  local service=$1 value=${(P)2:-}
  if [[ -z $value ]]; then
    security find-generic-password -a $MACHINE -s $service >/dev/null 2>&1 || die "set $2 (no keychain item $service for $MACHINE yet)"
    return 0
  fi
  [[ $value =~ '^[A-Za-z0-9._~+/=-]+$' ]] || die "$2 holds characters a credential does not"
  [[ $(security find-generic-password -a $MACHINE -s $service -w 2>/dev/null) == $value ]] && return 0
  act "store $service for $MACHINE in the login keychain" || return 0
  print -r -- "add-generic-password -U -a \"$MACHINE\" -s \"$service\" -w \"$value\"" | security -i >/dev/null
}
keychain atlas-infisical-client-id INFISICAL_UNIVERSAL_AUTH_CLIENT_ID
keychain atlas-infisical-client-secret INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET

# The Runtime home and its source credential.
if [[ ! -d $H ]] && act "create the Runtime home $H"; then mkdir -p -m 700 $H; fi
TOKEN_FILE=sources/$SOURCE/token
if [[ -n ${ATLAS_WORK_SOURCE_TOKEN:-} ]]; then
  [[ $ATLAS_WORK_SOURCE_TOKEN =~ '^[A-Za-z0-9._~+/=-]+$' ]] || die "ATLAS_WORK_SOURCE_TOKEN holds characters a token does not"
  if [[ ! -f $H/$TOKEN_FILE || $(<$H/$TOKEN_FILE) != $ATLAS_WORK_SOURCE_TOKEN ]] && act "write $H/$TOKEN_FILE"; then
    mkdir -p -m 700 $H/sources/$SOURCE
    (umask 077; print -rn -- $ATLAS_WORK_SOURCE_TOKEN > $H/$TOKEN_FILE.tmp); mv $H/$TOKEN_FILE.tmp $H/$TOKEN_FILE
  fi
elif [[ ! -f $H/$TOKEN_FILE ]]; then
  [[ -n $DRY ]] && note "would need ATLAS_WORK_SOURCE_TOKEN: no $H/$TOKEN_FILE yet" || die "set ATLAS_WORK_SOURCE_TOKEN (no $H/$TOKEN_FILE yet)"
fi
json_list() { local out= w; for w in "$@"; do out+="${out:+,}\"$w\""; done; print -r -- "[$out]" }
if [[ ! -f $H/policy.json ]] && act "write the first policy.json (version 1, source $SOURCE; Control's configuration replaces it)"; then
  {
    print -r -- "{\"version\":1,\"changed_by\":\"install\",\"slots\":$(json_list $WORKERS),\"profiles\":{},"
    print -rn -- "\"sources\":[{\"name\":\"$SOURCE\",\"kind\":\"remote\",\"url\":\"${O[source-url]}\",\"credential_file\":\"$TOKEN_FILE\",\"priority\":1,\"max_slots\":${O[source-max-slots]},\"max_store_bytes\":2147483648"
    [[ -z ${O[git-url]:-} ]] || print -rn -- ",\"git_url\":\"${O[git-url]}\""
    print -r -- "}]}"
  } > $H/policy.json.tmp
  chmod 600 $H/policy.json.tmp
  mv $H/policy.json.tmp $H/policy.json
fi

# 2. The released build.
installed=$(readlink $BIN 2>/dev/null || true)
if [[ $installed == $RELEASE/bin/atlas-runtime && -f $RELEASE/BUILD && $(<$RELEASE/BUILD) == $B ]]; then
  :
elif [[ -n $installed || -e $BIN ]] && ATLAS_RUNTIME_HOME=$H $BIN service status >/dev/null 2>&1; then
  die "a Runtime runs here on another build ($installed): upgrade it through Control (a runtime_upgrade naming $B)"
elif act "install the released build $B"; then
  T=$(mktemp -d "${TMPDIR:-/tmp}/atlas-install.XXXXXX"); trap 'rm -rf $T' EXIT INT TERM
  A=atlas-runtime-$B-darwin-arm64.tar.gz
  mkdir -p $T/atlas-runtime-$B
  if [[ ${O[releases]} == /* ]]; then
    cp ${O[releases]}/atlas-runtime-$B/$A{,.sha256} $T/atlas-runtime-$B/
  else
    for f in $A.sha256 $A; do curl -fsSL --proto '=https' -o $T/atlas-runtime-$B/$f ${O[releases]}/atlas-runtime-$B/$f || die "download of $f failed"; done
  fi
  (cd $T/atlas-runtime-$B && shasum -a 256 -c $A.sha256 >/dev/null) || die "$A does not have the SHA-256 its .sha256 names"
  mkdir $T/cli && tar -xzf $T/atlas-runtime-$B/$A -C $T/cli ./bin/atlas-runtime ./BUILD
  # The release's own update command installs it (and checks the SHA-256 again).
  ATLAS_RUNTIME_HOME=$H $T/cli/bin/atlas-runtime service update --build $B --releases $T --install $BIN --restart none >/dev/null ||
    die "atlas-runtime service update failed; see $H/update.json"
  rm -rf $T; trap - EXIT INT TERM
fi

# 3. machine.json, and the shell's Runtime home.
M=$C/machine.json
{
  print -r -- "{"
  print -r -- "  \"machine\": \"$MACHINE\", \"environment\": \"${O[environment]}\", \"runtime_home\": \"$H\","
  print -r -- "  \"workers\": $(json_list $WORKERS),"
  print -r -- "  \"path\": \"${O[path]}\","
  print -r -- "  \"bus\": {\"host\": \"${O[bus-host]}\", \"port\": ${O[bus-port]}},"
  [[ -z ${O[fly-app]:-} ]] || print -r -- "  \"fly_proxy\": {\"app\": \"${O[fly-app]}\", \"remote_port\": ${O[fly-remote-port]}},"
  if [[ -n $CODE ]]; then
    repos=; for r in $REPOS; do repos+="${repos:+, }\"${r%%=*}\": \"${r#*=}\""; done
    print -r -- "  \"code\": {\"home\": \"${O[code-home]}\", \"config\": {\"port\": ${O[code-port]}, \"repositories\": {$repos}}},"
  fi
  print -r -- "  \"infisical\": {\"domain\": \"${O[infisical-domain]}\", \"project_id\": \"${O[infisical-project-id]}\", \"env\": \"${O[infisical-env]}\", \"path\": \"${O[infisical-path]}\"}"
  print -r -- "}"
} > ${TMPDIR:-/tmp}/machine.json.$$
chmod 600 ${TMPDIR:-/tmp}/machine.json.$$
if ! cmp -s ${TMPDIR:-/tmp}/machine.json.$$ $M 2>/dev/null && act "write $M"; then
  mkdir -p -m 700 $C; mv ${TMPDIR:-/tmp}/machine.json.$$ $M
fi
rm -f ${TMPDIR:-/tmp}/machine.json.$$
if ! grep -q 'ATLAS_RUNTIME_HOME' $HOME/.zshenv 2>/dev/null && act "add ATLAS_RUNTIME_HOME=$H to ~/.zshenv"; then
  print -r -- "export ATLAS_RUNTIME_HOME=$H" >> $HOME/.zshenv
fi

# 4. The launch agents, from the release's install.sh.
if [[ -n $DRY && ! -d $RELEASE ]]; then note "would run $RELEASE/platform/atlas_runtime/host/macos/install.sh"; exit 0; fi
if [[ -n $DRY && ! -f $M ]]; then note "would run install.sh once machine.json is written"; exit 0; fi
exec /bin/zsh $RELEASE/platform/atlas_runtime/host/macos/install.sh ${DRY:+--dry-run}
