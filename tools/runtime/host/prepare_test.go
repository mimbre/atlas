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
	"sort"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/eyra/atlas/tools/runtime/snapshot"
	"github.com/eyra/atlas/tools/runtime/workspace"
)

const (
	registryLock = `{"name":"assets","lockfileVersion":3,"requires":true,"packages":{"":{"name":"assets","devDependencies":{"left-pad":"1.3.0"}},` +
		`"node_modules/left-pad":{"version":"1.3.0","resolved":"https://registry.npmjs.org/left-pad/-/left-pad-1.3.0.tgz","integrity":"sha512-AAAA","dev":true}}}`
	packageJSON = `{"name":"assets","private":true,"scripts":{"preinstall":"touch SCRIPT-RAN"},"devDependencies":{"left-pad":"1.3.0"}}`
	uuid        = "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"
)

// packageFiles is a repository with one npm package folder, app.
func packageFiles() map[string]string {
	return map[string]string{"app/package.json": packageJSON, "app/package-lock.json": registryLock, "app/README.md": "assets\n"}
}

// preparationFolder records dest as snapshot Materialize would, for a snapshot of one repository
// "repo" holding files, beneath a fresh user home. CODEX_HOME stays as inherited: preparation only
// denies it, and the folder scope only compares it.
func preparationFolder(t *testing.T, files map[string]string) (user, home, dest string) {
	t.Helper()
	user, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("HOME", user)
	home, dest = filepath.Join(user, "runtime"), filepath.Join(user, "work")
	type entry struct {
		Kind       string `json:"kind"`
		Mode       string `json:"mode"`
		Path       string `json:"path"`
		Repository string `json:"repository"`
		SHA256     string `json:"sha256"`
		Size       int    `json:"size"`
	}
	type repository struct {
		Path       string `json:"path"`
		Repository string `json:"repository"`
		Revision   string `json:"revision"`
	}
	manifest := struct {
		Entries      []entry      `json:"entries"`
		Repositories []repository `json:"repositories"`
		Version      int          `json:"version"`
	}{Entries: []entry{}, Repositories: []repository{{"repo", "github.com/test/repo", "rev_" + strings.Repeat("a", 64)}}, Version: 2}
	names := make([]string, 0, len(files))
	for name := range files {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		sum := sha256.Sum256([]byte(files[name]))
		manifest.Entries = append(manifest.Entries, entry{"file", "100644", "repo/" + name, "github.com/test/repo", hex.EncodeToString(sum[:]), len(files[name])})
	}
	raw, err := json.Marshal(manifest)
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(raw)
	id := "sha256:" + hex.EncodeToString(sum[:])
	baseline := filepath.Join(home, "snapshots", hex.EncodeToString(sum[:]))
	write := func(path, body string) {
		if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(body), 0600); err != nil {
			t.Fatal(err)
		}
	}
	for _, name := range names {
		write(filepath.Join(baseline, "tree", "repo", name), files[name])
		write(filepath.Join(dest, "repo", name), files[name])
	}
	if err = os.MkdirAll(filepath.Join(dest, "repo"), 0700); err != nil {
		t.Fatal(err)
	}
	write(filepath.Join(baseline, "manifest.json"), string(raw))
	write(filepath.Join(baseline, "complete"), id+"\n")
	write(filepath.Join(home, "materializations", fmt.Sprintf("%x.json", sha256.Sum256([]byte(dest)))), fmt.Sprintf(`{"destination":%q,"snapshot_id":%q}`, dest, id))
	return
}

