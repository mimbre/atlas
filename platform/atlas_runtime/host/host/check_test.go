package host

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/eyra/atlas/platform/atlas_runtime/host/snapshot"
	"github.com/eyra/atlas/platform/atlas_runtime/host/workspace"
)

// checkHome is a Runtime home in the isolated user home user, with one materialized folder at
// <home>/workers/work-x (B6), recorded like snapshot compose records one, and its scope as the core
// passes it: the folder's verified record plus profile, version and home.
func checkHome(t *testing.T, user, home string) (dest string, scope map[string]any) {
	t.Helper()
	dest = filepath.Join(home, "workers", "work-x")
	manifest := `{"entries":[],"repositories":[{"path":"repo","repository":"r","revision":"rev_` + strings.Repeat("a", 64) + `"}],"version":2}`
	sum := sha256.Sum256([]byte(manifest))
	id := "sha256:" + hex.EncodeToString(sum[:])
	baseline := filepath.Join(home, "snapshots", hex.EncodeToString(sum[:]))
	for _, directory := range []string{filepath.Join(baseline, "tree"), filepath.Join(home, "materializations"), filepath.Join(dest, "repo")} {
		if err := os.MkdirAll(directory, 0700); err != nil {
			t.Fatal(err)
		}
	}
	for path, body := range map[string]string{
		filepath.Join(baseline, "manifest.json"):                                                     manifest,
		filepath.Join(baseline, "complete"):                                                          id + "\n",
		filepath.Join(home, "materializations", fmt.Sprintf("%x.json", sha256.Sum256([]byte(dest)))): fmt.Sprintf(`{"destination":%q,"snapshot_id":%q}`, dest, id),
	} {
		if err := os.WriteFile(path, []byte(body), 0600); err != nil {
			t.Fatal(err)
		}
	}
	verified, err := snapshot.Verified(home, dest)
	if err != nil {
		t.Fatal(err)
	}
	verified["profile"], verified["version"], verified["home"] = "materialized-folder", json.Number("1"), home
	encoded, err := json.Marshal(verified)
	if err != nil {
		t.Fatal(err)
	}
	if scope, err = decodedScope(string(encoded)); err != nil {
		t.Fatal(err)
	}
	t.Setenv("ATLAS_RUNTIME_HOME", home)
	return dest, scope
}

func decodedScope(encoded string) (map[string]any, error) {
	value, err := argument(encoded)
	scope, _ := value.(map[string]any)
	return scope, err
}

// checkFixture is an isolated user home with a Runtime home and its work-x folder, and the
// `codex sandbox` stand-in of preparation (prepare_test.go): it records each call's argv in calls
// (NUL-separated, one call per line) and runs the command after `--` unconfined.
type checkFixture struct {
	user, home, dest, bin, calls string
	scope                        map[string]any
}

func newCheckFixture(t *testing.T) *checkFixture {
	t.Helper()
	user := isolatedHome(t)
	fixture := &checkFixture{user: user, home: filepath.Join(user, "runtime"), bin: t.TempDir()}
	fixture.dest, fixture.scope = checkHome(t, user, fixture.home)
	fixture.calls = filepath.Join(fixture.bin, "calls")
	standIn := "#!/bin/sh\nprintf '%s\\0' \"$0\" \"$@\" >> " + fixture.calls + "\necho >> " + fixture.calls +
		"\nwhile [ \"$#\" -gt 0 ] && [ \"$1\" != \"--\" ]; do shift; done\nshift\nexec \"$@\"\n"
	if err := os.WriteFile(filepath.Join(fixture.bin, "codex"), []byte(standIn), 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", fixture.bin+":/usr/bin:/bin")
	return fixture
}

func (fixture *checkFixture) scratch() string {
	return filepath.Join(fixture.home, "scratch", "check-work-x.1")
}

func (fixture *checkFixture) args(t *testing.T, timeout, grace, tail int, argv ...string) []string {
	t.Helper()
	scope, err := json.Marshal(fixture.scope)
	if err != nil {
		t.Fatal(err)
	}
	return append([]string{"--cwd", fixture.dest, "--scope", string(scope), "--scratch", fixture.scratch(),
		"--timeout", fmt.Sprint(timeout), "--grace", fmt.Sprint(grace), "--tail", fmt.Sprint(tail), "--"}, argv...)
}

func (fixture *checkFixture) readOnlyArgs(timeout, grace, tail int, argv ...string) []string {
	return append([]string{"--cwd", fixture.dest, "--sandbox", "read-only", "--scratch", fixture.scratch(),
		"--timeout", fmt.Sprint(timeout), "--grace", fmt.Sprint(grace), "--tail", fmt.Sprint(tail), "--"}, argv...)
}

// recordedCalls are the argv lists the stand-in received.
func (fixture *checkFixture) recordedCalls(t *testing.T) [][]string {
	t.Helper()
	data, err := os.ReadFile(fixture.calls)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	} else if err != nil {
		t.Fatal(err)
	}
	var calls [][]string
	for _, line := range strings.Split(strings.TrimSuffix(string(data), "\n"), "\n") {
		calls = append(calls, strings.Split(strings.TrimSuffix(line, "\x00"), "\x00"))
	}
	return calls
}

