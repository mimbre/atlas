#!/bin/zsh
# atlas-runtime-install.sh: installs a Runtime on this Mac from a build Atlas released
# (IS-Atlas-116, UC-Atlas-50). It is the command `atlas runtime install` prints, published
# with each release (release.sh) as atlas-runtime-<build>/atlas-runtime-install.sh:
#
#   curl -fsSL …/atlas-runtime-BUILD/atlas-runtime-install.sh | ATLAS_RUNTIME_CREDENTIAL=… \
#     /bin/zsh -s -- --build BUILD --env test|prod --machine NAME --workers w1,w2 \
#     --source https://… --git https://… [--releases URL] [--runtime-home DIR] \
#     [--code-home DIR] [--code-port PORT]
#
# 1. fetches the release atlas-runtime-BUILD-darwin-arm64.tar.gz, checks its SHA-256 and
#    unpacks it into ~/.local/share/atlas-runtime/releases/BUILD, as `service update` does
#    (kept when it is there with its BUILD), and points ~/.local/bin/atlas-runtime at its CLI;
# 2. writes the work source credential (ATLAS_RUNTIME_CREDENTIAL, from the environment only:
#    never an argument) to <runtime home>/sources/flow/token, mode 600;
# 3. writes ~/.config/atlas-runtime/machine.json from its arguments;
# 4. runs the release's install.sh, which builds the release's Code (the atlas_code OTP
#    release), writes the Runtime's starting policy.json and code.json and Code's home when
#    they are not there, and loads the launch agents: Runtime, Code (and the Fly proxy when
#    machine.json names one).
#
# Running it again with the same arguments changes nothing. It refuses, changing nothing,
# where it would replace what it did not make: an atlas-runtime that is no release (bring it
# to one with `atlas-runtime service update --build BUILD`) or a machine.json that differs.
set -eu
umask 077

die() { print -u2 -r -- "atlas-runtime-install: $*"; exit 1 }
usage="usage: ATLAS_RUNTIME_CREDENTIAL=<token> atlas-runtime-install.sh --build BUILD --env test|prod --machine NAME --workers W1,W2 --source URL --git URL [--releases URL] [--runtime-home DIR] [--code-home DIR] [--code-port PORT]"