// preparationTools puts a stand-in for the installed `codex sandbox`, which runs the command after
// `--` without confinement, and a stand-in npm first on PATH. The npm stand-in counts its runs in
// the returned file and runs the package's preinstall script unless --ignore-scripts is given, as npm does.
func preparationTools(t *testing.T, npm string) (runs string) {
	t.Helper()
	bin := t.TempDir()
	runs = filepath.Join(bin, "runs")
	scripts := map[string]string{
		"codex": "#!/bin/sh\nwhile [ \"$#\" -gt 0 ] && [ \"$1\" != \"--\" ]; do shift; done\nshift\nexec \"$@\"\n",
		"npm": "#!/bin/sh\necho run >> " + runs + "\ncase \" $* \" in *\" --ignore-scripts \"*) ;; *) " +
			"sh -c \"$(sed -n 's/.*\"preinstall\":\"\\([^\"]*\\)\".*/\\1/p' package.json)\" ;; esac\n" + npm,
	}
	for name, body := range scripts {
		if err := os.WriteFile(filepath.Join(bin, name), []byte(body), 0700); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("PATH", bin+":/usr/bin:/bin")
	return runs
}

func runCount(t *testing.T, runs string) int {
	t.Helper()
	data, err := os.ReadFile(runs)
	if errors.Is(err, os.ErrNotExist) {
		return 0
	} else if err != nil {
		t.Fatal(err)
	}
	return strings.Count(string(data), "run\n")
}

func readText(t *testing.T, path string) string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

// notReady requires err to be a preparation that is not ready and returns its result.
func notReady(t *testing.T, err error, state string) map[string]any {
	t.Helper()
	var failure *PreparationFailure
	if !errors.As(err, &failure) || failure.Result()["state"] != state || failure.Result()["ready"] != false ||
		!strings.Contains(err.Error(), "is not ready") || !strings.Contains(err.Error(), "materialize the snapshot into a fresh folder") {
		t.Fatalf("want a %s preparation that is not ready, got %v", state, err)
	}
	return failure.Result()
}

func TestPreparationInstallsOnlyItsOutputAndKeepsDiagnosticsPrivate(t *testing.T) {
	user, home, dest := preparationFolder(t, packageFiles())
	if err := os.WriteFile(filepath.Join(user, ".npmrc"), []byte("//registry.npmjs.org/:_authToken=NPMRC-SENTINEL\n"), 0600); err != nil {
		t.Fatal(err)
	}
	for name, value := range map[string]string{"GH_TOKEN": "GH-SENTINEL", "NPM_TOKEN": "NPM-SENTINEL", "npm_config__authToken": "CONFIG-SENTINEL",
		"ANTHROPIC_API_KEY": "API-SENTINEL", "NODE_OPTIONS": "--require /x/OPTIONS-SENTINEL"} {
		t.Setenv(name, value)
	}
	runs := preparationTools(t, `env
for config in "$npm_config_userconfig" "$npm_config_globalconfig"; do echo "config bytes $(wc -c < "$config" | tr -d ' ')"; cat "$config"; done
mkdir -p node_modules/left-pad node_modules/.bin
echo 'module.exports = 1' > node_modules/left-pad/index.js
ln -s ../left-pad/index.js node_modules/.bin/left-pad
head -c 1500000 /dev/zero | tr '\0' x
`)
	before, err := workspace.FolderScope(dest, home)
	if err != nil {
		t.Fatal(err)
	}
	result, err := Prepare(home, dest, "repo/app")
	if err != nil || result["ready"] != true || result["state"] != "succeeded" || !slices.Equal(result["outputs"].([]string), []string{"repo/app/node_modules"}) || *result["exit_code"].(*int) != 0 {
		t.Fatalf("got %v %v", result, err)
	}
	if runCount(t, runs) != 1 {
		t.Fatal("npm did not run exactly once")
	}
	if _, err := os.Lstat(filepath.Join(dest, "repo", "app", "SCRIPT-RAN")); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("the package's lifecycle script ran")
	}

	// The private log has npm's view: scrubbed environment, empty npm configuration, capped output.
	diagnostics := snapshot.PreparationDiagnostics(home, dest)
	if result["diagnostics"] != diagnostics {
		t.Fatalf("diagnostics: %v", result["diagnostics"])
	}
	log := readText(t, filepath.Join(diagnostics, "stdout.log"))
	if len(log) != prepareLogLimit || strings.Count(log, "config bytes 0\n") != 2 || !strings.Contains(log, "npm_config_registry=https://registry.npmjs.org/\n") ||
		strings.Contains(log, "SENTINEL") || strings.Contains(log, "GH_TOKEN") || strings.Contains(log, "NODE_OPTIONS") {
		t.Fatalf("npm environment or log cap wrong (%d bytes): %.2000s", len(log), log)
	}
	var outcome map[string]any
	if err = json.Unmarshal([]byte(readText(t, filepath.Join(diagnostics, "outcome.json"))), &outcome); err != nil || outcome["stdout_dropped_bytes"] == float64(0) {
		t.Fatalf("outcome: %v %v", outcome, err)
	}

	// The worker-readable result holds only the outcome, nothing from the command, logs or environment.
	raw := readText(t, snapshot.PreparationResult(home, dest))
	var worker map[string]any
	if err = json.Unmarshal([]byte(raw), &worker); err != nil {
		t.Fatal(err)
	}
	keys := []string{}
	for key := range worker {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	if !slices.Equal(keys, []string{"destination", "ended_at", "exit_code", "kind", "outputs", "path", "snapshot_id", "started_at", "state", "version"}) ||
		strings.Contains(raw, "npm_config") || strings.Contains(raw, "SENTINEL") || strings.Contains(raw, "codex") {
		t.Fatalf("worker-readable result: %s", raw)
	}

	// Status, diff and submit agree: only node_modules is skipped, tracked edits still count.
	for _, diffs := range []bool{false, true} {
		inspection, err := snapshot.Inspect(home, dest, nil, diffs)
		if err != nil || inspection["clean"] != true {
			t.Fatalf("diffs=%v: %v %v", diffs, inspection, err)
		}
	}
	if submitted, err := snapshot.Submit(home, dest, "", uuid); err != nil || submitted["state"] != "clean" {
		t.Fatalf("submit must find nothing to send, without Code: %v %v", submitted, err)
	}
	if err = os.WriteFile(filepath.Join(dest, "repo", "app", "README.md"), []byte("edited\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if inspection, err := snapshot.Inspect(home, dest, nil, false); err != nil || changesJSON(t, inspection) != `[{"repository":"github.com/test/repo","path":"repo/app/README.md","change":"modified"}]` {
		t.Fatalf("got %v %v", inspection, err)
	}

	// Workers get the same scope as before, the lock is free and the scratch is gone.
	after, err := workspace.FolderScope(dest, home)
	if err != nil || !workspace.JSONEqual(after, before) {
		t.Fatalf("scope changed: %v %v", after, err)
	}
	lock, _, err := workspace.Lock(dest, false)
	if err != nil {
		t.Fatalf("the preparation kept the folder lock: %v", err)
	}
	lock.Close()
	if entries, err := os.ReadDir(filepath.Join(home, "scratch")); err != nil || len(entries) != 0 {
		t.Fatalf("scratch left behind: %v %v", entries, err)
	}

	// Worker profiles read the result itself, never the diagnostics beside it.
	scratch := filepath.Join(home, "scratch", "turn-1")
	inspector := filepath.Join(user, "bin", "atlas-runtime")
	args, err := folderArguments(after, scratch, user, inspector)
	quoted, _ := json.Marshal(snapshot.PreparationResult(home, dest))
	if err != nil || !strings.Contains(args[3], string(quoted)+`="read"`) || strings.Contains(args[3], diagnostics) {
		t.Fatalf("Codex worker profile: %v %v", args, err)
	}
	// Claude denies writes below system temp roots; keep the fake user's folder outside TMPDIR.
	t.Setenv("TMPDIR", t.TempDir())
	t.Setenv("CLAUDE_CONFIG_DIR", "")
	settings, err := claudeFolderSettings(after, "/u/.ac-12345678", user, inspector)
	if err != nil || !strings.Contains(settings, `"allowRead":[`) || !strings.Contains(settings, string(quoted)) || strings.Contains(settings, diagnostics) {
		t.Fatalf("Claude worker settings: %s %v", settings, err)
	}

	// A repeat reports the recorded result without running again; another package is refused.
	again, err := Prepare(home, dest, "repo/app")
	if err != nil || again["ended_at"] != result["ended_at"] || runCount(t, runs) != 1 {
		t.Fatalf("repeat: %v %v", again, err)
	}
	if _, err = Prepare(home, dest, "repo"); err == nil || !strings.Contains(err.Error(), "a folder is prepared once") || runCount(t, runs) != 1 {
		t.Fatalf("a second preparation: %v", err)
	}
}

func TestFailedPreparationIsNotReadyButKeepsTheFolderUsable(t *testing.T) {
	_, home, dest := preparationFolder(t, packageFiles())
	runs := preparationTools(t, "mkdir -p node_modules/partial\necho half > node_modules/partial/x\necho 'npm ERR! code ECONNREFUSED' >&2\nexit 3\n")
	_, err := Prepare(home, dest, "repo/app")
	result := notReady(t, err, "failed")
	if result["reason"] != "exit" || *result["exit_code"].(*int) != 3 {
		t.Fatalf("got %v", result)
	}
	if !strings.Contains(readText(t, filepath.Join(snapshot.PreparationDiagnostics(home, dest), "stderr.log")), "npm ERR! code ECONNREFUSED") {
		t.Fatal("stderr is not in the diagnostics")
	}
	// Workers refuse the folder with the same explanation; nothing in it is removed.
	if _, scopeErr := workspace.FolderScope(dest, home); scopeErr == nil || scopeErr.Error() != err.Error() {
		t.Fatalf("worker scope: %v", scopeErr)
	}
	if readText(t, filepath.Join(dest, "repo", "app", "node_modules", "partial", "x")) != "half\n" {
		t.Fatal("the partial output was not kept")
	}
	// Edits are not trapped: status, diff and submit still see them, without the partial output.
	if err = os.WriteFile(filepath.Join(dest, "repo", "app", "README.md"), []byte("kept edit\n"), 0600); err != nil {
		t.Fatal(err)
	}
	inspection, err := snapshot.Inspect(home, dest, nil, false)
	if err != nil || changesJSON(t, inspection) != `[{"repository":"github.com/test/repo","path":"repo/app/README.md","change":"modified"}]` {
		t.Fatalf("got %v %v", inspection, err)
	}
	if fmt.Sprint(inspection["preparation"]) != "map[kind:npm-ci outputs:[repo/app/node_modules] path:repo/app ready:false state:failed]" {
		t.Fatalf("status preparation: %v", inspection["preparation"])
	}
	// A repeat reports the failure and never retries.
	_, err = Prepare(home, dest, "repo/app")
	notReady(t, err, "failed")
	if runCount(t, runs) != 1 {
		t.Fatal("a failed preparation was retried")
	}
}

func TestPreparationWithoutAnOutcomeStaysUncertain(t *testing.T) {
	_, home, dest := preparationFolder(t, packageFiles())
	runs := preparationTools(t, "mkdir node_modules\n")
	// A preparation command killed after claiming the folder leaves only its running result.
	plan, err := snapshot.PlanNPMCI(home, dest, "repo/app")
	if err != nil {
		t.Fatal(err)
	}
	if err = snapshot.BeginPreparation(home, plan, map[string]any{}); err != nil {
		t.Fatal(err)
	}
	if _, err = workspace.FolderScope(dest, home); err == nil || !strings.Contains(err.Error(), "has no recorded outcome") {
		t.Fatalf("worker scope: %v", err)
	}
	_, err = Prepare(home, dest, "repo/app")
	notReady(t, err, "running")
	if runCount(t, runs) != 0 {
		t.Fatal("an uncertain preparation was run again")
	}
}

func TestPreparationTimeoutKillsItsWholeGroup(t *testing.T) {
	_, home, dest := preparationFolder(t, packageFiles())
	pidFile := filepath.Join(t.TempDir(), "pid")
	preparationTools(t, "mkdir node_modules\nsleep 60 &\necho $! > "+pidFile+"\nwait\n")
	previous := prepareTimeout
	prepareTimeout = 500 * time.Millisecond
	defer func() { prepareTimeout = previous }()
	started := time.Now()
	_, err := Prepare(home, dest, "repo/app")
	if result := notReady(t, err, "failed"); result["reason"] != "timeout" || time.Since(started) > 10*time.Second {
		t.Fatalf("got %v after %s", result, time.Since(started))
	}
	var pid int
	if _, err = fmt.Sscan(readText(t, pidFile), &pid); err != nil {
		t.Fatal(err)
	}
	for deadline := time.Now().Add(3 * time.Second); syscall.Kill(pid, 0) == nil; time.Sleep(20 * time.Millisecond) {
		if time.Now().After(deadline) {
			t.Fatalf("descendant %d survived the timeout", pid)
		}
	}
}

func TestPreparationThatChangesTrackedFilesFails(t *testing.T) {
	_, home, dest := preparationFolder(t, packageFiles())
	preparationTools(t, "mkdir node_modules\necho tampered > README.md\n")
	_, err := Prepare(home, dest, "repo/app")
	if result := notReady(t, err, "failed"); result["reason"] != "changed" {
		t.Fatalf("got %v", result)
	}
	if outcome := readText(t, filepath.Join(snapshot.PreparationDiagnostics(home, dest), "outcome.json")); !strings.Contains(outcome, "repo/app/README.md") {
		t.Fatalf("outcome does not name the change: %s", outcome)
	}
}

func TestPreparationRefusesBeforeRunningAnything(t *testing.T) {
	lock := func(entry string) string {
		return strings.Replace(registryLock, `"resolved":"https://registry.npmjs.org/left-pad/-/left-pad-1.3.0.tgz","integrity":"sha512-AAAA"`, entry, 1)
	}
	for _, test := range []struct {
		name, path, want string
		files            map[string]string
		change           func(dest string) error
	}{
		{"project .npmrc", "repo/app", "project repo/app/.npmrc is not supported", map[string]string{"app/.npmrc": "registry=https://evil.example/\n"}, nil},
		{"repository .npmrc", "repo/app", "project repo/.npmrc is not supported", map[string]string{".npmrc": "x\n"}, nil},
		{"other registry", "repo/app", `resolves "node_modules/left-pad" to "https://evil.example/left-pad.tgz"`,
			map[string]string{"app/package-lock.json": lock(`"resolved":"https://evil.example/left-pad.tgz","integrity":"sha512-AAAA"`)}, nil},
		{"registry credentials in the URL", "repo/app", "not to https://registry.npmjs.org/",
			map[string]string{"app/package-lock.json": lock(`"resolved":"https://user:pass@registry.npmjs.org/left-pad.tgz","integrity":"sha512-AAAA"`)}, nil},
		{"git source", "repo/app", "not to https://registry.npmjs.org/",
			map[string]string{"app/package-lock.json": lock(`"resolved":"git+ssh://git@github.com/x/left-pad.git#abc","integrity":"sha512-AAAA"`)}, nil},
		{"weak integrity", "repo/app", "without a sha512 integrity",
			map[string]string{"app/package-lock.json": lock(`"resolved":"https://registry.npmjs.org/left-pad/-/left-pad-1.3.0.tgz","integrity":"sha1-AAAA"`)}, nil},
		{"linked package", "repo/app", "as a link or bundled package", map[string]string{"app/package-lock.json": lock(`"resolved":"../left-pad","link":true`)}, nil},
		{"tracked output", "repo/app", "repo/app/node_modules/kept.js is tracked in the snapshot", map[string]string{"app/node_modules/kept.js": "x\n"}, nil},
		{"no lockfile", "repo/app", "repo/app/package-lock.json is not a tracked file", map[string]string{"app/package-lock.json": ""}, nil},
		{"outside repositories", "elsewhere", "is not a folder inside a materialized repository", nil, nil},
		{"changed lockfile", "repo/app", "has 1 change(s) since it was materialized, first modified repo/app/package-lock.json", nil,
			func(dest string) error {
				return os.WriteFile(filepath.Join(dest, "repo/app/package-lock.json"), []byte(registryLock+" "), 0600)
			}},
		{"symlinked package folder", "repo/linked", "repo/linked is not a directory", nil,
			func(dest string) error { return os.Symlink("app", filepath.Join(dest, "repo", "linked")) }},
	} {
		t.Run(test.name, func(t *testing.T) {
			files := packageFiles()
			for name, body := range test.files {
				if body == "" {
					delete(files, name)
				} else {
					files[name] = body
				}
			}
			_, home, dest := preparationFolder(t, files)
			runs := preparationTools(t, "mkdir node_modules\n")
			if test.change != nil {
				if err := test.change(dest); err != nil {
					t.Fatal(err)
				}
			}
			if _, err := Prepare(home, dest, test.path); err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("got %v, want %q", err, test.want)
			}
			if _, err := os.Lstat(filepath.Join(home, "preparations")); !errors.Is(err, os.ErrNotExist) || runCount(t, runs) != 0 {
				t.Fatalf("a refused preparation recorded or ran something: %v", err)
			}
			if _, err := workspace.FolderScope(dest, home); err != nil {
				t.Fatalf("a refused preparation must leave a legacy folder usable: %v", err)
			}
		})
	}
	t.Run("missing Codex sandbox", func(t *testing.T) {
		_, home, dest := preparationFolder(t, packageFiles())
		runs := preparationTools(t, "mkdir node_modules\n")
		if err := os.Remove(filepath.Join(filepath.Dir(runs), "codex")); err != nil {
			t.Fatal(err)
		}
		if _, err := Prepare(home, dest, "repo/app"); err == nil || !strings.Contains(err.Error(), "requires the installed Codex sandbox") || runCount(t, runs) != 0 {
			t.Fatalf("got %v", err)
		}
	})
}

// changesJSON is the JSON of an inspection's changes.
func changesJSON(t *testing.T, inspection map[string]any) string {
	t.Helper()
	body, err := json.Marshal(inspection["changes"])
	if err != nil {
		t.Fatal(err)
	}
	return string(body)
}

func TestWorkerPreparationAndSubmissionShareTheFolderLock(t *testing.T) {
	_, home, dest := preparationFolder(t, packageFiles())
	signals := t.TempDir()
	runs := preparationTools(t, "echo started > "+signals+"/started\nwhile [ ! -e "+signals+"/release ]; do sleep 0.05; done\nmkdir node_modules\n")
	// A worker (or submission) holding the folder refuses the preparation before anything is recorded.
	worker, _, err := workspace.Lock(dest, false)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = Prepare(home, dest, "repo/app"); err == nil || !strings.Contains(err.Error(), "has an active Runtime owner") {
		t.Fatalf("got %v", err)
	}
	worker.Close()
	if _, err = os.Lstat(filepath.Join(home, "preparations")); !errors.Is(err, os.ErrNotExist) || runCount(t, runs) != 0 {
		t.Fatal("a refused preparation recorded or ran something")
	}

	type outcome struct {
		result map[string]any
		err    error
	}
	done := make(chan outcome, 1)
	go func() {
		result, err := Prepare(home, dest, "repo/app")
		done <- outcome{result, err}
	}()
	for deadline := time.Now().Add(10 * time.Second); ; time.Sleep(20 * time.Millisecond) {
		if _, err := os.Stat(filepath.Join(signals, "started")); err == nil {
			break
		} else if time.Now().After(deadline) {
			t.Fatal("the preparation did not start")
		}
	}
	// While it runs, a worker launch, a submission and another preparation all refuse.
	if lock, _, err := workspace.Lock(dest, false); err == nil {
		lock.Close()
		t.Fatal("a worker could take the folder during its preparation")
	}
	if _, err = snapshot.Submit(home, dest, "", uuid); err == nil || !strings.Contains(err.Error(), "has an active Runtime owner") {
		t.Fatalf("submit during preparation: %v", err)
	}
	if _, err = Prepare(home, dest, "repo/app"); err == nil || !strings.Contains(err.Error(), "has an active Runtime owner") {
		t.Fatalf("a second preparation: %v", err)
	}
	if _, err = workspace.FolderScope(dest, home); err == nil || !strings.Contains(err.Error(), "has no recorded outcome") {
		t.Fatalf("a worker scope during preparation: %v", err)
	}
	if err = os.WriteFile(filepath.Join(signals, "release"), nil, 0600); err != nil {
		t.Fatal(err)
	}
	if finished := <-done; finished.err != nil || finished.result["ready"] != true || runCount(t, runs) != 1 {
		t.Fatalf("got %v %v", finished.result, finished.err)
	}
}

// TestSetupProfileIsEnforcedByInstalledCodexSandbox runs probes under the installed Codex seatbelt
// with the exact preparation profile; fake user and Runtime homes hold sentinels. It does not reach
// the npm registry: registry access through Codex's proxy needs a separate networked proof.
func TestSetupProfileIsEnforcedByInstalledCodexSandbox(t *testing.T) {
	codex, err := exec.LookPath("codex")
	if runtime.GOOS != "darwin" || err != nil {
		t.Skip("requires the installed Codex CLI on macOS")
	}
	user, home, dest := preparationFolder(t, packageFiles())
	scope, err := workspace.FolderScopeBeforePreparation(dest, home)
	if err != nil {
		t.Fatal(err)
	}
	plan, err := snapshot.PlanNPMCI(home, dest, "repo/app")
	if err != nil {
		t.Fatal(err)
	}
	if err = snapshot.BeginPreparation(home, plan, map[string]any{"secret": "DIAGNOSTICS-SENTINEL"}); err != nil {
		t.Fatal(err)
	}
	token := filepath.Join(user, "code-home", "runtime.token")
	sentinels := map[string]string{
		token:                                      "TOKEN-SENTINEL",
		filepath.Join(home, "code.json"):           fmt.Sprintf(`{"url":"http://127.0.0.1:1","token_file":%q}`, token),
		filepath.Join(user, ".npmrc"):              "//registry.npmjs.org/:_authToken=NPMRC-SENTINEL",
		filepath.Join(user, ".ssh", "id"):          "SSH-SENTINEL",
		filepath.Join(user, ".codex", "auth.json"): "AUTH-SENTINEL",
	}
	for path, body := range sentinels {
		if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(body), 0600); err != nil {
			t.Fatal(err)
		}
	}
	scratch := filepath.Join(home, "scratch", "prepare-sandbox")
	if err := os.MkdirAll(filepath.Join(scratch, "tmp"), 0700); err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.Write([]byte("REACHABLE-SENTINEL")) }))
	defer server.Close()
	directory := filepath.Join(dest, "repo", "app")
	args, err := setupArguments(scope, []string{filepath.Join(directory, "node_modules")}, scratch, user, true)
	if err != nil {
		t.Fatal(err)
	}
	for _, probe := range []struct {
		script  string
		allowed bool
	}{
		{"mkdir -p node_modules/pkg && echo ok > node_modules/pkg/index.js", true},
		{fmt.Sprintf("echo ok > %q && cat %q", filepath.Join(scratch, "tmp", "f"), filepath.Join(scratch, "tmp", "f")), true},
		{"cat package-lock.json", true},
		{"echo tampered > README.md", false},
		{"echo planted > ../planted.txt", false},
		{"mkdir ../../.git", false},
		{fmt.Sprintf("cat %q", filepath.Join(user, ".npmrc")), false},
		{fmt.Sprintf("cat %q", filepath.Join(snapshot.PreparationDiagnostics(home, dest), "request.json")), false},
		{fmt.Sprintf("cat %q", snapshot.PreparationResult(home, dest)), false},
		{fmt.Sprintf("echo x > %q", snapshot.PreparationResult(home, dest)), false},
		{fmt.Sprintf("cat %q", filepath.Join(home, "code.json")), false},
		{fmt.Sprintf("cat %q", token), false},
		{fmt.Sprintf("cat %q", filepath.Join(user, ".ssh", "id")), false},
		{fmt.Sprintf("cat %q", filepath.Join(user, ".codex", "auth.json")), false},
		// The registry proxy answers other hosts with an HTTP denial; --fail makes that a failed request.
		{"curl -sS --fail -m 5 " + server.URL, false},
	} {
		command := exec.Command(codex, append(append([]string{"sandbox", "-P", setupProfile, "-C", directory}, args...), "--", "sh", "-c", probe.script)...)
		command.Dir = directory
		out, err := command.CombinedOutput()
		t.Logf("sandboxed %q: err=%v output=%q", probe.script, err, out)
		if (err == nil) != probe.allowed {
			t.Fatalf("sandboxed %q: allowed=%v want %v: %s", probe.script, err == nil, probe.allowed, out)
		}
		if !probe.allowed && strings.Contains(string(out), "SENTINEL") {
			t.Fatalf("sandboxed %q leaked a sentinel: %s", probe.script, out)
		}
	}
	if readText(t, filepath.Join(directory, "README.md")) != "assets\n" {
		t.Fatal("a tracked file changed")
	}
	// Positive control: the same request reaches the server outside the sandbox.
	if out, err := exec.Command("curl", "-sS", "--fail", "-m", "5", server.URL).CombinedOutput(); err != nil || !strings.Contains(string(out), "REACHABLE-SENTINEL") {
		t.Fatalf("unsandboxed control failed: %v %s", err, out)
	}
}

