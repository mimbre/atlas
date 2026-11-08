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
	"strings"
	"testing"

	"github.com/eyra/atlas/tools/runtime/workspace"
)

// materialize records dest under home as snapshot Materialize would, for a snapshot of one
// empty repository "repo", and returns its materialized-folder scope.
func materialize(t *testing.T, home, dest string) map[string]any {
	t.Helper()
	manifest := `{"entries":[],"repositories":[{"commit":"` + strings.Repeat("a", 40) + `","path":"repo","repository":"r"}]}`
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
	args, err := folderArguments(scope, scratch, user)
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
		`permissions={atlas_folder={extends=":read-only",filesystem={` + strings.Join(filesystem, ",") + `},network={enabled=false}}}`}
	if !slices.Equal(args, want) {
		t.Fatalf("got  %q\nwant %q", args, want)
	}
	if routed, err := permissionArguments(scope, scratch); err != nil || !slices.Equal(routed, want) {
		t.Fatalf("profile dispatch differs: %q %v", routed, err)
	}
	for _, unknown := range []any{map[string]any{"profile": "other", "root": dest}, map[string]any{"root": dest}} {
		if _, err := permissionArguments(unknown, scratch); err == nil || err.Error() != "Unknown permission profile" {
			t.Fatalf("unknown profile accepted: %v", err)
		}
	}
	// A token directory that contains the writable folder cannot be denied without denying the folder.
	if err := os.WriteFile(filepath.Join(home, "code.json"), []byte(fmt.Sprintf(`{"token_file":%q}`, filepath.Join(user, "t"))), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := folderArguments(scope, scratch, user); err == nil || !strings.Contains(err.Error(), "Code token directory") {
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
	for _, want := range []string{"TMPDIR=" + scratch + "/tmp", "GOCACHE=" + scratch + "/go-build", "GOTMPDIR=" + scratch + "/go-tmp",
		"XDG_CACHE_HOME=" + scratch + "/cache", "npm_config_cache=" + scratch + "/npm", "ATLAS_RUNTIME_HOME=" + home,
		"PATH=" + filepath.Dir(self) + ":"} {
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

func TestFolderLaunchRefusesChangedScopeAndClaude(t *testing.T) {
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
	args := scopedArgs(t, native, dest, folder, scope)
	args[8] = "claude"
	host = startHost(t, args)
	if _, code := host.finish(t); code != 1 || !strings.Contains(host.stderr.String(), "Claude supports only the dedicated-repository permission profile") {
		t.Fatalf("Claude accepted the folder profile: code=%d stderr=%s", code, host.stderr.String())
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

// TestFolderProfileIsEnforcedByInstalledCodexSandbox runs real worker commands under the
// installed Codex seatbelt with the exact profile arguments; fake user and Runtime homes hold sentinels.
func TestFolderProfileIsEnforcedByInstalledCodexSandbox(t *testing.T) {
	codex, err := exec.LookPath("codex")
	if runtime.GOOS != "darwin" || err != nil {
		t.Skip("requires the installed Codex CLI on macOS")
	}
	bin := t.TempDir()
	if out, err := exec.Command("go", "build", "-o", filepath.Join(bin, "atlas-runtime"), "github.com/eyra/atlas/tools/runtime").CombinedOutput(); err != nil {
		t.Fatalf("build: %v %s", err, out)
	}
	user := isolatedHome(t)
	home, dest := filepath.Join(user, "runtime"), filepath.Join(user, "work")
	scope := materialize(t, home, dest)
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
	args, err := folderArguments(scope, scratch, user)
	if err != nil {
		t.Fatal(err)
	}
	environment := append(os.Environ(), "ATLAS_RUNTIME_HOME="+home, "TMPDIR="+filepath.Join(scratch, "tmp"), "PATH="+bin+":"+os.Getenv("PATH"))
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
		{fmt.Sprintf("cat %q", token), false},
		{fmt.Sprintf("ls %q", filepath.Dir(token)), false},
		{fmt.Sprintf("cat %q", filepath.Join(user, ".ssh", "id")), false},
		{fmt.Sprintf("cat %q", filepath.Join(user, ".codex", "auth.json")), false},
		{fmt.Sprintf("cat %q", filepath.Join(user, ".config", "gh", "hosts.yml")), false},
		{fmt.Sprintf("echo x > %q", record), false},
		{fmt.Sprintf("touch %q", filepath.Join(home, "planted")), false},
		{"mkdir repo/.git", false},
		{"mkdir .git", false},
		{"curl -sS -m 5 " + server.URL, false},
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
	out, err := shell(true, "atlas-runtime snapshot status --dest "+dest)
	if err != nil || !strings.Contains(out, `"path":"repo/new.txt"`) || !strings.Contains(out, `"change":"added"`) {
		t.Fatalf("sandboxed snapshot status: %v %s", err, out)
	}
	if out, err = shell(true, "atlas-runtime snapshot diff --dest "+dest); err != nil || !strings.Contains(out, "+edit") {
		t.Fatalf("sandboxed snapshot diff: %v %s", err, out)
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
