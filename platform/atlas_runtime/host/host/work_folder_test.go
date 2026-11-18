package host

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// The work folder of S5a P7a (design §3.9 RQ7; decision 2026-11-17, designer conditions 2 and 3):
// <home>/workers/work-<work_id> runs under the profiles with the managed repository's chain and
// sibling rule (I8). Codex, where the more specific path wins, also keeps the deny on the whole home
// with the folder as the more specific allow (P7a fix B1); Claude, where a deny wins, does not deny the
// home and adds top-level patterns for the file tools instead.

const testWorkID = "work-work-0123456789abcdef"

// workFolderHome is a Runtime home with a work folder, a sibling work folder and slot, the frozen
// store, a base, the work store, a Code token and the sockets; it returns the home, the folder and its scope.
func workFolderHome(t *testing.T, parent string) (string, string, map[string]any) {
	t.Helper()
	home := filepath.Join(parent, "runtime")
	work := filepath.Join(home, "workers", testWorkID)
	scope := materialize(t, home, work)
	for _, dir := range []string{"workers/work-work-1111111111111111", "workers/slot1", "frozen/blobs", "bases", "work", "turns"} {
		if err := os.MkdirAll(filepath.Join(home, dir), 0700); err != nil {
			t.Fatal(err)
		}
	}
	token := filepath.Join(home, "code-service", "runtime.token")
	if err := os.MkdirAll(filepath.Dir(token), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(home, "code.json"), []byte(fmt.Sprintf(`{"url":"http://127.0.0.1:1","token_file":%q}`, token)), 0600); err != nil {
		t.Fatal(err)
	}
	return home, work, scope
}

// profileEntries decodes the filesystem table of a rendered Codex profile into path → access.
func profileEntries(t *testing.T, args []string) map[string]string {
	t.Helper()
	if len(args) < 4 {
		t.Fatalf("profile arguments: %q", args)
	}
	profile := args[3]
	start := strings.Index(profile, "filesystem={")
	end := strings.Index(profile, "},network=")
	if start < 0 || end < 0 {
		t.Fatalf("no filesystem table: %s", profile)
	}
	entries := map[string]string{}
	for _, pair := range splitTable(profile[start+len("filesystem={") : end]) {
		key, access, ok := strings.Cut(pair, "=")
		var path string
		if !ok || json.Unmarshal([]byte(key), &path) != nil {
			t.Fatalf("entry %q of %s", pair, profile)
		}
		entries[path] = strings.Trim(access, `"`)
	}
	return entries
}

// splitTable splits `"a"="x","b"="y"` on the commas outside quotes.
func splitTable(table string) []string {
	var parts []string
	quoted, escaped, start := false, false, 0
	for i, c := range table {
		switch {
		case escaped:
			escaped = false
		case c == '\\':
			escaped = true
		case c == '"':
			quoted = !quoted
		case c == ',' && !quoted:
			parts = append(parts, table[start:i])
			start = i + 1
		}
	}
	return append(parts, table[start:])
}

// assertWorkFolderDenies checks the chain and sibling rule in a rendered profile's entries.
func assertWorkFolderDenies(t *testing.T, label string, entries map[string]string, home, work string) {
	t.Helper()
	// The user home, which contains every test home, is denied as for any folder in it (the folder
	// stays the more specific Codex path); only Runtime-home denies are checked here.
	user, _ := os.UserHomeDir()
	// Codex lets the more specific path win: the home stays denied whole (late entries, listings).
	if entries[home] != "none" {
		t.Errorf("%s: the home itself must be denied, got %q", label, entries[home])
	}
	if access, ok := entries[filepath.Join(home, "workers")]; ok {
		t.Errorf("%s: <home>/workers must stay on the chain, got %s", label, access)
	}
	if access := codexAccess(entries, work); access != "read" && access != "write" {
		t.Errorf("%s: the folder is %q under the home deny", label, access)
	}
	for path, access := range entries {
		if access == "none" && within(path, work) && path != user && path != home {
			t.Errorf("%s: deny %s contains the work folder", label, path)
		}
	}
	for _, name := range []string{"runtime.sock", "backend.sock", "frozen", "bases", "work", "snapshots", "materializations",
		"scratch", "turns", "code.json", "policy.json", "code-service", "code-service/runtime.token",
		"workers/slot1", "workers/work-work-1111111111111111"} {
		if entries[filepath.Join(home, name)] != "none" {
			t.Errorf("%s: %s is not denied: %v", label, name, entries[filepath.Join(home, name)])
		}
	}
	// A sibling created after launch falls under the sibling globs.
	globs := 0
	for path, access := range entries {
		if strings.HasPrefix(path, filepath.Join(home, "workers")+"/") && strings.ContainsAny(path, "[*") && access == "none" {
			globs++
		}
	}
	if want := 4 * len(testWorkID); globs != want {
		t.Errorf("%s: %d sibling worker globs, want %d", label, globs, want)
	}
}