// checkRun is one in-process `host check` with live stdin and stdout.
type checkRun struct {
	stdin *os.File
	lines chan map[string]any
	done  chan error
}

func startCheck(t *testing.T, args []string) *checkRun {
	t.Helper()
	stdinReader, stdinWriter, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	stdoutReader, stdoutWriter := io.Pipe()
	run := &checkRun{stdin: stdinWriter, lines: make(chan map[string]any, 8), done: make(chan error, 1)}
	go func() {
		err := Check(args, stdinReader, stdoutWriter)
		stdoutWriter.Close()
		run.done <- err
	}()
	go func() {
		scanner := bufio.NewScanner(stdoutReader)
		scanner.Buffer(make([]byte, 1<<16), 1<<22)
		for scanner.Scan() {
			var line map[string]any
			if err := json.Unmarshal(scanner.Bytes(), &line); err != nil {
				line = map[string]any{"unparsed": scanner.Text()}
			}
			run.lines <- line
		}
		close(run.lines)
	}()
	t.Cleanup(func() {
		stdinWriter.Close()
		stdinReader.Close()
	})
	return run
}

// next is the next stdout line within bound.
func (run *checkRun) next(t *testing.T, bound time.Duration) map[string]any {
	t.Helper()
	select {
	case line, ok := <-run.lines:
		if !ok {
			t.Fatalf("host check printed no further line: %v", <-run.done)
		}
		return line
	case <-time.After(bound):
		t.Fatalf("host check printed nothing within %s", bound)
	}
	return nil
}

// finish requires the check to return nil and print nothing more within bound.
func (run *checkRun) finish(t *testing.T, bound time.Duration) {
	t.Helper()
	select {
	case err := <-run.done:
		if err != nil {
			t.Fatalf("host check: %v", err)
		}
	case <-time.After(bound):
		t.Fatalf("host check did not return within %s", bound)
	}
	if line, ok := <-run.lines; ok {
		t.Fatalf("extra line %v", line)
	}
}

// ended runs a check to its end with stdin open and returns the ended line.
func ended(t *testing.T, args []string, bound time.Duration) map[string]any {
	t.Helper()
	run := startCheck(t, args)
	if started := run.next(t, 10*time.Second); started["event"] != "started" {
		t.Fatalf("want started, got %v", started)
	}
	line := run.next(t, bound)
	if line["event"] != "ended" {
		t.Fatalf("want ended, got %v", line)
	}
	run.finish(t, 5*time.Second)
	return line
}

func refused(t *testing.T, args []string) string {
	t.Helper()
	run := startCheck(t, args)
	line := run.next(t, 10*time.Second)
	run.finish(t, 5*time.Second)
	if line["event"] != "refused" || len(line) != 2 {
		t.Fatalf("want a refused line, got %v", line)
	}
	return line["why"].(string)
}

func tailOf(line map[string]any) (string, bool) {
	output := line["output"].(map[string]any)
	return output["tail"].(string), output["complete"].(bool)
}

func requireGoneAndClean(t *testing.T, fixture *checkFixture, line map[string]any) {
	t.Helper()
	if line["group_gone"] != true || line["scratch_removed"] != true {
		t.Fatalf("group or scratch left: %v", line)
	}
	if _, err := os.Lstat(fixture.scratch()); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("scratch %s left: %v", fixture.scratch(), err)
	}
}

