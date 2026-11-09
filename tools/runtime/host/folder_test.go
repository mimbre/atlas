package host

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"slices"
	"strconv"
	"strings"
	"testing"

	"github.com/eyra/atlas/tools/runtime/snapshot"
	"github.com/eyra/atlas/tools/runtime/workspace"
)

// materialize records dest under home as snapshot Materialize would, for a snapshot of one
// empty repository "repo", and returns its materialized-folder scope.
func materialize(t *testing.T, home, dest string) map[string]any {
	t.Helper()
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
	scope, err := workspace.FolderScope(dest, home)
	if err != nil {
		t.Fatal(err)
	}
	return scope
}

func TestFolderProfileArgumentsAreTheEnforcementContract(t *testing.T) {
	user := isolatedHome(t)
	home := filepath.Join(user, "runtime")
	dest := filepath.Join(user, "work")
	scope := materialize(t, home, dest)
	token := filepath.Join(user, "code-home", "runtime.token")
	if err := os.WriteFile(filepath.Join(home, "code.json"), []byte(fmt.Sprintf(`{"url":"http://127.0.0.1:1","token_file":%q}`, token)), 0600); err != nil {
		t.Fatal(err)
	}
	scratch := filepath.Join(home, "scratch", "turn-1")
	inspector := filepath.Join(user, "bin", "atlas-runtime")
	args, err := folderArguments(scope, scratch, user, inspector)
	if err != nil {
		t.Fatal(err)
	}
	q := func(path string) string { body, _ := json.Marshal(path); return string(body) }
	filesystem := []string{q(dest) + `="write"`, q(scratch) + `="write"`, q(home) + `="none"`,
		q(scope["record"].(string)) + `="read"`, q(scope["baseline"].(string)) + `="read"`,
		q(dest+"/.git") + `="none"`, q(dest+"/repo/.git") + `="none"`,
		q(token) + `="none"`, q(filepath.Dir(token)) + `="none"`}
	for _, name := range credentialPaths {
		filesystem = append(filesystem, q(filepath.Join(user, name))+`="none"`)
	}
	want := []string{"-c", `default_permissions="atlas_folder"`, "-c",
		`permissions={atlas_folder={extends=":read-only",filesystem={` + strings.Join(filesystem, ",") + `},network={enabled=true,allow_local_binding=true}}}`,
		"-c", "features.network_proxy=true"}
	if !slices.Equal(args, want) {
		t.Fatalf("got  %q\nwant %q", args, want)
	}
	if routed, err := permissionArguments(scope, scratch, inspector); err != nil || !slices.Equal(routed, want) {
		t.Fatalf("profile dispatch differs: %q %v", routed, err)
	}
	for _, unknown := range []any{map[string]any{"profile": "other", "root": dest}, map[string]any{"root": dest}} {
		if _, err := permissionArguments(unknown, scratch, inspector); err == nil || err.Error() != "Unknown permission profile" {
			t.Fatalf("unknown profile accepted: %v", err)
		}
	}
	// An inspector inside the denied home gets read on exactly that file; workers must not be able to replace it.
	inside := filepath.Join(home, "atlas-runtime")
	if args, err = folderArguments(scope, scratch, user, inside); err != nil {
		t.Fatal(err)
	}
	granted := `permissions={atlas_folder={extends=":read-only",filesystem={` + strings.Join(append(filesystem, q(inside)+`="read"`), ",") + `},network={enabled=true,allow_local_binding=true}}}`
	if !slices.Equal(args, append(want[:3:3], granted, "-c", "features.network_proxy=true")) {
		t.Fatalf("inspector grant: got %q\nwant %q", args, granted)
	}
	for _, writable := range []string{dest, scratch} {
		executable := filepath.Join(writable, "atlas-runtime")
		if _, err := folderArguments(scope, scratch, user, executable); err == nil || err.Error() != "Runtime executable "+executable+
			" is inside worker-writable "+writable+"; install atlas-runtime outside the materialized folder and worker temp" {
			t.Fatalf("writable inspector accepted: %v", err)
		}
	}
	// A token directory that contains the writable folder cannot be denied without denying the folder.
	if err := os.WriteFile(filepath.Join(home, "code.json"), []byte(fmt.Sprintf(`{"token_file":%q}`, filepath.Join(user, "t"))), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := folderArguments(scope, scratch, user, inspector); err == nil || !strings.Contains(err.Error(), "Code token directory") {
		t.Fatalf("token directory containing the folder accepted: %v", err)
	}
}

// folderLaunch prepares a materialized folder, a fake native Codex and a logging Git on PATH.
func folderLaunch(t *testing.T, body string) (dest, home, folder, native, gitLog string, scope map[string]any) {
	t.Helper()
	user := isolatedHome(t)
	home, dest = filepath.Join(user, "runtime"), filepath.Join(user, "work")
	scope = materialize(t, home, dest)
	shims := filepath.Join(user, "shims")
	gitLog = filepath.Join(user, "git.log")
	if err := os.Mkdir(shims, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(shims, "git"), []byte("#!/bin/sh\necho \"$@\" >> "+gitLog+"\nexit 1\n"), 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", shims+":"+os.Getenv("PATH"))
	folder = t.TempDir()
	native = fixture(t, folder, body)
	return
}

func TestFolderLaunchRunsNoGitAndOwnsLockAndScratchUntilReaped(t *testing.T) {
	dest, home, folder, native, gitLog, scope := folderLaunch(t, `env > "$0.env"
printf '%s\n' "$@" > "$0.args"
printf '%s\n' '{"type":"thread.started","thread_id":"native-session"}'
sleep 60 </dev/null >/dev/null 2>&1 &
wait
`)
	scratch := filepath.Join(home, "scratch", filepath.Base(folder))
	// A stale inherited value must not reach the worker; the host supplies its own executable.
	t.Setenv("ATLAS_RUNTIME_EXECUTABLE", "/stale/atlas-runtime")
	host := startHost(t, scopedArgs(t, native, dest, folder, scope))
	started := host.record(t)
	if event := host.record(t); event["type"] != "runtime.event" {
		t.Fatalf("native event not forwarded: %v", event)
	}
	if lock, _, err := workspace.Lock(dest, false); err == nil || !strings.Contains(err.Error(), "active Runtime owner") {
		if lock != nil {
			lock.Close()
		}
		t.Fatalf("running group must own the folder: %v", err)
	}
	if info, err := os.Stat(scratch); err != nil || info.Mode().Perm() != 0700 {
		t.Fatalf("owned scratch missing while running: %v %v", info, err)
	}
	var process struct {
		PID             int      `json:"pid"`
		Command         []string `json:"command"`
		NativeTemporary string   `json:"native_temporary"`
	}
	raw, err := os.ReadFile(filepath.Join(folder, "process.json"))
	if err != nil || json.Unmarshal(raw, &process) != nil {
		t.Fatalf("process evidence: %s %v", raw, err)
	}
	// The native CLI is the group leader itself: no pre-exec child, so no Git preparation.
	if started["pid"] != float64(process.PID) || process.Command[0] != native || process.NativeTemporary != scratch ||
		!slices.Contains(process.Command, `default_permissions="atlas_folder"`) {
		t.Fatalf("unexpected launch evidence: %+v %v", process, started)
	}
	host.stdin.Close()
	records, code := host.finish(t)
	if code != 0 || records[len(records)-1]["stopped"] != true {
		t.Fatalf("code=%d records=%v stderr=%s", code, records, host.stderr.String())
	}
	environment, err := os.ReadFile(native + ".env")
	if err != nil {
		t.Fatal(err)
	}
	self, _ := os.Executable()
	self, _ = filepath.EvalSymlinks(self)
	for _, want := range []string{"TMPDIR=" + scratch + "/tmp", "GOCACHE=" + scratch + "/go-build", "GOTMPDIR=" + scratch + "/go-tmp",
		"XDG_CACHE_HOME=" + scratch + "/cache", "npm_config_cache=" + scratch + "/npm", "ATLAS_RUNTIME_HOME=" + home,
		"PATH=" + filepath.Dir(self) + ":", "ATLAS_RUNTIME_EXECUTABLE=" + self + "\n"} {
		if !strings.Contains(string(environment), "\n"+want) && !strings.HasPrefix(string(environment), want) {
			t.Fatalf("worker environment lacks %q:\n%s", want, environment)
		}
	}
	if _, err := os.Stat(scratch); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("scratch not removed after reaping: %v", err)
	}
	lock, _, err := workspace.Lock(dest, false)
	if err != nil {
		t.Fatalf("lock not released after the group was reaped: %v", err)
	}
	lock.Close()
	if log, err := os.ReadFile(gitLog); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("Git ran: %s %v", log, err)
	}

	// Continuation resumes the confirmed session with the same profile and still no Git.
	fixture(t, folder, `printf '%s\n' "$@" > "$0.args"
printf '%s\n' '{"type":"thread.started","thread_id":"native-session"}' '{"type":"turn.completed"}'
`)
	args := scopedArgs(t, native, dest, folder, scope)
	args[5] = "native-session"
	records, code = startHost(t, args).finish(t)
	if code != 0 || records[len(records)-1]["exit_code"] != 0.0 {
		t.Fatalf("continuation failed: code=%d records=%v", code, records)
	}
	if argv, _ := os.ReadFile(native + ".args"); !strings.Contains(string(argv), "resume\n") || !strings.Contains(string(argv), `default_permissions="atlas_folder"`) {
		t.Fatalf("continuation argv: %s", argv)
	}
	if log, err := os.ReadFile(gitLog); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("Git ran on continuation: %s %v", log, err)
	}
}

