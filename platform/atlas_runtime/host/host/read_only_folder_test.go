package host

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"testing"
)

// IS-Atlas-20: a read-only work in a Git checkout (a job's review) runs as a materialized folder
// whose scope is read_only: Bash reads the folder (Git included) and writes only its scratch, where
// its build goes (MIX_BUILD_ROOT); a write in the folder is refused by the sandbox.

// readOnly is scope with the Runtime's read_only flag.
func readOnly(scope map[string]any) map[string]any {
	frozen := map[string]any{"read_only": true}
	for key, value := range scope {
		frozen[key] = value
	}
	return frozen
}

func TestReadOnlyFolderCodexProfileReadsTheFolderAndWritesOnlyTheScratch(t *testing.T) {
	user := isolatedHome(t)
	home, dest := filepath.Join(user, "runtime"), filepath.Join(user, "work")
	scope := materialize(t, home, dest)
	scratch := filepath.Join(home, "scratch", "turn-1")
	inspector := filepath.Join(user, "bin", "atlas-runtime")
	writable, err := folderArguments(scope, scratch, user, inspector)
	if err != nil {
		t.Fatal(err)
	}
	args, err := folderArguments(readOnly(scope), scratch, user, inspector)
	if err != nil {
		t.Fatal(err)
	}
	q := func(path string) string { body, _ := json.Marshal(path); return string(body) }
	// The same profile as the writable folder's, with the folder read instead of written.
	want := slices.Clone(writable)
	want[1] = `default_permissions="atlas_read_only_folder"`
	want[3] = strings.Replace(strings.Replace(want[3], "atlas_folder={", "atlas_read_only_folder={", 1),
		q(dest)+`="write"`, q(dest)+`="read"`, 1)
	if !slices.Equal(args, want) {
		t.Fatalf("got  %q\nwant %q", args, want)
	}
	if strings.Contains(args[3], q(dest)+`="write"`) || !strings.Contains(args[3], q(scratch)+`="write"`) {
		t.Fatalf("the read-only folder must write only its scratch: %s", args[3])
	}
	if routed, err := permissionArguments(readOnly(scope), scratch, inspector, ""); err != nil || !slices.Equal(routed, want) {
		t.Fatalf("profile dispatch differs: %q %v", routed, err)
	}
}

func TestReadOnlyFolderClaudeSettingsFreezeTheFolder(t *testing.T) {
	user := isolatedHomeIn(t, outsideSystemTemp(t))
	t.Setenv("TMPDIR", t.TempDir())
	t.Setenv("CLAUDE_CONFIG_DIR", "")
	home, dest := filepath.Join(user, "runtime"), filepath.Join(user, "work")
	scope := materialize(t, home, dest)
	temporary := "/u/.ac-12345678"
	inspector := filepath.Join(user, "bin", "atlas-runtime")
	encoded, err := claudeFolderSettings(readOnly(scope), temporary, user, inspector)
	if err != nil {
		t.Fatal(err)
	}
	var settings struct {
		Sandbox struct {
			Filesystem struct{ AllowWrite, DenyWrite, AllowRead []string }
		}
		Permissions struct{ Deny []string }
	}
	if err := json.Unmarshal([]byte(encoded), &settings); err != nil {
		t.Fatal(err)
	}
	filesystem := settings.Sandbox.Filesystem
	// Bash writes only the private temp (its build and caches); the folder is read, never written.
	if !slices.Equal(filesystem.AllowWrite, []string{temporary}) {
		t.Fatalf("allowWrite %q", filesystem.AllowWrite)
	}
	if !slices.Contains(filesystem.DenyWrite, dest) || !slices.Contains(filesystem.AllowRead, dest) {
		t.Fatalf("the folder must be readable and denied writes: %s", encoded)
	}
	// The file-editing tools may not touch it either, whatever tools a later Runtime enables.
	for _, rule := range []string{"Edit(/" + dest + ")", "Write(/" + dest + ")", "Read(/" + dest + "/.git)"} {
		if !slices.Contains(settings.Permissions.Deny, rule) {
			t.Fatalf("permissions lack %s: %q", rule, settings.Permissions.Deny)
		}
	}
	// The writable folder's settings are unchanged by the flag's existence.
	if plain, err := claudeFolderSettings(scope, temporary, user, inspector); err != nil || plain == encoded ||
		!strings.Contains(plain, `"allowWrite":["`+dest+`","`+temporary+`"]`) {
		t.Fatalf("writable folder settings: %s %v", plain, err)
	}
}