func TestCheckExitStatusesAndOwnSignal(t *testing.T) {
	fixture := newCheckFixture(t)
	for _, test := range []struct {
		argv []string
		want float64
	}{
		{[]string{"true"}, 0},
		{[]string{"sh", "-c", "exit 3"}, 3},
		// A command that dies of its own signal gets the status codex sandbox passes on (P0 T1e) and no signal.
		{[]string{"sh", "-c", "kill -TERM $$"}, 143},
	} {
		line := ended(t, fixture.args(t, 30, 1, 16384, test.argv...), 20*time.Second)
		if line["exit_status"] != test.want || line["signal"] != nil || line["timed_out"] != false || line["stopped"] != false {
			t.Fatalf("%v: %v", test.argv, line)
		}
		requireGoneAndClean(t, fixture, line)
	}
}

func TestCheckRunsNoShell(t *testing.T) {
	fixture := newCheckFixture(t)
	line := ended(t, fixture.args(t, 30, 1, 16384, "echo", "a; echo INJECTED", "$HOME"), 20*time.Second)
	if tail, complete := tailOf(line); tail != "a; echo INJECTED $HOME\n" || !complete {
		t.Fatalf("argv was interpreted: %q", tail)
	}
}

func TestCheckTimeoutStopsTheGroup(t *testing.T) {
	fixture := newCheckFixture(t)
	begin := time.Now()
	line := ended(t, fixture.args(t, 1, 1, 16384, "sleep", "30"), 20*time.Second)
	if line["timed_out"] != true || line["exit_status"] != nil || line["signal"] != "SIGINT" || line["stopped"] != false || time.Since(begin) > 10*time.Second {
		t.Fatalf("timeout: %v after %s", line, time.Since(begin))
	}
	requireGoneAndClean(t, fixture, line)
}

// grandchild runs ARGV that leaves a background grandchild, which ignores SIGINT as background
// jobs of a non-interactive shell do (P0 T1f), and returns its pid file.
func grandchild(fixture *checkFixture) (string, []string) {
	pidFile := filepath.Join(fixture.user, "grandchild.pid")
	return pidFile, []string{"sh", "-c", `sleep 60 & echo $! > "$0"; wait`, pidFile}
}