// runPackageJSON declares the build script an npm-run preparation runs, beside lifecycle scripts it must not.
const runPackageJSON = `{"name":"assets","private":true,"scripts":{"preinstall":"touch SCRIPT-RAN","prebuild":"touch PRE-RAN","build":"node build.js"},"devDependencies":{"left-pad":"1.3.0"}}`

// runOutputs are the viewer-like outputs of the build: two tracked generated paths beside the
// tracked page, and an untracked temporary folder in the package.
var runOutputs = []string{"repo/static/prism", "repo/app/.build", "repo/static/app.css"}

// runFiles is a repository whose package app builds the tracked static/app.css and static/prism.
func runFiles() map[string]string {
	files := packageFiles()
	files["app/package.json"] = runPackageJSON
	files["app/build.js"] = "build()\n"
	files["static/index.html"] = "<html>\n"
	files["static/app.css"] = "built\n"
	files["static/prism/LICENSE"] = "MIT\n"
	return files
}

// regenerate is a build that rewrites its tracked outputs exactly as the snapshot has them.
const regenerate = `rm -rf ../static/prism/*
mkdir -p ../static/prism .build
printf 'MIT\n' > ../static/prism/LICENSE
printf 'built\n' > ../static/app.css
echo entry > .build/entry.css`

// runTools is preparationTools with a stand-in node, whose npm runs ci on ci and run on run.
func runTools(t *testing.T, ci, run string) (runs string) {
	t.Helper()
	runs = preparationTools(t, "case \"$1\" in\nci)\n"+ci+"\n;;\nrun)\necho \"args $*\"\nenv\n"+run+"\n;;\nesac\n")
	if err := os.WriteFile(filepath.Join(filepath.Dir(runs), "node"), []byte("#!/bin/sh\nexit 0\n"), 0700); err != nil {
		t.Fatal(err)
	}
	return runs
}