func TestFolderLaunchRefusesChangedScope(t *testing.T) {
	dest, home, folder, native, gitLog, scope := folderLaunch(t, "touch \"$0.executed\"\n")
	changed := map[string]any{}
	for key, value := range scope {
		changed[key] = value
	}
	changed["snapshot_id"] = "sha256:" + strings.Repeat("0", 64)
	host := startHost(t, scopedArgs(t, native, dest, folder, changed))
	if records, code := host.finish(t); code != 1 || len(records) != 0 ||
		!strings.Contains(host.stderr.String(), "Materialized folder permission scope changed") {
		t.Fatalf("changed scope not refused: code=%d records=%v stderr=%s", code, records, host.stderr.String())
	}
	if diagnostic, _ := os.ReadFile(filepath.Join(folder, "stderr.log")); string(diagnostic) != "Materialized folder permission scope changed" {
		t.Fatalf("refusal must reach stderr.log: %q", diagnostic)
	}
	if _, err := os.Stat(native + ".executed"); err == nil {
		t.Fatal("native CLI executed despite a refusal")
	}
	if _, err := os.Stat(filepath.Join(home, "scratch", filepath.Base(folder))); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("refused launch left scratch: %v", err)
	}
	lock, _, err := workspace.Lock(dest, false)
	if err != nil {
		t.Fatalf("refused launch kept the lock: %v", err)
	}
	lock.Close()
	if log, err := os.ReadFile(gitLog); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("Git ran: %s %v", log, err)
	}
}