// waitFor waits until path exists: the command reached the point the test stops it at.
func waitFor(t *testing.T, path string) {
	t.Helper()
	for range 1000 {
		if info, err := os.Stat(path); err == nil && (info.Size() > 0 || !strings.HasSuffix(path, ".pid")) {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("%s did not appear", path)
}

func requireProcessGone(t *testing.T, pidFile string) {
	t.Helper()
	data, err := os.ReadFile(pidFile)
	if err != nil {
		t.Fatal(err)
	}
	var pid int
	fmt.Sscan(string(data), &pid)
	for range 100 {
		if err := syscall.Kill(pid, 0); err == syscall.ESRCH {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	syscall.Kill(pid, syscall.SIGKILL)
	t.Fatalf("grandchild %d survived the check", pid)
}

func TestCheckStopSignalsTheWholeGroup(t *testing.T) {
	fixture := newCheckFixture(t)
	pidFile, argv := grandchild(fixture)
	run := startCheck(t, fixture.args(t, 60, 1, 16384, argv...))
	started := run.next(t, 10*time.Second)
	if started["event"] != "started" || started["pgid"] == nil {
		t.Fatalf("started: %v", started)
	}
	waitFor(t, pidFile)
	run.stdin.WriteString(`{"stop":"signal"}` + "\n")
	line := run.next(t, 15*time.Second)
	run.finish(t, 5*time.Second)
	if line["event"] != "ended" || line["stopped"] != true || line["timed_out"] != false || line["exit_status"] != nil || line["signal"] == nil {
		t.Fatalf("stop: %v", line)
	}
	requireProcessGone(t, pidFile)
	requireGoneAndClean(t, fixture, line)
}

func TestCheckKillsAChildThatIgnoresSIGINTAfterGrace(t *testing.T) {
	fixture := newCheckFixture(t)
	ready := filepath.Join(fixture.user, "ready")
	run := startCheck(t, fixture.args(t, 60, 1, 16384, "sh", "-c", `trap "" INT; touch "$0"; sleep 30`, ready))
	run.next(t, 10*time.Second)
	waitFor(t, ready)
	begin := time.Now()
	run.stdin.WriteString(`{"stop":"signal"}` + "\n")
	line := run.next(t, 15*time.Second)
	run.finish(t, 5*time.Second)
	if line["signal"] != "SIGKILL" || line["stopped"] != true || time.Since(begin) < time.Second || time.Since(begin) > 8*time.Second {
		t.Fatalf("grace: %v after %s", line, time.Since(begin))
	}
	requireGoneAndClean(t, fixture, line)
}

func TestCheckStopKillIsImmediate(t *testing.T) {
	fixture := newCheckFixture(t)
	ready := filepath.Join(fixture.user, "ready")
	run := startCheck(t, fixture.args(t, 60, 30, 16384, "sh", "-c", `trap "" INT; touch "$0"; sleep 30`, ready))
	run.next(t, 10*time.Second)
	waitFor(t, ready)
	begin := time.Now()
	run.stdin.WriteString(`{"stop":"kill"}` + "\n")
	line := run.next(t, 10*time.Second)
	run.finish(t, 5*time.Second)
	if line["signal"] != "SIGKILL" || line["stopped"] != true || time.Since(begin) > 5*time.Second {
		t.Fatalf("kill: %v after %s", line, time.Since(begin))
	}
	requireGoneAndClean(t, fixture, line)
}

func TestCheckParentLostStopsTheCheck(t *testing.T) {
	fixture := newCheckFixture(t)
	pidFile, argv := grandchild(fixture)
	run := startCheck(t, fixture.args(t, 60, 1, 16384, argv...))
	run.next(t, 10*time.Second)
	waitFor(t, pidFile)
	begin := time.Now()
	run.stdin.Close()
	line := run.next(t, 10*time.Second)
	run.finish(t, 5*time.Second)
	if line["stopped"] != true || line["signal"] == nil || time.Since(begin) > 8*time.Second {
		t.Fatalf("parent lost: %v after %s", line, time.Since(begin))
	}
	requireProcessGone(t, pidFile)
	requireGoneAndClean(t, fixture, line)
}

func TestCheckTailIsBoundedOnAUTF8Boundary(t *testing.T) {
	fixture := newCheckFixture(t)
	// Stdout and stderr are merged in write order: 10 x, é (2 bytes) on stderr, then "end".
	argv := []string{"sh", "-c", `printf xxxxxxxxxx; printf '\303\251' >&2; printf end`}
	line := ended(t, fixture.args(t, 30, 1, 4, argv...), 20*time.Second)
	if tail, complete := tailOf(line); tail != "end" || complete {
		t.Fatalf("cut tail: %q %v", tail, complete)
	}
	line = ended(t, fixture.args(t, 30, 1, 5, argv...), 20*time.Second)
	if tail, complete := tailOf(line); tail != "éend" || complete {
		t.Fatalf("tail with the whole character: %q %v", tail, complete)
	}
	line = ended(t, fixture.args(t, 30, 1, 15, argv...), 20*time.Second)
	if tail, complete := tailOf(line); tail != "xxxxxxxxxxéend" || !complete {
		t.Fatalf("whole output: %q %v", tail, complete)
	}
	line = ended(t, fixture.args(t, 30, 1, 100, "sh", "-c", "head -c 300000 /dev/zero | tr '\\0' a; printf END"), 20*time.Second)
	if tail, complete := tailOf(line); tail != strings.Repeat("a", 97)+"END" || complete {
		t.Fatalf("long output: %d bytes, complete %v", len(tail), complete)
	}
}

func TestCheckRefusesACommandOutsideTheFolder(t *testing.T) {
	fixture := newCheckFixture(t)
	if err := os.Symlink("/bin/echo", filepath.Join(fixture.dest, "repo", "out")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(fixture.user, "gone"), filepath.Join(fixture.dest, "repo", "dangling")); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(fixture.dest, "repo", "ok.sh"), []byte("#!/bin/sh\necho ok\n"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("ok.sh", filepath.Join(fixture.dest, "repo", "inside")); err != nil {
		t.Fatal(err)
	}
	for argv0, want := range map[string]string{"../x": "leaves_folder", "repo/../../x": "leaves_folder", "/bin/echo": "leaves_folder",
		"repo/out": "leaves_folder", "repo/dangling": "leaves_folder", "no-such-tool-p6": "not_found", "repo/missing": "not_found"} {
		if why := refused(t, fixture.args(t, 30, 1, 16384, argv0)); why != want {
			t.Fatalf("%s: refused %s, want %s", argv0, why, want)
		}
		if _, err := os.Lstat(fixture.scratch()); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("%s: a refusal left the scratch: %v", argv0, err)
		}
	}
	if calls := fixture.recordedCalls(t); len(calls) != 0 {
		t.Fatalf("a refused check reached codex sandbox: %v", calls)
	}
	// A relative command inside the folder, through a link that stays inside, runs.
	for _, argv0 := range []string{"repo/ok.sh", "./repo/inside"} {
		if line := ended(t, fixture.args(t, 30, 1, 16384, argv0), 20*time.Second); line["exit_status"] != 0.0 {
			t.Fatalf("%s: %v", argv0, line)
		}
	}
}

func TestCheckRefusesWithoutAnAbsoluteCodex(t *testing.T) {
	fixture := newCheckFixture(t)
	// No codex on PATH at all.
	t.Setenv("PATH", "/usr/bin:/bin")
	if why := refused(t, fixture.args(t, 30, 1, 16384, "true")); why != "sandbox_unavailable" {
		t.Fatalf("no codex: %s", why)
	}
	// Only a relative codex (exec.ErrDot).
	t.Chdir(fixture.bin)
	t.Setenv("PATH", ".:/usr/bin:/bin")
	if why := refused(t, fixture.args(t, 30, 1, 16384, "true")); why != "sandbox_unavailable" {
		t.Fatalf("relative codex: %s", why)
	}
	if calls := fixture.recordedCalls(t); len(calls) != 0 {
		t.Fatalf("the command ran without the sandbox: %v", calls)
	}
	if _, err := os.Lstat(fixture.scratch()); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("a refusal left the scratch: %v", err)
	}
}

// checkCodexAdditions are the variables the installed `codex sandbox` adds to a command's
// environment beyond what it is given under the folder profile (P0 T1d, codex-cli 0.167.1; its
// network proxy).
var checkCodexAdditions = []string{"ALL_PROXY", "BUNDLE_HTTPS_PROXY", "BUNDLE_HTTP_PROXY", "BUNDLE_NO_PROXY",
	"CODEX_NETWORK_ALLOW_LOCAL_BINDING", "CODEX_NETWORK_PROXY_ACTIVE", "CODEX_SANDBOX", "DOCKER_HTTPS_PROXY", "DOCKER_HTTP_PROXY",
	"ELECTRON_GET_USE_PROXY", "FTP_PROXY", "GIT_SSH_COMMAND", "HTTPS_PROXY", "HTTP_PROXY", "NODE_USE_ENV_PROXY", "NO_PROXY",
	"NPM_CONFIG_HTTPS_PROXY", "NPM_CONFIG_HTTP_PROXY", "NPM_CONFIG_NOPROXY", "NPM_CONFIG_PROXY", "PIP_PROXY", "WSS_PROXY", "WS_PROXY",
	"YARN_HTTPS_PROXY", "YARN_HTTP_PROXY", "__CF_USER_TEXT_ENCODING", "all_proxy", "ftp_proxy", "http_proxy", "https_proxy", "no_proxy",
	"npm_config_http_proxy", "npm_config_https_proxy", "npm_config_noproxy", "npm_config_proxy", "ws_proxy", "wss_proxy"}

// checkNetworkDisabledMarker is the one entry `codex sandbox` adds under the read-only profile
// (network disabled) instead of the proxy variables: seen in HN, codex-cli 0.167.1. Only this exact
// entry is allowed; any other value, or any other new CODEX_* variable, fails the rule.
const checkNetworkDisabledMarker = "CODEX_SANDBOX_NETWORK_DISABLED=1"

// checkEnvironmentNames are the variable names a command under `host check` may see: preparation's
// environment, the codex additions, and what /bin/sh itself sets.
var checkEnvironmentNames = slices.Concat(preparationKept, checkCodexAdditions, []string{"TMPDIR", "XDG_CACHE_HOME",
	"npm_config_cache", "npm_config_userconfig", "npm_config_globalconfig", "npm_config_registry",
	"npm_config_update_notifier", "PWD", "SHLVL", "_", "OLDPWD"})

// checkEnvironmentAllows is the I-H3 environment rule HN applies to each `env` line of a checked command.
func checkEnvironmentAllows(entry string) bool {
	if strings.Contains(entry, "SENTINEL") {
		return false
	}
	if entry == checkNetworkDisabledMarker {
		return true
	}
	name, _, _ := strings.Cut(entry, "=")
	return slices.Contains(checkEnvironmentNames, name)
}

func TestCheckEnvironmentRule(t *testing.T) {
	for entry, want := range map[string]bool{
		"CODEX_SANDBOX_NETWORK_DISABLED=1":  true,
		"CODEX_SANDBOX_NETWORK_DISABLED=0":  false,
		"CODEX_SANDBOX_NETWORK_DISABLED=":   false,
		"CODEX_SANDBOX_NETWORK_DISABLED=11": false,
		"CODEX_SANDBOX_NETWORK_DISABLED":    false,
		"CODEX_TOKEN=1":                     false,
		"CODEX_API_KEY=x":                   false,
		"CODEX_SANDBOX=seatbelt":            true,
		"CODEX_NETWORK_PROXY_ACTIVE=1":      true,
		"HTTPS_PROXY=http://127.0.0.1:1":    true,
		"TMPDIR=/s/tmp":                     true,
		"GH_TOKEN=x":                        false,
		"ATLAS_RUNTIME_HOME=/h":             false,
		"PATH=/GH-SENTINEL":                 false,
	} {
		if got := checkEnvironmentAllows(entry); got != want {
			t.Errorf("checkEnvironmentAllows(%q) = %v, want %v", entry, got, want)
		}
	}
}

func TestCheckEnvironmentIsTheAllowList(t *testing.T) {
	fixture := newCheckFixture(t)
	for name, value := range map[string]string{"GH_TOKEN": "GH-SENTINEL", "ANTHROPIC_API_KEY": "API-SENTINEL",
		"NPM_TOKEN": "NPM-SENTINEL", "ATLAS_RUNTIME_EXECUTABLE": "/x/EXECUTABLE-SENTINEL", "LANG": "C"} {
		t.Setenv(name, value)
	}
	line := ended(t, fixture.args(t, 30, 1, 65536, "env"), 20*time.Second)
	tail, complete := tailOf(line)
	if !complete || strings.Contains(tail, "SENTINEL") || strings.Contains(tail, "ATLAS_RUNTIME_HOME") {
		t.Fatalf("environment leaked: %s", tail)
	}
	scratch := fixture.scratch()
	want := map[string]string{"HOME": fixture.user, "PATH": os.Getenv("PATH"), "LANG": "C", "CODEX_HOME": os.Getenv("CODEX_HOME"),
		"TMPDIR": filepath.Join(scratch, "tmp"), "XDG_CACHE_HOME": filepath.Join(scratch, "cache"), "npm_config_cache": filepath.Join(scratch, "npm-cache"),
		"npm_config_userconfig": filepath.Join(scratch, "user-npmrc"), "npm_config_globalconfig": filepath.Join(scratch, "global-npmrc"),
		"npm_config_registry": "https://" + snapshot.NPMRegistry + "/", "npm_config_update_notifier": "false"}
	for _, name := range []string{"USER", "LOGNAME", "LC_ALL", "LC_CTYPE"} {
		if value, present := os.LookupEnv(name); present {
			want[name] = value
		}
	}
	got := map[string]string{}
	for _, entry := range strings.Split(strings.TrimSuffix(tail, "\n"), "\n") {
		name, value, _ := strings.Cut(entry, "=")
		// Added by the stand-in's /bin/sh (the real codex sandbox adds P0 T1d's proxy variables, or under
		// read-only checkNetworkDisabledMarker, instead; HN applies checkEnvironmentAllows to those).
		if !slices.Contains([]string{"PWD", "SHLVL", "_", "OLDPWD", "__CF_USER_TEXT_ENCODING"}, name) {
			got[name] = value
		}
	}
	if !workspace.JSONEqual(toAny(want), toAny(got)) {
		t.Fatalf("environment\n got %v\nwant %v", got, want)
	}
}

func toAny(values map[string]string) map[string]any {
	result := map[string]any{}
	for key, value := range values {
		result[key] = value
	}
	return result
}

// scratchModeCommand prints the scratch directory's POSIX `ls -ld` mode string from inside the sandboxed
// command (portable across BSD and GNU userlands, unlike `stat -f`/`stat -c`), then writes in the folder.
const scratchModeCommand = `ls -ld "$(dirname "$TMPDIR")" | cut -c1-10; touch repo/written`

func TestCheckArgvIsTheTurnsProfile(t *testing.T) {
	fixture := newCheckFixture(t)
	scratch := fixture.scratch()
	line := ended(t, fixture.args(t, 30, 1, 16384, "sh", "-c", scratchModeCommand), 20*time.Second)
	if tail, _ := tailOf(line); tail != "drwx------\n" || line["exit_status"] != 0.0 {
		t.Fatalf("scratch mode: %q %v", tail, line)
	}
	inspector, err := os.Executable()
	if err == nil {
		inspector, err = filepath.EvalSymlinks(inspector)
	}
	if err != nil {
		t.Fatal(err)
	}
	folder, err := folderArguments(fixture.scope, scratch, fixture.user, inspector)
	if err != nil {
		t.Fatal(err)
	}
	if len(folder) != 8 || !strings.Contains(folder[3], quoted(fixture.home)+`="none"`) || !strings.Contains(folder[3], quoted(fixture.dest)+`="write"`) ||
		!strings.Contains(folder[3], "unix_sockets={"+quoted(scratch)+`="allow"}`) {
		t.Fatalf("folder profile: %v", folder)
	}
	codex := filepath.Join(fixture.bin, "codex")
	readOnly, err := sandboxArguments("read-only", fixture.dest, fixture.home)
	if err != nil {
		t.Fatal(err)
	}
	if len(readOnly) != 4 || strings.Contains(strings.Join(readOnly, " "), scratch) || !strings.Contains(readOnly[3], "network={enabled=false}") {
		t.Fatalf("read-only profile: %v", readOnly)
	}
	ended(t, fixture.readOnlyArgs(30, 1, 16384, "true"), 20*time.Second)
	want := [][]string{
		slices.Concat([]string{codex, "sandbox", "-P", "atlas_folder", "-C", fixture.dest}, folder, []string{"--", "sh", "-c", scratchModeCommand}),
		slices.Concat([]string{codex, "sandbox", "-P", "atlas_read_only", "-C", fixture.dest}, readOnly, []string{"--", "true"}),
	}
	if calls := fixture.recordedCalls(t); !slices.EqualFunc(calls, want, slices.Equal[[]string]) {
		t.Fatalf("argv\n got %q\nwant %q", calls, want)
	}
	if _, err := os.Lstat(scratch); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("read-only scratch left: %v", err)
	}
}

func TestCheckRemovesAStaleScratchFirst(t *testing.T) {
	fixture := newCheckFixture(t)
	scratch := fixture.scratch()
	if err := os.MkdirAll(filepath.Join(scratch, "sealed"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(scratch, "sealed", "STALE"), nil, 0400); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(filepath.Join(scratch, "sealed"), 0500); err != nil {
		t.Fatal(err)
	}
	line := ended(t, fixture.args(t, 30, 1, 16384, "ls", "-A", scratch), 20*time.Second)
	if tail, _ := tailOf(line); tail != "cache\nglobal-npmrc\nnpm-cache\ntmp\nuser-npmrc\n" {
		t.Fatalf("stale scratch kept: %q", tail)
	}
	requireGoneAndClean(t, fixture, line)
}

func TestCheckRefusesAChangedScopeOrBusyFolder(t *testing.T) {
	fixture := newCheckFixture(t)
	for _, test := range []struct {
		want   string
		change func(map[string]any)
	}{
		{"scope changed", func(scope map[string]any) {
			scope["record"] = filepath.Join(fixture.home, "materializations", "other.json")
		}},
		{"materialized-folder permission scope", func(scope map[string]any) { scope["profile"] = "review-packet" }},
		{"ATLAS_RUNTIME_HOME as its home", func(scope map[string]any) { scope["home"] = fixture.user }},
		{"scope changed", func(scope map[string]any) { scope["writable"] = filepath.Dir(fixture.dest) }},
	} {
		original := fixture.scope
		changed := map[string]any{}
		for key, value := range original {
			changed[key] = value
		}
		test.change(changed)
		fixture.scope = changed
		if err := Check(fixture.args(t, 30, 1, 16384, "true"), strings.NewReader(""), io.Discard); err == nil || !strings.Contains(err.Error(), test.want) {
			t.Fatalf("a changed scope was not refused with %q: %v", test.want, err)
		}
		fixture.scope = original
	}
	lock, _, err := workspace.Lock(fixture.dest, false)
	if err != nil {
		t.Fatal(err)
	}
	err = Check(fixture.args(t, 30, 1, 16384, "true"), strings.NewReader(""), io.Discard)
	lock.Close()
	if err == nil || !strings.Contains(err.Error(), "active Runtime owner") {
		t.Fatalf("busy folder: %v", err)
	}
	for _, args := range [][]string{
		fixture.args(t, 0, 1, 16384, "true"),
		fixture.args(t, 30, 1, checkMaxTail+1, "true"),
		{"--cwd", fixture.dest, "--sandbox", "workspace-write", "--scratch", fixture.scratch(), "--timeout", "1", "--grace", "1", "--tail", "1", "--", "true"},
		{"--cwd", fixture.dest, "--sandbox", "read-only", "--scratch", filepath.Join(fixture.user, "elsewhere"), "--timeout", "1", "--grace", "1", "--tail", "1", "--", "true"},
		append(fixture.args(t, 30, 1, 1)[:12], "true"),
	} {
		if err := Check(args, strings.NewReader(""), io.Discard); err == nil {
			t.Fatalf("usage error accepted: %q", args)
		}
	}
	if calls := fixture.recordedCalls(t); len(calls) != 0 {
		t.Fatalf("a refused setup ran: %v", calls)
	}
}

// TestCheckGivesTheCommandDefaultSIGINT starts the helper binary with SIGINT ignored, as a
// non-interactive shell starts a background job (P0 T1f); the check must still stop on SIGINT.
func TestCheckGivesTheCommandDefaultSIGINT(t *testing.T) {
	binary := filepath.Join(t.TempDir(), "atlas-runtime")
	if out, err := exec.Command("go", "build", "-o", binary, "github.com/eyra/atlas/platform/atlas_runtime/host").CombinedOutput(); err != nil {
		t.Fatalf("build: %v %s", err, out)
	}
	fixture := newCheckFixture(t)
	command := exec.Command("/bin/sh", append([]string{"-c", `trap "" INT; exec "$0" host check "$@"`, binary}, fixture.args(t, 60, 20, 16384, "sleep", "30")...)...)
	stdin, err := command.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	stdout, err := command.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err = command.Start(); err != nil {
		t.Fatal(err)
	}
	defer command.Process.Kill()
	lines := bufio.NewScanner(stdout)
	if !lines.Scan() || !strings.Contains(lines.Text(), `"event":"started"`) {
		t.Fatalf("started: %q", lines.Text())
	}
	time.Sleep(200 * time.Millisecond)
	begin := time.Now()
	io.WriteString(stdin, `{"stop":"signal"}`+"\n")
	if !lines.Scan() {
		t.Fatal("no ended line")
	}
	var line map[string]any
	if err := json.Unmarshal(lines.Bytes(), &line); err != nil {
		t.Fatal(err)
	}
	if line["signal"] != "SIGINT" || time.Since(begin) > 10*time.Second {
		t.Fatalf("SIGINT did not stop the check: %v after %s", line, time.Since(begin))
	}
	stdin.Close()
	if err := command.Wait(); err != nil {
		t.Fatalf("helper exit: %v", err)
	}
}