func TestWorkFolderCodexProfilesDenyTheChainNotTheHome(t *testing.T) {
	user := isolatedHome(t)
	home, work, scope := workFolderHome(t, user)
	homePath(t, user, home, work)
	scratch := filepath.Join(home, "scratch", "turn-1")
	inspector := filepath.Join(user, "bin", "atlas-runtime")

	args, err := folderArguments(scope, scratch, user, inspector)
	if err != nil {
		t.Fatal(err)
	}
	entries := profileEntries(t, args)
	assertWorkFolderDenies(t, "materialized-folder", entries, home, work)
	for path, access := range map[string]string{work: "write", scratch: "write", user: "none",
		scope["record"].(string): "read", scope["baseline"].(string): "read", work + "/.git": "none", work + "/repo/.git": "none"} {
		if entries[path] != access {
			t.Errorf("materialized-folder: %s is %q, want %q", path, entries[path], access)
		}
	}
	for path, access := range entries {
		if access == "write" && path != work && path != scratch {
			t.Errorf("materialized-folder: unexpected writable %s", path)
		}
	}
	if !strings.Contains(args[3], `unix_sockets={`+quote(scratch)+`="allow"}`) {
		t.Errorf("Unix sockets must stay limited to the scratch: %s", args[3])
	}

	for _, mode := range []string{"read-only", "workspace-write"} {
		args, err := sandboxArguments(mode, work, home)
		if err != nil {
			t.Fatal(err)
		}
		entries := profileEntries(t, args)
		assertWorkFolderDenies(t, mode, entries, home, work)
		want := map[string]string{"read-only": "read", "workspace-write": "write"}[mode]
		if entries[work] != want || !strings.Contains(args[3], "network={enabled=false}") {
			t.Errorf("%s: the folder is %q: %s", mode, entries[work], args[3])
		}
	}

	// The names cover the frozen store, the bases and the work store before they exist.
	for _, name := range []string{"bases", "work", "frozen"} {
		if err := os.RemoveAll(filepath.Join(home, name)); err != nil {
			t.Fatal(err)
		}
	}
	args, err = folderArguments(scope, scratch, user, inspector)
	if err != nil {
		t.Fatal(err)
	}
	assertWorkFolderDenies(t, "materialized-folder, absent at launch", profileEntries(t, args), home, work)

	setup, err := setupArguments(scope, []string{filepath.Join(work, "repo", "node_modules")}, scratch, user, false)
	if err != nil {
		t.Fatal(err)
	}
	assertWorkFolderDenies(t, "setup", profileEntries(t, setup), home, work)

	// Any other folder keeps the home denied whole, and a home spelled differently is not the work folder.
	outside := filepath.Join(user, "outside")
	outsideScope := materialize(t, home, outside)
	args, err = folderArguments(outsideScope, scratch, user, inspector)
	if err != nil {
		t.Fatal(err)
	}
	if profileEntries(t, args)[home] != "none" {
		t.Error("a folder outside the home must keep the home denied whole")
	}
	args, err = sandboxArguments("read-only", filepath.Join(home, "workers", "slot1"), home)
	if err != nil {
		t.Fatal(err)
	}
	if profileEntries(t, args)[home] != "none" {
		t.Error("a slot folder is not the work folder: the home stays denied whole")
	}
}