func TestFolderLaunchRefusesAnInspectorWorkersCanReplace(t *testing.T) {
	dest, home, folder, native, _, scope := folderLaunch(t, "touch \"$0.executed\"\n")
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	binary, err := os.ReadFile(self)
	if err != nil {
		t.Fatal(err)
	}
	inside := filepath.Join(dest, "atlas-runtime")
	if err = os.WriteFile(inside, binary, 0700); err != nil {
		t.Fatal(err)
	}
	command := exec.Command(inside, append([]string{"native-host"}, scopedArgs(t, native, dest, folder, scope)...)...)
	command.Env = append(os.Environ(), "ATLAS_NATIVE_HOST_TEST=1")
	out, err := command.CombinedOutput()
	want := "Runtime executable " + inside + " is inside worker-writable " + dest + "; install atlas-runtime outside the materialized folder and worker temp"
	if err == nil || !strings.Contains(string(out), want) {
		t.Fatalf("inspector inside the folder not refused: %v %s", err, out)
	}
	if _, err := os.Stat(native + ".executed"); err == nil {
		t.Fatal("native CLI executed despite a refusal")
	}
	if _, err := os.Stat(filepath.Join(home, "scratch", filepath.Base(folder))); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("refused launch left scratch: %v", err)
	}
}

// claudeFolder materializes a folder outside every system temp root, beneath the real home
// whose private temp path fits the 44-byte limit, with a logging Git first on PATH.
func claudeFolder(t *testing.T) (dest, home, gitLog string, scope map[string]any) {
	t.Helper()
	user, err := os.UserHomeDir()
	if err != nil {
		t.Fatal(err)
	}
	if user, err = filepath.EvalSymlinks(user); err != nil {
		t.Fatal(err)
	}
	if len(user+"/.ac-xxxxxxxx/claude-"+strconv.Itoa(os.Getuid())) > 44 {
		t.Skipf("home %s is too long for a Claude private temp", user)
	}
	// The user's Codex home stays the Codex home, not a project config above the folder.
	t.Setenv("CODEX_HOME", filepath.Join(user, ".codex"))
	root, err := os.MkdirTemp(user, ".atlas-host-test-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(root) })
	home, dest = filepath.Join(root, "runtime"), filepath.Join(root, "work")
	scope = materialize(t, home, dest)
	shims := t.TempDir()
	gitLog = filepath.Join(shims, "git.log")
	if err := os.WriteFile(filepath.Join(shims, "git"), []byte("#!/bin/sh\necho \"$@\" >> "+gitLog+"\nexit 1\n"), 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", shims+":"+os.Getenv("PATH"))
	return
}

func TestClaudeFolderSettingsAreTheEnforcementContract(t *testing.T) {
	user := isolatedHome(t)
	// Claude denies writes below system temp roots; keep the fake user's folder outside TMPDIR.
	system := t.TempDir()
	t.Setenv("TMPDIR", system)
	t.Setenv("CLAUDE_CONFIG_DIR", "")
	home, dest := filepath.Join(user, "runtime"), filepath.Join(user, "work")
	scope := materialize(t, home, dest)
	token := filepath.Join(user, "code-home", "runtime.token")
	if err := os.WriteFile(filepath.Join(home, "code.json"), []byte(fmt.Sprintf(`{"url":"http://127.0.0.1:1","token_file":%q}`, token)), 0600); err != nil {
		t.Fatal(err)
	}
	temporary := "/u/.ac-12345678"
	inspector := filepath.Join(user, "bin", "atlas-runtime")
	encoded, err := claudeFolderSettings(scope, temporary, user, inspector)
	if err != nil {
		t.Fatal(err)
	}
	var roots []string
	for _, path := range []string{"/tmp", "/var/tmp", system} {
		resolved, _ := resolvePath(path)
		if !slices.Contains(roots, resolved) {
			roots = append(roots, resolved)
		}
	}
	slices.Sort(roots)
	record, baseline := scope["record"].(string), scope["baseline"].(string)
	protected := []string{home, dest + "/.git", dest + "/repo/.git", token, filepath.Dir(token), user + "/.claude"}
	for _, name := range credentialPaths {
		if name != ".claude" {
			protected = append(protected, filepath.Join(user, name))
		}
	}
	var rules []string
	for _, path := range protected {
		rules = append(rules, "Read(/"+path+")")
	}
	q := func(values ...string) string { body, _ := json.Marshal(values); return string(body) }
	want := func(granted ...string) string {
		return `{"sandbox":{"enabled":true,"failIfUnavailable":true,"allowUnsandboxedCommands":false,"excludedCommands":[],` +
			`"filesystem":{"allowWrite":` + q(dest, temporary) + `,"denyWrite":` + q(append(append(roots, protected...), record, baseline)...) +
			`,"denyRead":` + q(protected...) + `,"allowRead":` + q(append([]string{record, baseline, user + "/.claude/shell-snapshots", user + "/.claude/session-env"}, granted...)...) +
			`},"network":{"allowedDomains":[],"strictAllowlist":true,"allowAllUnixSockets":false,"allowLocalBinding":true}},` +
			`"permissions":{"deny":` + q(rules...) + `}}`
	}
	if encoded != want() {
		t.Fatalf("got  %s\nwant %s", encoded, want())
	}
	// An inspector inside the denied home gets read on exactly that file; workers must not be able to replace it.
	inside := filepath.Join(home, "atlas-runtime")
	if encoded, err = claudeFolderSettings(scope, temporary, user, inside); err != nil || encoded != want(inside) {
		t.Fatalf("inspector grant: %v\ngot  %s\nwant %s", err, encoded, want(inside))
	}
	// A rebound folder's worker reads the rebind's done marker for status and diff, never its journal.
	marker := snapshot.RebindMarker(scope["home"].(string), scope["root"].(string))
	if err := os.MkdirAll(filepath.Dir(marker), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(marker, []byte(dest+"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(filepath.Dir(marker), "journal.json"), []byte(`{"phase":"done"}`), 0600); err != nil {
		t.Fatal(err)
	}
	rebound := strings.Replace(want(marker), q(baseline)[1:]+`,"denyRead"`, q(baseline, marker)[1:]+`,"denyRead"`, 1)
	if encoded, err = claudeFolderSettings(scope, temporary, user, inspector); err != nil || encoded != rebound {
		t.Fatalf("done marker grant: %v\ngot  %s\nwant %s", err, encoded, rebound)
	}
	if err := os.RemoveAll(filepath.Join(home, "rebinds")); err != nil {
		t.Fatal(err)
	}
	for _, writable := range []string{dest, temporary} {
		executable := filepath.Join(writable, "atlas-runtime")
		if _, err := claudeFolderSettings(scope, temporary, user, executable); err == nil || err.Error() != "Runtime executable "+executable+
			" is inside worker-writable "+writable+"; install atlas-runtime outside the materialized folder and worker temp" {
			t.Fatalf("writable inspector accepted: %v", err)
		}
	}

	incomplete := map[string]any{}
	for key, value := range scope {
		if key != "record" {
			incomplete[key] = value
		}
	}
	if _, err := claudeFolderSettings(incomplete, temporary, user, inspector); err == nil || err.Error() != "Materialized folder scope is incomplete" {
		t.Fatalf("incomplete scope accepted: %v", err)
	}
	if _, err := claudeFolderSettings(scope, "/"+strings.Repeat("x", 44), user, inspector); err == nil ||
		err.Error() != "Claude private native temp path exceeds the 44-byte child-temp limit" {
		t.Fatalf("long private temp accepted: %v", err)
	}
	// A protected token directory containing the folder would also deny writing it.
	if err := os.WriteFile(filepath.Join(home, "code.json"), []byte(fmt.Sprintf(`{"token_file":%q}`, filepath.Join(user, "t"))), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := claudeFolderSettings(scope, temporary, user, inspector); err == nil || err.Error() != "Protected path "+user+" contains "+dest {
		t.Fatalf("token directory containing the folder accepted: %v", err)
	}
	t.Setenv("TMPDIR", user)
	if _, err := claudeFolderSettings(scope, temporary, user, inspector); err == nil ||
		err.Error() != "Claude materialized folders must be outside system temporary directories" {
		t.Fatalf("folder inside a system temp root accepted: %v", err)
	}
}

func TestClaudeFolderLaunchRunsNoGitAndBindsTheScopeContext(t *testing.T) {
	dest, home, gitLog, scope := claudeFolder(t)
	user := filepath.Dir(filepath.Dir(dest))
	folder := t.TempDir()
	native := fixture(t, folder, `env > "$0.env"
printf '%s\n' "$@" > "$0.args"
pwd -P > "$0.cwd"
test -f "${0%/native}/claude-context.json" || exit 9
printf '%s\n' '{"type":"result","result":"done"}'
`)
	args := claudeScopedArgs(t, native, dest, folder, scope)
	// A stale inherited value must not reach the worker; the host supplies its own executable.
	t.Setenv("ATLAS_RUNTIME_EXECUTABLE", "/stale/atlas-runtime")
	host := startHost(t, args)
	records, code := host.finish(t)
	if code != 0 || records[len(records)-1]["exit_code"] != 0.0 {
		t.Fatalf("code=%d records=%v stderr=%s", code, records, host.stderr.String())
	}
	environment, err := os.ReadFile(native + ".env")
	if err != nil {
		t.Fatal(err)
	}
	temporary := ""
	for _, line := range strings.Split(string(environment), "\n") {
		if value, found := strings.CutPrefix(line, "CLAUDE_CODE_TMPDIR="); found {
			temporary = value
		}
	}
	if filepath.Dir(temporary) != user || !strings.HasPrefix(filepath.Base(temporary), ".ac-") {
		t.Fatalf("private temp %q is not under the user home", temporary)
	}
	self, _ := os.Executable()
	self, _ = filepath.EvalSymlinks(self)
	for _, want := range []string{"TMPDIR=" + temporary + "/tmp", "GOCACHE=" + temporary + "/go-build", "GOTMPDIR=" + temporary + "/go-tmp",
		"XDG_CACHE_HOME=" + temporary + "/cache", "npm_config_cache=" + temporary + "/npm", "ATLAS_RUNTIME_HOME=" + home,
		"PATH=" + filepath.Dir(self) + ":", "ATLAS_RUNTIME_EXECUTABLE=" + self + "\n"} {
		if !strings.Contains(string(environment), "\n"+want) && !strings.HasPrefix(string(environment), want) {
			t.Fatalf("worker environment lacks %q:\n%s", want, environment)
		}
	}
	argv, _ := os.ReadFile(native + ".args")
	lines := strings.Split(string(argv), "\n")
	var settings struct {
		Sandbox struct {
			Filesystem struct{ AllowWrite, DenyRead []string }
		}
		Permissions struct{ Deny []string }
	}
	if index := slices.Index(lines, "--settings"); index < 0 || json.Unmarshal([]byte(lines[index+1]), &settings) != nil ||
		!slices.Equal(settings.Sandbox.Filesystem.AllowWrite, []string{dest, temporary}) ||
		!slices.Contains(settings.Sandbox.Filesystem.DenyRead, home) || !slices.Contains(settings.Permissions.Deny, "Read(/"+dest+"/repo/.git)") {
		t.Fatalf("settings in argv %q", argv)
	}
	if !slices.Contains(lines, "Bash,Read,Glob,Grep") || slices.Contains(lines, "Edit") {
		t.Fatalf("tools in argv %q", argv)
	}
	if cwd, _ := os.ReadFile(native + ".cwd"); string(cwd) != dest+"\n" {
		t.Fatalf("native must run in the folder: %q", cwd)
	}
	var process struct {
		Command         []string `json:"command"`
		NativeTemporary string   `json:"native_temporary"`
	}
	raw, _ := os.ReadFile(filepath.Join(folder, "process.json"))
	// The native CLI is the group leader itself: no pre-exec child, so no Git context discovery.
	if json.Unmarshal(raw, &process) != nil || process.Command[0] != native || process.NativeTemporary != temporary {
		t.Fatalf("process evidence %s", raw)
	}
	if _, err := os.Stat(temporary); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("private temp survived the reaped group: %v", err)
	}
	data, _ := os.ReadFile(filepath.Join(folder, "claude-context.json"))
	saved, err := argument(string(data))
	if err != nil {
		t.Fatal(err)
	}
	want, _ := argument(encode(t, map[string]any{"cwd": dest, "git": nil, "permissions": scope}))
	if !workspace.JSONEqual(saved, want) {
		t.Fatalf("saved context %s", data)
	}

	// Continuation resumes the confirmed session against the same scope context, still without Git.
	fixture(t, folder, `printf '%s\n' "$@" > "$0.args"
printf '%s\n' '{"type":"system","subtype":"init","session_id":"`+claudeSession+`","model":"m"}' '{"type":"result","result":"done"}'
`)
	args[5], args[9], args[10] = claudeSession, `"m"`, encode(t, saved)
	host = startHost(t, args)
	if records, code = host.finish(t); code != 0 || records[len(records)-1]["exit_code"] != 0.0 {
		t.Fatalf("continuation failed: code=%d records=%v stderr=%s", code, records, host.stderr.String())
	}
	if argv, _ := os.ReadFile(native + ".args"); !strings.Contains(string(argv), "--resume\n"+claudeSession+"\n") {
		t.Fatalf("continuation argv %s", argv)
	}

	// A drifted saved context or a rebound snapshot refuses before the native CLI runs.
	fixture(t, folder, "touch \"$0.executed\"\n")
	changed := map[string]any{}
	for key, value := range scope {
		changed[key] = value
	}
	changed["snapshot_id"] = "sha256:" + strings.Repeat("0", 64)
	before, _ := filepath.Glob(filepath.Join(user, ".ac-*"))
	for _, refusal := range []struct {
		scope   map[string]any
		context any
		message string
	}{
		{scope, map[string]any{"cwd": dest, "git": nil, "permissions": nil}, "Saved Claude working directory, repository identity or permission scope changed"},
		{changed, saved, "Materialized folder permission scope changed"},
	} {
		args := claudeScopedArgs(t, native, dest, folder, refusal.scope)
		args[5], args[9], args[10] = claudeSession, `"m"`, encode(t, refusal.context)
		host := startHost(t, args)
		if records, code := host.finish(t); code != 1 || len(records) != 0 || host.stderr.String() != "Native runner: "+refusal.message+"\n" {
			t.Fatalf("%s: code=%d records=%v stderr=%q", refusal.message, code, records, host.stderr.String())
		}
		if diagnostic, _ := os.ReadFile(filepath.Join(folder, "stderr.log")); string(diagnostic) != refusal.message {
			t.Fatalf("refusal must reach stderr.log: %q", diagnostic)
		}
	}
	if _, err := os.Stat(native + ".executed"); err == nil {
		t.Fatal("native CLI executed despite a refusal")
	}
	if after, _ := filepath.Glob(filepath.Join(user, ".ac-*")); !slices.Equal(after, before) {
		t.Fatalf("refused launch left a private temp: %v", after)
	}
	if after, _ := os.ReadFile(filepath.Join(folder, "claude-context.json")); string(after) != string(data) {
		t.Fatalf("refusal rewrote the saved context: %s", after)
	}
	lock, _, err := workspace.Lock(dest, false)
	if err != nil {
		t.Fatalf("lock not released: %v", err)
	}
	lock.Close()
	if log, err := os.ReadFile(gitLog); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("Git ran: %s %v", log, err)
	}
}

// TestFolderProfileIsEnforcedByInstalledCodexSandbox runs real worker commands under the
// installed Codex seatbelt with the exact profile arguments; fake user and Runtime homes hold sentinels.
// The inspector lives inside the denied Runtime home, like the dedicated deployment's binary, and an
// older stale `atlas-runtime` comes first on PATH.
func TestFolderProfileIsEnforcedByInstalledCodexSandbox(t *testing.T) {
	codex, err := exec.LookPath("codex")
	if runtime.GOOS != "darwin" || err != nil {
		t.Skip("requires the installed Codex CLI on macOS")
	}
	user := isolatedHome(t)
	home, dest := filepath.Join(user, "runtime"), filepath.Join(user, "work")
	scope := materialize(t, home, dest)
	inspector := filepath.Join(home, "atlas-runtime")
	if out, err := exec.Command("go", "build", "-o", inspector, "github.com/eyra/atlas/tools/runtime").CombinedOutput(); err != nil {
		t.Fatalf("build: %v %s", err, out)
	}
	bin := t.TempDir()
	if err := os.WriteFile(filepath.Join(bin, "atlas-runtime"), []byte("#!/bin/sh\necho STALE-CLI\nexit 3\n"), 0700); err != nil {
		t.Fatal(err)
	}
	token := filepath.Join(user, "code-home", "runtime.token")
	sentinels := map[string]string{
		token:                                             "TOKEN-SENTINEL",
		filepath.Join(home, "code.json"):                  fmt.Sprintf(`{"url":"http://127.0.0.1:1","token_file":%q}`, token),
		filepath.Join(user, ".ssh", "id"):                 "SSH-SENTINEL",
		filepath.Join(user, ".codex", "auth.json"):        "AUTH-SENTINEL",
		filepath.Join(user, ".config", "gh", "hosts.yml"): "GH-SENTINEL",
	}
	for path, body := range sentinels {
		if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(body), 0600); err != nil {
			t.Fatal(err)
		}
	}
	scratch := filepath.Join(home, "scratch", "turn-sandbox")
	if err := os.MkdirAll(filepath.Join(scratch, "tmp"), 0700); err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.Write([]byte("reachable")) }))
	defer server.Close()
	args, err := folderArguments(scope, scratch, user, inspector)
	if err != nil {
		t.Fatal(err)
	}
	environment := append(os.Environ(), "ATLAS_RUNTIME_HOME="+home, "ATLAS_RUNTIME_EXECUTABLE="+inspector,
		"TMPDIR="+filepath.Join(scratch, "tmp"), "PATH="+bin+":"+os.Getenv("PATH"))
	shell := func(sandboxed bool, script string) (string, error) {
		command := exec.Command("sh", "-c", script)
		if sandboxed {
			command = exec.Command(codex, append(append([]string{"sandbox", "-P", "atlas_folder", "-C", dest}, args...), "--", "sh", "-c", script)...)
		}
		command.Dir, command.Env = dest, environment
		out, err := command.CombinedOutput()
		return string(out), err
	}
	record, baseline := scope["record"].(string), scope["baseline"].(string)
	for _, probe := range []struct {
		script  string
		allowed bool
	}{
		{"echo edit > repo/new.txt && cat repo/new.txt", true},
		{`echo scratch > "$TMPDIR/f" && cat "$TMPDIR/f"`, true},
		{fmt.Sprintf("cat %q %q/manifest.json %q/complete", record, baseline, baseline), true},
		{fmt.Sprintf("cat %q", filepath.Join(home, "code.json")), false},
		{fmt.Sprintf("ls %q", home), false},
		{fmt.Sprintf("cat %q", token), false},
		{fmt.Sprintf("ls %q", filepath.Dir(token)), false},
		{fmt.Sprintf("cat %q", filepath.Join(user, ".ssh", "id")), false},
		{fmt.Sprintf("cat %q", filepath.Join(user, ".codex", "auth.json")), false},
		{fmt.Sprintf("cat %q", filepath.Join(user, ".config", "gh", "hosts.yml")), false},
		{fmt.Sprintf("echo x > %q", record), false},
		{fmt.Sprintf("touch %q", filepath.Join(home, "planted")), false},
		{"mkdir repo/.git", false},
		{"mkdir .git", false},
		// Loopback is open (listen and connect); everything external stays blocked, directly or via the proxy.
		{"curl -sS -m 5 " + server.URL, true},
		{`python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); s.listen(1)'`, true},
		{"curl -sS -f -m 8 https://example.com", false},
		{"curl -sS -m 5 --noproxy '*' https://1.1.1.1", false},
	} {
		out, err := shell(true, probe.script)
		t.Logf("sandboxed %q: err=%v output=%q", probe.script, err, out)
		if (err == nil) != probe.allowed {
			t.Fatalf("sandboxed %q: allowed=%v want %v: %s", probe.script, err == nil, probe.allowed, out)
		}
		if !probe.allowed && strings.Contains(out, "SENTINEL") {
			t.Fatalf("sandboxed %q leaked a sentinel: %s", probe.script, out)
		}
	}
	// Bare `atlas-runtime` resolves to the stale CLI; the explicit inspector runs from inside the denied home.
	if out, err := shell(true, "atlas-runtime snapshot status --dest "+dest); err == nil || !strings.Contains(out, "STALE-CLI") {
		t.Fatalf("PATH did not select the stale CLI: %v %s", err, out)
	}
	out, err := shell(true, `"$ATLAS_RUNTIME_EXECUTABLE" snapshot status --dest `+dest)
	if err != nil || !strings.Contains(out, `"path":"repo/new.txt"`) || !strings.Contains(out, `"change":"added"`) {
		t.Fatalf("sandboxed snapshot status: %v %s", err, out)
	}
	if out, err = shell(true, `"$ATLAS_RUNTIME_EXECUTABLE" snapshot diff --dest `+dest); err != nil || !strings.Contains(out, "+edit") {
		t.Fatalf("sandboxed snapshot diff: %v %s", err, out)
	}
	if out, err = shell(true, fmt.Sprintf("cat %q", filepath.Join(home, "code.json"))); err == nil || strings.Contains(out, "token_file") {
		t.Fatalf("inspector grant exposed its sibling: %v %s", err, out)
	}
	// Positive controls: the same reads and request succeed outside the sandbox.
	for _, script := range []string{
		fmt.Sprintf("cat %q %q %q", filepath.Join(home, "code.json"), token, filepath.Join(user, ".ssh", "id")),
		"curl -sS -m 5 " + server.URL,
	} {
		if out, err := shell(false, script); err != nil {
			t.Fatalf("unsandboxed control %q failed: %v %s", script, err, out)
		}
	}
}