# The credential, from the environment only; nothing this script starts inherits it.
CREDENTIAL=${ATLAS_RUNTIME_CREDENTIAL:-}
unset ATLAS_RUNTIME_CREDENTIAL
[[ -n $CREDENTIAL ]] || die "no ATLAS_RUNTIME_CREDENTIAL in the environment: run the command Control gave (atlas runtime install)"
[[ $CREDENTIAL =~ '^[A-Za-z0-9._~+/-]+=*$' && ${#CREDENTIAL} -le 4096 ]] || die "ATLAS_RUNTIME_CREDENTIAL is no bearer token"

typeset -A A
A=(releases https://github.com/mimbre/atlas/releases/download
   runtime-home $HOME/.local/state/atlas-runtime
   code-home $HOME/.local/state/atlas-code
   code-port 7598)
while (( $# )); do
  case $1 in
    --build|--env|--machine|--workers|--source|--git|--releases|--runtime-home|--code-home|--code-port)
      (( $# >= 2 )) || die "$1 needs a value"$'\n'"$usage"
      A[${1#--}]=$2; shift 2 ;;
    --credential*) die "the credential is never an argument: set ATLAS_RUNTIME_CREDENTIAL" ;;
    *) die "unknown argument $1"$'\n'"$usage" ;;
  esac
done
for k in build env machine workers source git; do [[ -n ${A[$k]:-} ]] || die "--$k is missing"$'\n'"$usage"; done

[[ $(uname) == Darwin && $(uname -m) == arm64 ]] || die "a Runtime release is for macOS on arm64"
[[ ${A[build]} =~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' ]] || die "--build ${A[build]} is no build name"
[[ ${A[env]} == (test|prod) ]] || die "--env must be test or prod"
[[ ${A[machine]} =~ '^[a-z][a-z0-9-]{0,23}$' ]] || die "--machine ${A[machine]} is no machine name"
[[ ${A[workers]} =~ '^[a-z][a-z0-9_-]{0,63}(,[a-z][a-z0-9_-]{0,63})*$' ]] || die "--workers must be W1,W2: lower-case worker names"
https() { [[ $1 =~ '^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$' ]] }
https ${A[source]} || die "--source must be an https:// URL"
https ${A[git]} || die "--git must be an https:// URL"
[[ ${A[releases]} =~ '^(https://[A-Za-z0-9.-]+(:[0-9]{1,5})?|file://)/[A-Za-z0-9._~/-]*$' ]] || die "--releases must be an https:// (or file://) URL"
for k in runtime-home code-home; do
  [[ ${A[$k]} == /* && ${A[$k]} =~ '^[A-Za-z0-9._/-]+$' ]] || die "--$k must be an absolute path of plain names"
done
[[ ${A[code-port]} == <1024-65535> ]] || die "--code-port must be a port number"

BUILD=${A[build]}
DATA=$HOME/.local/share/atlas-runtime
[[ -n ${XDG_DATA_HOME:-} && $XDG_DATA_HOME == /* ]] && DATA=$XDG_DATA_HOME/atlas-runtime
REL=$DATA/releases/$BUILD
BIN=$HOME/.local/bin/atlas-runtime
C=$HOME/.config/atlas-runtime
H=${A[runtime-home]}

# Refuse first, before anything changes.
if [[ -e $BIN || -L $BIN ]]; then
  [[ -L $BIN && $(readlink $BIN) == $DATA/releases/*/bin/atlas-runtime ]] ||
    die "$BIN is there and no release: bring it to one once with atlas-runtime service update --build $BUILD"
fi

# machine.json (machine.example.json): every value checked above to be plain. One that is
# there and differs refuses here, before anything changes.
workers=\"${A[workers]//,/\",\"}\"
P=$HOME/.local/bin:$HOME/.asdf/shims:$HOME/.npm-global/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
[[ $P =~ '^[A-Za-z0-9._/:-]+$' ]] || die "your home's path $HOME is not plain names"
mkdir -p -m 700 $C
NEW=$C/machine.json.new
cat > $NEW <<J
{
  "machine": "${A[machine]}",
  "environment": "${A[env]}",
  "runtime_home": "$H",
  "workers": [$workers],
  "path": "$P",
  "source": {"name": "flow", "url": "${A[source]}", "git_url": "${A[git]}"},
  "code": {"home": "${A[code-home]}", "port": ${A[code-port]}}
}
J
if [[ -f $C/machine.json ]] && ! cmp -s $NEW $C/machine.json; then
  diff -u $C/machine.json $NEW >&2 || true
  rm -f $NEW
  die "$C/machine.json is there and differs (above); move it away to install with these arguments"
fi

# 1. The release, as `service update` fetches it (fetchRelease in update.go).
if [[ $(cat $REL/BUILD 2>/dev/null) != $BUILD ]]; then
  mkdir -p -m 755 $DATA/releases
  T=$(mktemp -d $DATA/releases/.$BUILD-XXXXXX)
  trap 'rm -rf $T' EXIT
  name=atlas-runtime-$BUILD-darwin-arm64.tar.gz
  base=${A[releases]%/}/atlas-runtime-$BUILD
  curl -fsSL --proto '=https,file' -o $T/$name.sha256 $base/$name.sha256 || die "cannot fetch $base/$name.sha256"
  curl -fsSL --proto '=https,file' -o $T/$name $base/$name || die "cannot fetch $base/$name"
  want=$(awk 'NR==1 {print tolower($1)}' $T/$name.sha256)
  [[ ${#want} == 64 ]] || die "$name.sha256 holds no SHA-256"
  [[ $(shasum -a 256 $T/$name | awk '{print $1}') == $want ]] || die "$name does not have the SHA-256 its .sha256 names"
  mkdir $T/tree
  tar -xzf $T/$name -C $T/tree
  [[ $(cat $T/tree/BUILD 2>/dev/null) == $BUILD ]] || die "release $BUILD: its BUILD does not name it"
  rm -rf $REL
  mv $T/tree $REL
  chmod 755 $REL
  echo "installed release $BUILD in $REL"
fi
[[ $($REL/bin/atlas-runtime version 2>/dev/null) == *"\"build\":\"$BUILD\""* ]] ||
  die "the CLI of release $BUILD does not say it is $BUILD"
mkdir -p $HOME/.local/bin
if [[ $(readlink $BIN 2>/dev/null) != $REL/bin/atlas-runtime ]]; then
  ln -s $REL/bin/atlas-runtime $BIN.new && mv -f $BIN.new $BIN
  echo "pointed $BIN at release $BUILD"
fi

# 2. The work source credential, where the Runtime reads it (AtlasRuntime.Sources.Credential).
mkdir -p -m 700 $H $H/sources $H/sources/flow
TOKEN=$H/sources/flow/token
if [[ ! -f $TOKEN || $(<$TOKEN) != $CREDENTIAL ]]; then
  print -rn -- $CREDENTIAL > $TOKEN.tmp && chmod 600 $TOKEN.tmp && mv -f $TOKEN.tmp $TOKEN
  echo "wrote $TOKEN"
fi
unset CREDENTIAL

# 3. machine.json, checked against what is there before anything changed.
if [[ ! -f $C/machine.json ]]; then
  chmod 600 $NEW && mv $NEW $C/machine.json
  echo "wrote $C/machine.json"
else
  rm -f $NEW
fi

# 4. The launch agents, from the release.
exec /bin/zsh $REL/platform/atlas_runtime/host/macos/install.sh