// codexAccess is the access a rendered Codex profile gives path, as Codex resolves it: a deny glob
// matching path or an ancestor denies, otherwise the most specific listed path containing path wins;
// "" means no rule (the built-in base decides). Seatbelt's [!c] class is Go's [^c].
func codexAccess(entries map[string]string, path string) string {
	for pattern, access := range entries {
		if access != "none" || !strings.ContainsAny(pattern, "*[") {
			continue
		}
		glob := strings.ReplaceAll(strings.TrimSuffix(pattern, "/**"), "[!", "[^")
		for candidate := path; candidate != "/"; candidate = filepath.Dir(candidate) {
			if matched, _ := filepath.Match(glob, candidate); matched {
				return "none"
			}
		}
	}
	best, access := "", ""
	for entry, value := range entries {
		if !strings.ContainsAny(entry, "*[") && within(entry, path) && len(entry) > len(best) {
			best, access = entry, value
		}
	}
	return access
}

// lateHomeNames are entries the Runtime creates at the top of its home while a turn runs: the atomic
// temps of availability.ex, work/mode.ex and the policy, first-use records, a new store directory and a
// work source's credential (sources/<name>/token) and a local work source queue record (local-source/,
// work acquisition M2 F4).
var lateHomeNames = []string{"late.json.tmp", "mode.json.tmp", "availability.json.tmp", "policy.json.tmp", "mode.json",
	"clients.json", "submissions/tmp-1/blob", "packets/p/packet.json", ".record-123", "sources/late/token",
	"local-source/late.json"}

// TestWorkFolderProfilesDenyHomeEntriesCreatedDuringTheTurn is review B1: an entry created at the top of
// the Runtime home after the profiles were rendered is denied, and neither the home nor <home>/workers
// can be listed. The home lies outside the user home, so the user-home deny does not cover it.
func TestWorkFolderProfilesDenyHomeEntriesCreatedDuringTheTurn(t *testing.T) {
	user := isolatedHome(t)
	parent, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	home, work, scope := workFolderHome(t, parent)
	if within(user, home) {
		t.Fatalf("the home %s must lie outside the user home %s", home, user)
	}
	scratch := filepath.Join(home, "scratch", "turn-1")
	inspector := filepath.Join(user, "bin", "atlas-runtime")
	profiles := map[string]map[string]string{}
	folder, err := folderArguments(scope, scratch, user, inspector)
	if err != nil {
		t.Fatal(err)
	}
	profiles["materialized-folder"] = profileEntries(t, folder)
	for _, mode := range []string{"read-only", "workspace-write"} {
		args, err := sandboxArguments(mode, work, home)
		if err != nil {
			t.Fatal(err)
		}
		profiles[mode] = profileEntries(t, args)
	}
	output := filepath.Join(work, "repo", "node_modules")
	setup, err := setupArguments(scope, []string{output}, scratch, user, false)
	if err != nil {
		t.Fatal(err)
	}
	profiles["setup"] = profileEntries(t, setup)
	writeLateHomeNames(t, home, "LATE-SENTINEL")

	want := map[string]string{"materialized-folder": "write", "read-only": "read", "workspace-write": "write", "setup": "read"}
	for label, entries := range profiles {
		for _, name := range lateHomeNames {
			if access := codexAccess(entries, filepath.Join(home, name)); access != "none" {
				t.Errorf("%s: %s created during the turn is %q, want none", label, name, access)
			}
		}
		for _, listed := range []string{home, filepath.Join(home, "workers")} {
			if access := codexAccess(entries, listed); access != "none" {
				t.Errorf("%s: %s can be listed (%q)", label, listed, access)
			}
		}
		if access := codexAccess(entries, filepath.Join(work, "repo", "a.txt")); access != want[label] {
			t.Errorf("%s: a file in the folder is %q, want %q", label, access, want[label])
		}
	}
	if access := codexAccess(profiles["setup"], filepath.Join(output, "x")); access != "write" {
		t.Errorf("setup: the output is %q, want write", access)
	}
}