func TestReadOnlyFolderLaunchBuildsInTheScratch(t *testing.T) {
	dest, home, folder, native, _, scope := folderLaunch(t, `env > "$0.env"
printf '%s\n' "$@" > "$0.args"
printf '%s\n' '{"type":"thread.started","thread_id":"native-session"}' '{"type":"turn.completed"}'
`)
	scratch := filepath.Join(home, "scratch", filepath.Base(folder))
	host := startHost(t, scopedArgs(t, native, dest, folder, readOnly(scope)))
	records, code := host.finish(t)
	if code != 0 || records[len(records)-1]["exit_code"] != 0.0 {
		t.Fatalf("code=%d records=%v stderr=%s", code, records, host.stderr.String())
	}
	environment, _ := os.ReadFile(native + ".env")
	for _, want := range []string{"MIX_BUILD_ROOT=" + scratch + "/_build", "REBAR_BASE_DIR=" + scratch + "/_build/rebar3", "TMPDIR=" + scratch + "/tmp"} {
		if !strings.Contains("\n"+string(environment), "\n"+want+"\n") {
			t.Fatalf("worker environment lacks %q:\n%s", want, environment)
		}
	}
	if argv, _ := os.ReadFile(native + ".args"); !strings.Contains(string(argv), `default_permissions="atlas_read_only_folder"`) {
		t.Fatalf("argv %s", argv)
	}
	// A writable folder's turn builds where it is, as before.
	plain := filepath.Join(t.TempDir(), "plain")
	fixture(t, filepath.Dir(plain), `env > "$0.env"
printf '%s\n' '{"type":"thread.started","thread_id":"native-session"}' '{"type":"turn.completed"}'
`)
	if records, code := startHost(t, scopedArgs(t, native, dest, folder, scope)).finish(t); code != 0 || records[len(records)-1]["exit_code"] != 0.0 {
		t.Fatalf("writable launch: code=%d records=%v", code, records)
	}
	if environment, _ := os.ReadFile(native + ".env"); strings.Contains(string(environment), "MIX_BUILD_ROOT=") {
		t.Fatalf("a writable folder got a scratch build:\n%s", environment)
	}
}

// The read-only folder under the installed `codex sandbox`: Git reads the checkout, a build writes the
// scratch's _build, and every write in the folder is refused by the sandbox. It needs the installed
// Codex CLI on macOS and nested Seatbelt (it skips inside an agent sandbox).
func TestReadOnlyFolderIsEnforcedByInstalledCodexSandbox(t *testing.T) {
	codex, err := exec.LookPath("codex")
	if runtime.GOOS != "darwin" || err != nil {
		t.Skip("requires the installed Codex CLI on macOS")
	}
	requireNestedSeatbelt(t)
	user := installedCodexHome(t)
	home, dest := filepath.Join(user, "runtime"), filepath.Join(user, "work")
	scope := materialize(t, home, dest)
	repo := filepath.Join(dest, "repo")
	for _, args := range [][]string{{"init", "-q", "-b", "work"}, {"commit", "-q", "--allow-empty", "-m", "the change"}} {
		command := exec.Command("git", append([]string{"-C", repo, "-c", "user.name=a", "-c", "user.email=a@a"}, args...)...)
		if out, err := command.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v %s", args, err, out)
		}
	}
	if err := os.WriteFile(filepath.Join(repo, "README.md"), []byte("base\n"), 0600); err != nil {
		t.Fatal(err)
	}
	inspector := filepath.Join(home, "atlas-runtime")
	if out, err := exec.Command("go", "build", "-o", inspector, "github.com/eyra/atlas/platform/atlas_runtime/host").CombinedOutput(); err != nil {
		t.Fatalf("build: %v %s", err, out)
	}
	scratch := filepath.Join(home, "scratch", "turn-review")
	for _, directory := range []string{"tmp", "_build"} {
		if err := os.MkdirAll(filepath.Join(scratch, directory), 0700); err != nil {
			t.Fatal(err)
		}
	}
	args, err := folderArguments(readOnly(scope), scratch, user, inspector)
	if err != nil {
		t.Fatal(err)
	}
	environment := append(os.Environ(), "TMPDIR="+filepath.Join(scratch, "tmp"), "MIX_BUILD_ROOT="+filepath.Join(scratch, "_build"),
		"GIT_CONFIG_GLOBAL="+os.DevNull, "GIT_CONFIG_NOSYSTEM=1")
	for _, probe := range []struct {
		script  string
		allowed bool
	}{
		{"cat repo/README.md && git -C repo log --oneline", true},
		{`echo built > "$MIX_BUILD_ROOT/app.beam" && cat "$MIX_BUILD_ROOT/app.beam"`, true},
		{`echo temp > "$TMPDIR/f" && cat "$TMPDIR/f"`, true},
		{"echo edit > repo/new.txt", false},
		{"echo edit >> repo/README.md", false},
		{"rm repo/README.md", false},
		{"mkdir repo/_build", false},
		{"git -C repo commit -q --allow-empty -m nope", false},
		{fmt.Sprintf("touch %q", filepath.Join(home, "planted")), false},
	} {
		command := exec.Command(codex, append(append([]string{"sandbox", "-P", "atlas_read_only_folder", "-C", dest}, args...), "--", "sh", "-c", probe.script)...)
		command.Dir, command.Env = dest, environment
		out, err := command.CombinedOutput()
		if (err == nil) != probe.allowed {
			t.Errorf("%q: allowed=%v want %v: %s", probe.script, err == nil, probe.allowed, out)
		}
	}
	if body, err := os.ReadFile(filepath.Join(repo, "README.md")); err != nil || string(body) != "base\n" {
		t.Fatalf("the checkout was changed: %q %v", body, err)
	}
	if _, err := os.Stat(filepath.Join(repo, "new.txt")); err == nil {
		t.Fatal("a file was written in the checkout")
	}
}