func TestRunPreparationRegeneratesTrackedOutputsOffline(t *testing.T) {
	user, home, dest := preparationFolder(t, runFiles())
	t.Setenv("NPM_TOKEN", "NPM-SENTINEL")
	runs := runTools(t, "mkdir -p node_modules/tool", regenerate)
	// A run needs a succeeded npm-ci of its package first.
	if _, err := PrepareRun(home, dest, "repo/app", "build", runOutputs); err == nil || !strings.Contains(err.Error(), "requires a succeeded --npm-ci preparation of repo/app") || runCount(t, runs) != 0 {
		t.Fatalf("a run without npm-ci: %v", err)
	}
	if _, err := Prepare(home, dest, "repo/app"); err != nil {
		t.Fatal(err)
	}
	result, err := PrepareRun(home, dest, "repo/app", "build", runOutputs)
	sorted := []string{"repo/app/.build", "repo/static/app.css", "repo/static/prism"}
	if err != nil || result["ready"] != true || result["kind"] != "npm-run" || result["script"] != "build" || !slices.Equal(result["outputs"].([]string), sorted) ||
		*result["exit_code"].(*int) != 0 || runCount(t, runs) != 2 {
		t.Fatalf("got %v %v", result, err)
	}
	for _, name := range []string{"SCRIPT-RAN", "PRE-RAN"} {
		if _, err := os.Lstat(filepath.Join(dest, "repo", "app", name)); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("%s: a lifecycle script ran", name)
		}
	}

	// The run has its own private diagnostics beside the npm-ci's: exact arguments, offline, scrubbed.
	diagnostics := filepath.Join(snapshot.PreparationDiagnostics(home, dest), "npm-run")
	if result["diagnostics"] != diagnostics {
		t.Fatalf("diagnostics: %v", result["diagnostics"])
	}
	log := readText(t, filepath.Join(diagnostics, "stdout.log"))
	if !strings.Contains(log, "args run --ignore-scripts --offline build\n") || !strings.Contains(log, "npm_config_offline=true\n") || strings.Contains(log, "SENTINEL") {
		t.Fatalf("npm run log: %s", log)
	}
	if request := readText(t, filepath.Join(diagnostics, "request.json")); !strings.Contains(request, `"script":"build"`) || !strings.Contains(request, `"--offline"`) {
		t.Fatalf("request: %s", request)
	}
	if request := readText(t, filepath.Join(snapshot.PreparationDiagnostics(home, dest), "request.json")); !strings.Contains(request, `"ci"`) {
		t.Fatalf("the npm-ci request was not kept: %s", request)
	}

	// The worker-readable result names the run and the npm-ci it follows, and nothing private.
	raw := readText(t, snapshot.PreparationResult(home, dest))
	var worker map[string]any
	if err = json.Unmarshal([]byte(raw), &worker); err != nil {
		t.Fatal(err)
	}
	keys := []string{}
	for key := range worker {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	if !slices.Equal(keys, []string{"destination", "ended_at", "exit_code", "kind", "outputs", "path", "previous", "script", "snapshot_id", "started_at", "state", "version"}) ||
		strings.Contains(raw, "npm_config") || strings.Contains(raw, "SENTINEL") || strings.Contains(raw, "codex") {
		t.Fatalf("worker-readable result: %s", raw)
	}

	// Status, diff and submit agree: only node_modules and the untracked .build are skipped.
	for _, diffs := range []bool{false, true} {
		inspection, err := snapshot.Inspect(home, dest, nil, diffs)
		want := "map[excluded:[repo/app/node_modules repo/app/.build] kind:npm-run outputs:[repo/app/.build repo/static/app.css repo/static/prism] path:repo/app ready:true script:build state:succeeded]"
		if err != nil || inspection["clean"] != true || fmt.Sprint(inspection["preparation"]) != want {
			t.Fatalf("diffs=%v: %v %v", diffs, inspection, err)
		}
	}
	if submitted, err := snapshot.Submit(home, dest, "", uuid); err != nil || submitted["state"] != "clean" {
		t.Fatalf("submit must find nothing to send, without Code: %v %v", submitted, err)
	}
	// A tracked output is never excluded: a file added in it is an ordinary change.
	extra := filepath.Join(dest, "repo", "static", "prism", "extra.txt")
	if err = os.WriteFile(extra, []byte("x\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if inspection, err := snapshot.Inspect(home, dest, nil, false); err != nil || changesJSON(t, inspection) != `[{"repository":"github.com/test/repo","path":"repo/static/prism/extra.txt","change":"added"}]` {
		t.Fatalf("got %v %v", inspection, err)
	}
	if err = os.Remove(extra); err != nil {
		t.Fatal(err)
	}
	if _, err = workspace.FolderScope(dest, home); err != nil {
		t.Fatalf("workers refuse the prepared folder: %v", err)
	}

	// Repeats, in any output order, report the recorded outcomes; another run is refused.
	again, err := PrepareRun(home, dest, "repo/app", "build", sorted)
	if err != nil || again["ended_at"] != result["ended_at"] || runCount(t, runs) != 2 {
		t.Fatalf("repeat: %v %v", again, err)
	}
	if installed, err := Prepare(home, dest, "repo/app"); err != nil || installed["kind"] != "npm-ci" || runCount(t, runs) != 2 {
		t.Fatalf("npm-ci repeat: %v %v", installed, err)
	}
	for _, other := range []struct {
		script  string
		outputs []string
	}{{"build", []string{"repo/static/app.css"}}, {"lint", runOutputs}} {
		if _, err = PrepareRun(home, dest, "repo/app", other.script, other.outputs); err == nil || !strings.Contains(err.Error(), "a folder is prepared once") || runCount(t, runs) != 2 {
			t.Fatalf("another run %v: %v", other, err)
		}
	}

	// The run's profile has no network and writes only its outputs and scratch; node_modules stays read-only.
	scope, err := workspace.FolderScopeBeforePreparation(dest, home)
	if err != nil {
		t.Fatal(err)
	}
	args, err := setupArguments(scope, []string{filepath.Join(dest, "repo", "static", "app.css")}, filepath.Join(home, "scratch", "x"), user, false)
	profile := strings.Join(args, " ")
	if err != nil || !strings.Contains(profile, "network={enabled=false}") || strings.Contains(profile, "network_proxy") || strings.Contains(profile, snapshot.NPMRegistry) ||
		strings.Contains(profile, "node_modules") || strings.Count(profile, `="write"`) != 2 {
		t.Fatalf("run profile: %s %v", profile, err)
	}
}

func TestRunPreparationThatChangesFilesFails(t *testing.T) {
	for _, test := range []struct {
		name, run, reason, change string
	}{
		{"changed tracked output", "printf 'different\\n' > ../static/app.css", "changed", `"path":"repo/static/app.css","change":"modified"`},
		{"executable tracked output", regenerate + "\nchmod +x ../static/app.css", "changed", `"path":"repo/static/app.css","change":"mode"`},
		{"removed tracked output", "rm ../static/prism/LICENSE", "changed", `"path":"repo/static/prism/LICENSE","change":"deleted"`},
		{"file outside the outputs", regenerate + "\necho x > README.md", "changed", `"path":"repo/app/README.md","change":"modified"`},
		{"untracked output that is not a directory", "echo x > .build", "changed", `"path":"repo/app/.build","change":"added"`},
		{"failing script", "echo 'build failed' >&2\nexit 4", "exit", ""},
	} {
		t.Run(test.name, func(t *testing.T) {
			_, home, dest := preparationFolder(t, runFiles())
			runs := runTools(t, "mkdir -p node_modules/tool", test.run)
			if _, err := Prepare(home, dest, "repo/app"); err != nil {
				t.Fatal(err)
			}
			_, err := PrepareRun(home, dest, "repo/app", "build", runOutputs)
			result := notReady(t, err, "failed")
			if result["reason"] != test.reason || result["script"] != "build" {
				t.Fatalf("got %v", result)
			}
			diagnostics := filepath.Join(snapshot.PreparationDiagnostics(home, dest), "npm-run")
			if outcome := readText(t, filepath.Join(diagnostics, "outcome.json")); test.change != "" && !strings.Contains(outcome, strings.ReplaceAll(test.change, `"`, `\"`)) {
				t.Fatalf("outcome does not name the change: %s", outcome)
			}
			// Workers refuse the folder with the same explanation; status still reports the change.
			if _, scopeErr := workspace.FolderScope(dest, home); scopeErr == nil || scopeErr.Error() != err.Error() || !strings.Contains(err.Error(), "npm-run preparation of repo/app (script build) failed") {
				t.Fatalf("worker scope: %v", scopeErr)
			}
			inspection, err := snapshot.Inspect(home, dest, nil, false)
			if err != nil || !strings.Contains(changesJSON(t, inspection), test.change) || inspection["preparation"].(map[string]any)["state"] != "failed" {
				t.Fatalf("status: %v %v", inspection, err)
			}
			// A repeat reports the failure and never retries.
			_, err = PrepareRun(home, dest, "repo/app", "build", runOutputs)
			notReady(t, err, "failed")
			if runCount(t, runs) != 2 {
				t.Fatal("a failed run was retried")
			}
		})
	}
}

func TestRunPreparationRefusesBeforeRunningAnything(t *testing.T) {
	for _, test := range []struct {
		name, ci, script, want string
		outputs                []string
		change                 func(dest string) error
	}{
		{"no npm-ci", "", "build", "requires a succeeded --npm-ci preparation of repo/app", runOutputs, nil},
		{"failed npm-ci", "exit 1", "build", "requires a succeeded --npm-ci preparation of repo/app", runOutputs, nil},
		{"untracked script", "mkdir node_modules", "deploy", `script "deploy" is not in the tracked repo/app/package.json`, runOutputs, nil},
		{"script name", "mkdir node_modules", "-x", `--script "-x" is not a package.json script name`, runOutputs, nil},
		{"no outputs", "mkdir node_modules", "build", "declares no --output", nil, nil},
		{"node_modules output", "mkdir node_modules", "build", "overlaps repo/app/node_modules", []string{"repo/app/node_modules/.cache"}, nil},
		{"package folder output", "mkdir node_modules", "build", "", []string{"repo/app"}, nil},
		{"repository output", "mkdir node_modules", "build", "", []string{"repo"}, nil},
		{"manifest output", "mkdir node_modules", "build", "is the package's own manifest", []string{"repo/app/package-lock.json"}, nil},
		{"parent output", "mkdir node_modules", "build", "is not a relative path inside the destination", []string{"repo/app/../static"}, nil},
		{"Git output", "mkdir node_modules", "build", "is not a relative path inside the destination", []string{"repo/.git/hooks"}, nil},
		{"duplicate output", "mkdir node_modules", "build", "--output repo/static/app.css is declared twice", []string{"repo/static/app.css", "repo/static/app.css"}, nil},
		{"nested outputs", "mkdir node_modules", "build", "--output repo/static/app.css is inside --output repo/static", []string{"repo/static", "repo/static/app.css"}, nil},
		{"output outside repositories", "mkdir node_modules", "build", "--output elsewhere is outside the repository of repo/app", []string{"elsewhere"}, nil},
		{"symlinked output folder", "mkdir node_modules", "build", "repo/static/link is not a real directory", []string{"repo/static/link/x"},
			func(dest string) error { return os.Symlink("..", filepath.Join(dest, "repo", "static", "link")) }},
		{"changed folder", "mkdir node_modules", "build", "has 1 change(s) since it was materialized, first modified repo/app/README.md", runOutputs,
			func(dest string) error {
				return os.WriteFile(filepath.Join(dest, "repo", "app", "README.md"), []byte("edited\n"), 0600)
			}},
	} {
		t.Run(test.name, func(t *testing.T) {
			_, home, dest := preparationFolder(t, runFiles())
			runs := runTools(t, test.ci, regenerate)
			installed := 0
			if test.ci != "" {
				Prepare(home, dest, "repo/app")
				installed = 1
			}
			if test.change != nil {
				if err := test.change(dest); err != nil {
					t.Fatal(err)
				}
			}
			before, _ := os.ReadFile(snapshot.PreparationResult(home, dest))
			if _, err := PrepareRun(home, dest, "repo/app", test.script, test.outputs); err == nil || (test.want != "" && !strings.Contains(err.Error(), test.want)) {
				t.Fatalf("got %v, want %q", err, test.want)
			}
			after, _ := os.ReadFile(snapshot.PreparationResult(home, dest))
			if _, err := os.Lstat(filepath.Join(snapshot.PreparationDiagnostics(home, dest), "npm-run")); !errors.Is(err, os.ErrNotExist) || string(after) != string(before) || runCount(t, runs) != installed {
				t.Fatalf("a refused run recorded or ran something: %v", err)
			}
		})
	}
	t.Run("missing node", func(t *testing.T) {
		_, home, dest := preparationFolder(t, runFiles())
		runs := runTools(t, "mkdir node_modules", regenerate)
		if _, err := Prepare(home, dest, "repo/app"); err != nil {
			t.Fatal(err)
		}
		if err := os.Remove(filepath.Join(filepath.Dir(runs), "node")); err != nil {
			t.Fatal(err)
		}
		if _, err := PrepareRun(home, dest, "repo/app", "build", runOutputs); err == nil || !strings.Contains(err.Error(), "requires node on PATH") || runCount(t, runs) != 1 {
			t.Fatalf("got %v", err)
		}
	})
}

func TestRunPreparationTakesTheFolderLockAndRecordsBeforeRunning(t *testing.T) {
	_, home, dest := preparationFolder(t, runFiles())
	runs := runTools(t, "mkdir node_modules", regenerate)
	if _, err := Prepare(home, dest, "repo/app"); err != nil {
		t.Fatal(err)
	}
	worker, _, err := workspace.Lock(dest, false)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = PrepareRun(home, dest, "repo/app", "build", runOutputs); err == nil || !strings.Contains(err.Error(), "has an active Runtime owner") {
		t.Fatalf("got %v", err)
	}
	worker.Close()
	if _, err = os.Lstat(filepath.Join(snapshot.PreparationDiagnostics(home, dest), "npm-run")); !errors.Is(err, os.ErrNotExist) || runCount(t, runs) != 1 {
		t.Fatal("a refused run recorded or ran something")
	}
	// A run killed after its claim leaves only its running result: not ready, never run again.
	plan, err := snapshot.PlanNPMRun(home, dest, "repo/app", "build", runOutputs)
	if err != nil {
		t.Fatal(err)
	}
	if err = snapshot.BeginRun(home, plan, map[string]any{}); err != nil {
		t.Fatal(err)
	}
	if err = snapshot.BeginRun(home, plan, map[string]any{}); err == nil || !strings.Contains(err.Error(), "already has an npm-run preparation record") {
		t.Fatalf("a second claim: %v", err)
	}
	if _, err = workspace.FolderScope(dest, home); err == nil || !strings.Contains(err.Error(), "has no recorded outcome") {
		t.Fatalf("worker scope: %v", err)
	}
	_, err = PrepareRun(home, dest, "repo/app", "build", runOutputs)
	notReady(t, err, "running")
	if runCount(t, runs) != 1 {
		t.Fatal("an uncertain run was run again")
	}
}

// TestRunProfileIsEnforcedByInstalledCodexSandbox runs probes under the installed Codex seatbelt
// with the exact network-off run profile.
func TestRunProfileIsEnforcedByInstalledCodexSandbox(t *testing.T) {
	codex, err := exec.LookPath("codex")
	if runtime.GOOS != "darwin" || err != nil {
		t.Skip("requires the installed Codex CLI on macOS")
	}
	user, home, dest := preparationFolder(t, runFiles())
	scope, err := workspace.FolderScopeBeforePreparation(dest, home)
	if err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(filepath.Join(user, ".npmrc"), []byte("NPMRC-SENTINEL"), 0600); err != nil {
		t.Fatal(err)
	}
	directory := filepath.Join(dest, "repo", "app")
	if err = os.MkdirAll(filepath.Join(directory, "node_modules", "tool"), 0700); err != nil {
		t.Fatal(err)
	}
	scratch := filepath.Join(home, "scratch", "prepare-run-sandbox")
	if err = os.MkdirAll(scratch, 0700); err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.Write([]byte("REACHABLE-SENTINEL")) }))
	defer server.Close()
	var writable []string
	for _, output := range runOutputs {
		writable = append(writable, filepath.Join(dest, output))
	}
	args, err := setupArguments(scope, writable, scratch, user, false)
	if err != nil {
		t.Fatal(err)
	}
	for _, probe := range []struct {
		script  string
		allowed bool
	}{
		{"printf 'built\\n' > ../static/app.css && rm -rf ../static/prism/* && mkdir -p .build && echo x > .build/entry.css", true},
		{fmt.Sprintf("echo ok > %q", filepath.Join(scratch, "f")), true},
		{"cat node_modules/../package.json", true},
		{"echo x > node_modules/tool/index.js", false},
		{"echo x > ../static/index.html", false},
		{"echo x > build.js", false},
		// A declared output may be cleared, never removed.
		{"rm -rf ../static/prism", false},
		{fmt.Sprintf("cat %q", filepath.Join(user, ".npmrc")), false},
		{fmt.Sprintf("cat %q", snapshot.PreparationResult(home, dest)), false},
		{"curl -sS --fail -m 5 " + server.URL, false},
	} {
		command := exec.Command(codex, append(append([]string{"sandbox", "-P", setupProfile, "-C", directory}, args...), "--", "sh", "-c", probe.script)...)
		command.Dir = directory
		out, err := command.CombinedOutput()
		t.Logf("sandboxed %q: err=%v output=%q", probe.script, err, out)
		if (err == nil) != probe.allowed {
			t.Fatalf("sandboxed %q: allowed=%v want %v: %s", probe.script, err == nil, probe.allowed, out)
		}
		if !probe.allowed && strings.Contains(string(out), "SENTINEL") {
			t.Fatalf("sandboxed %q leaked a sentinel: %s", probe.script, out)
		}
	}
	if out, err := exec.Command("curl", "-sS", "--fail", "-m", "5", server.URL).CombinedOutput(); err != nil || !strings.Contains(string(out), "REACHABLE-SENTINEL") {
		t.Fatalf("unsandboxed control failed: %v %s", err, out)
	}
}