// writeLateHomeNames creates the lateHomeNames with the given contents, as the Runtime does while a turn runs.
func writeLateHomeNames(t *testing.T, home, body string) {
	t.Helper()
	for _, name := range lateHomeNames {
		path := filepath.Join(home, name)
		if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(body), 0600); err != nil {
			t.Fatal(err)
		}
	}
}

// leakToken returns a unique random token for the sentinel contents of one native run. Only the
// contents carry it, never a path, so it can appear in a probe's output only when a denied file was read.
func leakToken(t *testing.T) string {
	t.Helper()
	random := make([]byte, 16)
	if _, err := rand.Read(random); err != nil {
		t.Fatal(err)
	}
	return "atlas-leak-" + hex.EncodeToString(random)
}

// listedNames are entries of the denied directories (<home>, <home>/workers, a sibling's repo, the
// frozen store) that a real listing of them would print.
var listedNames = []string{"workers", "runtime.sock", "read.sock", "backend.sock", "mode.json.tmp", "policy.json",
	"frozen", "work-work-1111111111111111", "slot1", "secret", "blobs"}

// probeLeak reports what a probe's output leaked: the sentinel contents (the token) or a real
// directory listing, an output field that is exactly a listed name. A permission error that echoes a
// denied path ("cat: <home>/mode.json.tmp: Operation not permitted") is not a leak: its fields are
// whole paths and words, never a bare entry name.
func probeLeak(out, token string) string {
	if strings.Contains(out, token) {
		return "sentinel contents"
	}
	for _, field := range strings.Fields(out) {
		if slices.Contains(listedNames, field) {
			return "a listing of " + field
		}
	}
	return ""
}

// TestNativeProbeLeakMatcher pins the native check's leak matcher: permission errors naming the
// denied files are no leak; their contents or a listing of their directories are.
func TestNativeProbeLeakMatcher(t *testing.T) {
	token := "atlas-leak-00112233445566778899aabbccddeeff"
	for _, out := range []string{
		"cat: /private/tmp/awf1/h/mode.json.tmp: Operation not permitted\n",
		"cat: /private/tmp/awf1/h/workers/work-work-1111111111111111/repo/secret: Operation not permitted\n",
		"cat: /private/tmp/awf1/h/workers/work-work-1111111111111111/repo: Operation not permitted\n" +
			"ls: /private/tmp/awf1/h/workers/work-work-1111111111111111/repo: Operation not permitted\n",
		"ls: /private/tmp/awf1/h: Operation not permitted\n",
		"nc: unix connect failed: Operation not permitted\n",
		"FOLDER-CONTENT",
		"",
	} {
		if leak := probeLeak(out, token); leak != "" {
			t.Errorf("a permission error is reported as a leak (%s): %q", leak, out)
		}
	}
	for _, out := range []string{
		"SIBLING-" + token,
		"cat: x: Operation not permitted\nLATE-" + token,
		".\n..\nmode.json.tmp\nruntime.sock\nworkers\n",
		"slot1\nwork-work-0123456789abcdef\nwork-work-1111111111111111\n",
		"secret\n",
		"workers  frozen  mode.json.tmp\n",
	} {
		if probeLeak(out, token) == "" {
			t.Errorf("a leak is not detected: %q", out)
		}
	}
}

