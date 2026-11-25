#!/bin/zsh
# test-install.sh: rehearses atlas-runtime-install.sh and install.sh (IS-Atlas-116) in a
# throwaway HOME, against a release packed here from this checkout and fetched over file://.
# launchctl and mix are stubs that record what they were asked, so nothing is loaded into
# this Mac's session, nothing is built and nothing goes over the network. Checks: the first
# run installs the release, the credential, machine.json, the starting policy, Code's home
# and loads the Code and Runtime agents; a second run changes nothing; a differing run and
# a credential given as an argument are refused without changing a file; no secret is in
# an argument of what the agents run. Needs macOS on arm64 and Go. Exit 0: all held.
set -eu
[[ $(uname) == Darwin && $(uname -m) == arm64 ]] || { echo "test-install: macOS arm64 only" >&2; exit 2 }
SRC=${0:A:h}
R=$(mktemp -d "${TMPDIR:-/tmp}/atlas-test-install.XXXXXX"); trap 'rm -rf $R' EXIT
fail() { print -u2 -r -- "test-install: FAILED: $*"; exit 1 }
B=test-1 REL=$R/releases/atlas-runtime-test-1 TREE=$R/tree
mkdir -p $R/stubs $R/home/.asdf/shims $REL $TREE/bin $TREE/platform/atlas_runtime/host $TREE/products/software_factory
cp -R $SRC $TREE/platform/atlas_runtime/host/macos
print $B > $TREE/BUILD
(cd $SRC/.. && CGO_ENABLED=0 GOTELEMETRY=off go build -trimpath -o $TREE/bin/atlas-runtime .)
tar -C $TREE -czf $REL/atlas-runtime-$B-darwin-arm64.tar.gz .
(cd $REL && shasum -a 256 atlas-runtime-$B-darwin-arm64.tar.gz > atlas-runtime-$B-darwin-arm64.tar.gz.sha256)
cp $SRC/atlas-runtime-install.sh $REL/

cat > $R/stubs/launchctl <<'S'
#!/bin/sh
echo "launchctl $*" >> "$LOG"; touch "$LOG.loaded"
case $1 in
  print) grep -qx "${2##*/}" "$LOG.loaded" ;;
  bootout) grep -vx "${2##*/}" "$LOG.loaded" > "$LOG.n"; mv "$LOG.n" "$LOG.loaded" ;;
  bootstrap) basename "$3" .plist >> "$LOG.loaded" ;;
esac
S
cat > $R/home/.asdf/shims/mix <<'S'
#!/bin/sh
echo "mix $*" >> "$LOG"
while [ $# -gt 0 ]; do [ "$1" = --path ] && P=$2; shift; done
mkdir -p "$P/bin" && printf '#!/bin/sh\necho "$@"\n' > "$P/bin/atlas_code" && chmod +x "$P/bin/atlas_code"
S
chmod +x $R/stubs/launchctl $R/home/.asdf/shims/mix

CRED=dGVzdC1pbnN0YWxsLWNyZWRlbnRpYWwtb2YtYS1uZXctbWFj
install_with() {
  HOME=$R/home LOG=$R/log PATH=$R/stubs:/usr/bin:/bin:/usr/sbin:/sbin XDG_DATA_HOME= ATLAS_RUNTIME_HOME= \
    ATLAS_RUNTIME_CREDENTIAL=$CRED /bin/zsh -s -- --build $B --env test --machine new-mac --workers $1 \
    --source https://flow.example:7596 --git https://flow.example:7597 --releases file://$R/releases \
    < $REL/atlas-runtime-install.sh
}
files() { find $R/home -type f -exec stat -f '%m %z %Lp %N' {} + | sort }

install_with dev1,dev2 > $R/out 2>&1 || { cat $R/out; fail "the first install" }
H=$R/home/.local/state/atlas-runtime
[[ $(<$H/sources/flow/token) == $CRED && $(stat -f %Lp $H/sources/flow/token) == 600 ]] || fail "the credential file"
[[ $(readlink $R/home/.local/bin/atlas-runtime) == $R/home/.local/share/atlas-runtime/releases/$B/bin/atlas-runtime ]] || fail "the CLI link"
grep -q '"slots": \["dev1","dev2"\]' $H/policy.json || fail "the starting policy"
grep -q 'atlas-code/runtime.token' $H/code.json || fail "code.json"
[[ $(<$R/log.loaded) == $'com.mimbre.atlas-code\ncom.mimbre.atlas-runtime' ]] || fail "the agents loaded: $(<$R/log.loaded)"
for p in $R/home/Library/LaunchAgents/*.plist; do plutil -lint -s $p || fail "$p"; done

files > $R/before; : > $R/log; sleep 1
install_with dev1,dev2 > $R/out 2>&1 || { cat $R/out; fail "the second install" }
[[ ! -s $R/out ]] || { cat $R/out; fail "the second install said it changed something" }
grep -q 'bootstrap\|bootout' $R/log && fail "the second install reloaded an agent"
files | cmp -s - $R/before || fail "the second install changed a file"

install_with dev1,dev3 > $R/out 2>&1 && fail "a differing machine.json was not refused"
grep -q 'is there and differs' $R/out || fail "the refusal does not say why"
files | cmp -s - $R/before || fail "a refused install changed a file"
HOME=$R/home ATLAS_RUNTIME_CREDENTIAL=$CRED /bin/zsh $REL/atlas-runtime-install.sh --credential $CRED > $R/out 2>&1 &&
  fail "a credential given as an argument was not refused"

# What the agents run carries no secret in its arguments.
for p in $R/home/Library/LaunchAgents/*.plist; do
  args=$(plutil -extract ProgramArguments json -o - $p)
  [[ $args != *$CRED* && $args != *$(<$R/home/.local/state/atlas-code/runtime.token)* ]] || fail "$p has a secret in its arguments"
done
[[ $(HOME=$R/home /bin/zsh $R/home/.config/atlas-runtime/code.sh run) == 'eval AtlasCode.Server.run()' ]] || fail "Code's arguments"
echo "test-install: ok"