// TestWorkFolderClaudeSettingsDenyHomeEntriesCreatedDuringTheTurn is review B1 for Claude, where a deny
// wins over the folder: the home is never a Read rule; the claudeHomeTopRules cover the atomic temps,
// JSON records and dot names created at the home's top level after rendering, never workers or the
// folder; Bash reads of the home stay denied whole. A later top-level name of another shape (a new
// store directory) is covered by the Bash deny and --restricted only (claudeHomeTopPatterns).
func TestWorkFolderClaudeSettingsDenyHomeEntriesCreatedDuringTheTurn(t *testing.T) {
	user := claudeUser(t)
	home, work, scope := workFolderHome(t, user)
	claudeFolder, err := claudeFolderSettings(scope, "/u/.ac-12345678", user, filepath.Join(user, "bin", "atlas-runtime"))
	if err != nil {
		t.Fatal(err)
	}
	claudeRead, err := claudeReadOnlySettings(work, home)
	if err != nil {
		t.Fatal(err)
	}
	writeLateHomeNames(t, home, "LATE-SENTINEL")
	matches := func(rules []string, path string) bool {
		for _, rule := range rules {
			pattern := strings.TrimSuffix(strings.TrimPrefix(rule, "Read(/"), ")")
			for candidate := path; candidate != "/"; candidate = filepath.Dir(candidate) {
				if matched, _ := filepath.Match(pattern, candidate); matched {
					return true
				}
			}
		}
		return false
	}
	for label, encoded := range map[string]string{"claude materialized-folder": claudeFolder, "claude read-only": claudeRead} {
		settings := decodeClaude(t, encoded)
		rules := settings.Permissions.Deny
		for _, rule := range claudeHomeTopRules(home) {
			if !slices.Contains(rules, rule) {
				t.Errorf("%s: no rule %s", label, rule)
			}
		}
		for _, name := range []string{"late.json.tmp", "mode.json.tmp", "availability.json.tmp", "policy.json.tmp", "mode.json", "clients.json", ".record-123"} {
			if !matches(rules, filepath.Join(home, name)) {
				t.Errorf("%s: %s created during the turn has no Read rule", label, name)
			}
		}
		// Work acquisition M2 (F4): no top pattern matches the sources or local-source directory, so the enumerated
		// workerHomeNames rule (the materialized folder) or the home rule (read-only) must deny it.
		for _, path := range []string{filepath.Join(home, "sources"), filepath.Join(home, "sources", "late", "token"),
			filepath.Join(home, "local-source"), filepath.Join(home, "local-source", "late.json")} {
			if !matches(rules, path) {
				t.Errorf("%s: the work source path %s has no Read rule", label, path)
			}
		}
		for _, path := range []string{home, filepath.Join(home, "workers"), work, filepath.Join(work, "repo", "a.json")} {
			if matches(rules, path) {
				t.Errorf("%s: a Read rule denies %s", label, path)
			}
		}
		if label == "claude materialized-folder" {
			filesystem := settings.Sandbox.Filesystem
			if !slices.Contains(filesystem.DenyRead, home) {
				t.Errorf("%s: Bash reads of the home are not denied: %v", label, filesystem.DenyRead)
			}
			for _, allowed := range filesystem.AllowRead {
				for _, name := range lateHomeNames {
					if within(allowed, filepath.Join(home, name)) {
						t.Errorf("%s: allowRead %s re-opens %s", label, allowed, name)
					}
				}
			}
		}
	}
}

func quote(path string) string { body, _ := json.Marshal(path); return string(body) }

// The default home ~/.local/state/atlas-runtime is also a credential location: for the work folder it is
// covered by the home deny; a credential location strictly containing the home refuses the folder.
func TestWorkFolderCodexProfileInTheDefaultRuntimeHome(t *testing.T) {
	user := isolatedHome(t)
	home := filepath.Join(user, ".local", "state", "atlas-runtime")
	work := filepath.Join(home, "workers", testWorkID)
	scope := materialize(t, home, work)
	scratch := filepath.Join(home, "scratch", "turn-1")
	args, err := folderArguments(scope, scratch, user, filepath.Join(user, "bin", "atlas-runtime"))
	if err != nil {
		t.Fatal(err)
	}
	entries := profileEntries(t, args)
	if entries[home] != "none" || entries[work] != "write" || entries[filepath.Join(home, "materializations")] != "none" {
		t.Fatalf("default home: %v", entries)
	}

	inside := filepath.Join(user, ".codex", "runtime")
	work = filepath.Join(inside, "workers", testWorkID)
	scope = materialize(t, inside, work)
	if _, err := folderArguments(scope, filepath.Join(inside, "scratch", "t"), user, filepath.Join(user, "bin", "atlas-runtime")); err == nil ||
		err.Error() != "Protected path "+filepath.Join(user, ".codex")+" contains "+work {
		t.Fatalf("a credential location containing the home must refuse the folder: %v", err)
	}
}

func TestWorkFolderClaudeSettingsDenyTheChain(t *testing.T) {
	user := claudeUser(t)
	home, work, scope := workFolderHome(t, user)
	// Read-only: file tools only (no Bash), every off-chain entry denied by a Read rule, never the home.
	encoded, err := claudeReadOnlySettings(work, home)
	if err != nil {
		t.Fatal(err)
	}
	rules := decodeClaude(t, encoded).Permissions.Deny
	for _, rule := range rules {
		if rule == "Read(/"+home+")" || strings.ContainsAny(strings.TrimPrefix(rule, "Read(/"+home), "[*") && !slices.Contains(claudeHomeTopRules(home), rule) {
			t.Errorf("read-only rule %s denies the home or is a glob", rule)
		}
	}
	for _, name := range []string{"runtime.sock", "backend.sock", "frozen", "bases", "work", "snapshots", "materializations",
		"workers/slot1", "workers/work-work-1111111111111111", "code-service"} {
		if !slices.Contains(rules, "Read(/"+filepath.Join(home, name)+")") {
			t.Errorf("read-only: %s has no Read rule: %v", name, rules)
		}
	}
	// Materialized folder: the work folder renders with the bases and work store denied too, also
	// when they do not exist yet at launch (only the names cover them then).
	for _, name := range []string{"bases", "work", "frozen"} {
		if err := os.RemoveAll(filepath.Join(home, name)); err != nil {
			t.Fatal(err)
		}
	}
	temporary, inspector := "/u/.ac-12345678", filepath.Join(user, "bin", "atlas-runtime")
	encoded, err = claudeFolderSettings(scope, temporary, user, inspector)
	if err != nil {
		t.Fatal(err)
	}
	filesystem := decodeClaude(t, encoded).Sandbox.Filesystem
	for _, name := range []string{"bases", "work", "frozen", "workers/work-work-1111111111111111"} {
		if path := filepath.Join(home, name); !slices.Contains(filesystem.DenyRead, path) || !slices.Contains(filesystem.DenyWrite, path) {
			t.Errorf("materialized-folder: %s is not denied: %s", name, encoded)
		}
	}
}

// TestWorkFolderProfileIsEnforcedByInstalledCodexSandbox is the native I8 check of the work folder
// (designer condition 3), for the orchestrator on the mini, outside any agent sandbox:
//
//	ATLAS_RUNTIME_NATIVE_SANDBOX=1 go test -count=1 -v -run 'TestWorkFolderProfileIsEnforcedByInstalledCodexSandbox' ./host/
//
// Without the variable it skips; with it, a missing codex or a denied nested Seatbelt fails. From
// inside <home>/workers/work-<work_id>, under the materialized-folder and the read-only profile, it
// and the preparation (setup) profile, it runs real commands with the installed `codex sandbox`: the
// folder is read (all three) and written (materialized-folder only); runtime.sock, read.sock and
// backend.sock accept no connection; a sibling work folder, a sibling created after launch, a slot, the
// frozen store, a base, the work store, another baseline, a work source's credential (sources/), the local
// work source's queue (local-source/, work acquisition M2 F4) and the entries created at the top of the home after the profiles were rendered
// (the atomic temps, a new store, a new source) leak no sentinel; neither the home
// nor <home>/workers can be listed; nothing is written beside the folder (review B1, S1).
func TestWorkFolderProfileIsEnforcedByInstalledCodexSandbox(t *testing.T) {
	if os.Getenv("ATLAS_RUNTIME_NATIVE_SANDBOX") != "1" {
		t.Skip("native sandbox gate: set ATLAS_RUNTIME_NATIVE_SANDBOX=1 outside any agent sandbox")
	}
	codex, err := exec.LookPath("codex")
	if runtime.GOOS != "darwin" || err != nil || !filepath.IsAbs(codex) {
		t.Fatalf("requires the installed Codex CLI on macOS: %v", err)
	}
	if out, err := exec.Command("/usr/bin/sandbox-exec", "-p", "(version 1)(allow default)", "/usr/bin/true").CombinedOutput(); err != nil {
		t.Fatalf("nested Seatbelt is denied; run outside any sandbox: %v %s", err, out)
	}
	user := installedCodexHome(t)
	// Unix socket paths are limited to 104 bytes: the home lies under a short temp path.
	short, err := os.MkdirTemp("/tmp", "awf")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(short) })
	if short, err = filepath.EvalSymlinks(short); err != nil {
		t.Fatal(err)
	}
	home := filepath.Join(short, "h")
	work := filepath.Join(home, "workers", testWorkID)
	scope := materialize(t, home, work)
	sibling := filepath.Join(home, "workers", "work-work-1111111111111111")
	// The sentinel contents carry a unique token that no path or error text contains (probeLeak).
	token := leakToken(t)
	sentinels := map[string]string{
		filepath.Join(sibling, "repo", "secret"):                    "SIBLING-" + token,
		filepath.Join(home, "workers", "slot1", "secret"):           "SLOT-" + token,
		filepath.Join(home, "frozen", "blobs", "x"):                 "FROZEN-" + token,
		filepath.Join(home, "bases", "b", "secret"):                 "BASE-" + token,
		filepath.Join(home, "work", "work-1.json"):                  "WORKSTORE-" + token,
		filepath.Join(home, "snapshots", "other", "tree", "secret"): "BASELINE-" + token,
		filepath.Join(home, "policy.json"):                          "POLICY-" + token,
		filepath.Join(home, "sources", "s1", "token"):               "SOURCE-" + token,
		filepath.Join(home, "local-source", "queue.json"):           "LOCAL-SOURCE-" + token,
	}
	for path, body := range sentinels {
		if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(body), 0600); err != nil {
			t.Fatal(err)
		}
	}
	var accepted atomic.Int32
	var sockets []string
	for _, name := range []string{"runtime.sock", "read.sock", "backend.sock"} {
		path := filepath.Join(home, name)
		listener, err := net.Listen("unix", path)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { listener.Close() })
		go func() {
			for {
				connection, err := listener.Accept()
				if err != nil {
					return
				}
				accepted.Add(1)
				connection.Close()
			}
		}()
		sockets = append(sockets, path)
	}
	inspector := filepath.Join(short, "atlas-runtime")
	if out, err := exec.Command("go", "build", "-o", inspector, "github.com/eyra/atlas/platform/atlas_runtime/host").CombinedOutput(); err != nil {
		t.Fatalf("build: %v %s", err, out)
	}
	scratch := filepath.Join(home, "scratch", "turn-sandbox")
	if err := os.MkdirAll(filepath.Join(scratch, "tmp"), 0700); err != nil {
		t.Fatal(err)
	}
	folder, err := folderArguments(scope, scratch, user, inspector)
	if err != nil {
		t.Fatal(err)
	}
	readOnly, err := sandboxArguments("read-only", work, home)
	if err != nil {
		t.Fatal(err)
	}
	output := filepath.Join(work, "repo", "node_modules")
	if err := os.MkdirAll(output, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(work, "repo", "readme"), []byte("FOLDER-CONTENT"), 0600); err != nil {
		t.Fatal(err)
	}
	setup, err := setupArguments(scope, []string{output}, scratch, user, false)
	if err != nil {
		t.Fatal(err)
	}
	// Created at the top of the home after the profiles were rendered: only the home deny covers them.
	writeLateHomeNames(t, home, "LATE-"+token)
	// Created after the profiles were rendered: only the sibling globs cover it.
	late := filepath.Join(home, "workers", "work-work-2222222222222222")
	if err := os.MkdirAll(late, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(late, "secret"), []byte("LATE-"+token), 0600); err != nil {
		t.Fatal(err)
	}
	environment := append(os.Environ(), "TMPDIR="+filepath.Join(scratch, "tmp"))
	shell := func(name string, args []string, script string) (string, error) {
		command := exec.Command(codex, append(append([]string{"sandbox", "-P", name, "-C", work}, args...), "--", "sh", "-c", script)...)
		command.Dir, command.Env = work, environment
		out, err := command.CombinedOutput()
		return string(out), err
	}
	for _, profile := range []struct {
		name     string
		args     []string
		writable bool
	}{{"atlas_folder", folder, true}, {"atlas_read_only", readOnly, false}, {setupProfile, setup, false}} {
		probes := []struct {
			script  string
			allowed bool
		}{
			{"cat repo/readme", true},
			{"echo edit > repo/p7a.txt", profile.writable},
			{fmt.Sprintf("ls -a %q", home), false},
			{fmt.Sprintf("ls -a %q", filepath.Join(home, "workers")), false},
			// Only the materialized-folder profile reads its record and baseline (status, diff).
			{"cat " + scope["record"].(string) + " " + filepath.Join(scope["baseline"].(string), "manifest.json"), profile.writable},
			{fmt.Sprintf("touch %q", filepath.Join(home, "planted")), false},
			{fmt.Sprintf("touch %q", filepath.Join(home, "workers", "planted")), false},
			{fmt.Sprintf("mkdir %q", filepath.Join(home, "workers", "work-work-3333333333333333")), false},
		}
		if profile.name == setupProfile {
			probes = append(probes, struct {
				script  string
				allowed bool
			}{"echo built > repo/node_modules/p7a.txt", true})
		}
		for _, name := range lateHomeNames {
			probes = append(probes, struct {
				script  string
				allowed bool
			}{fmt.Sprintf("cat %q", filepath.Join(home, name)), false})
		}
		for path := range sentinels {
			probes = append(probes, struct {
				script  string
				allowed bool
			}{fmt.Sprintf("cat %q", path), false})
		}
		for _, path := range []string{filepath.Join(late, "secret"), filepath.Join(sibling, "repo"), filepath.Join(home, "frozen")} {
			probes = append(probes, struct {
				script  string
				allowed bool
			}{fmt.Sprintf("cat %q 2>&1 || ls %q", path, path), false})
		}
		for _, socket := range sockets {
			probes = append(probes, struct {
				script  string
				allowed bool
			}{fmt.Sprintf("/usr/bin/nc -U -w 2 %q </dev/null", socket), false})
		}
		for _, probe := range probes {
			before := accepted.Load()
			out, err := shell(profile.name, profile.args, probe.script)
			t.Logf("%s %q: err=%v output=%q accepted=%v", profile.name, probe.script, err, out, accepted.Load() != before)
			if (err == nil) != probe.allowed {
				t.Errorf("%s %q: allowed=%v want %v: %s", profile.name, probe.script, err == nil, probe.allowed, out)
			}
			if leak := probeLeak(out, token); leak != "" {
				t.Errorf("%s %q leaked %s: %s", profile.name, probe.script, leak, out)
			}
			if probe.allowed && probe.script == "cat repo/readme" && !strings.Contains(out, "FOLDER-CONTENT") {
				t.Errorf("%s: the folder is not readable: %s", profile.name, out)
			}
			time.Sleep(50 * time.Millisecond)
			if accepted.Load() != before {
				t.Errorf("%s %q: a Runtime socket accepted a connection", profile.name, probe.script)
			}
		}
	}
	// Controls: outside the sandbox each socket accepts and each sentinel is readable.
	for _, socket := range sockets {
		before := accepted.Load()
		if out, err := exec.Command("/usr/bin/nc", "-U", "-w", "2", socket).CombinedOutput(); err != nil {
			t.Fatalf("unsandboxed control connect %s: %v %s", socket, err, out)
		}
		time.Sleep(50 * time.Millisecond)
		if accepted.Load() == before {
			t.Fatalf("unsandboxed control: %s accepted nothing", socket)
		}
	}
	for path, body := range sentinels {
		if read, err := os.ReadFile(path); err != nil || string(read) != body {
			t.Fatalf("control read %s: %v", path, err)
		}
	}
	for _, name := range lateHomeNames {
		if read, err := os.ReadFile(filepath.Join(home, name)); err != nil || string(read) != "LATE-"+token {
			t.Fatalf("control read %s: %v", name, err)
		}
	}
}
