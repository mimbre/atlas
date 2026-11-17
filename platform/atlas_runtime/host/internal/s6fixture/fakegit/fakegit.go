// Package fakegit installs the fake `git` of the S6 repository parity test (plan s6-plan.md,
// A4) for one table row: a `git` on PATH that logs its argv and answers from the row's script,
// and a `sandbox` prefix that stands in for `codex sandbox … -C DIR … --`. The command itself
// is ./cmd; Build compiles it once per test. Only tests import this package.
//
// Its file names (bin, sandbox, script.json, log.jsonl; HEAD and config in ./cmd) are built by
// concatenation, not filepath.Join literals: they are test-fixture names, never Runtime home
// entries, and A4 does not edit P0's home census (host/host/runtime_home_census_test.go),
// which classifies every filepath.Join literal of a non-test file.
package fakegit

import (
	"bufio"
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

// Build compiles ./cmd into a fresh temporary directory and returns the binary's path.
func Build(t testing.TB) string {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	for {
		if _, err := os.Stat(dir + "/go.mod"); err == nil {
			break
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			t.Fatal("fakegit: no go.mod above the test's directory")
		}
		dir = parent
	}
	binary := t.TempDir() + "/fakegit"
	command := exec.Command("go", "build", "-o", binary, "./internal/s6fixture/fakegit/cmd")
	command.Dir = dir
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("building fakegit: %v\n%s", err, output)
	}
	return binary
}

// Fake is the fake git installed for one row.
type Fake struct {
	bin, log string
}

// Install writes the row's script, links `git` and `sandbox` to binary in a new directory, puts
// that directory first on PATH, and points the fake at root (for logging working directories),
// the script and a fresh log. script maps a git argument list (without the global -c/-C
// options, joined by spaces) to {stdout, stderr, code, effect}.
func Install(t testing.TB, binary, root string, script any) *Fake {
	t.Helper()
	dir := t.TempDir()
	bin := dir + "/bin"
	if err := os.Mkdir(bin, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"git", "sandbox"} {
		if err := os.Symlink(binary, filepath.Join(bin, name)); err != nil {
			t.Fatal(err)
		}
	}
	if script == nil {
		script = map[string]any{}
	}
	data, err := json.Marshal(script)
	if err != nil {
		t.Fatal(err)
	}
	scriptPath := dir + "/script.json"
	if err := os.WriteFile(scriptPath, data, 0o600); err != nil {
		t.Fatal(err)
	}
	real, err := exec.LookPath("git")
	if err != nil {
		t.Fatalf("fakegit: the real git is needed for check-ref-format: %v", err)
	}
	if real, err = filepath.Abs(real); err != nil {
		t.Fatal(err)
	}
	fake := &Fake{bin: bin, log: dir + "/log.jsonl"}
	t.Setenv("S6_FAKEGIT_REAL", real)
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("S6_FAKEGIT_SCRIPT", scriptPath)
	t.Setenv("S6_FAKEGIT_LOG", fake.log)
	t.Setenv("S6_FAKEGIT_ROOT", root)
	return fake
}

// Prefix is the sandbox prefix for a run in dir, shaped like the helper's
// `codex sandbox -P atlas_repository -C DIR … --` (host.go executeAssignment).
func (f *Fake) Prefix(dir string) []string {
	return []string{f.bin + "/sandbox", "-P", "atlas_repository", "-C", dir, "--"}
}

// Reset empties the log.
func (f *Fake) Reset(t testing.TB) {
	t.Helper()
	if err := os.Remove(f.log); err != nil && !os.IsNotExist(err) {
		t.Fatal(err)
	}
}

// Calls returns the logged calls in order, as generic JSON values.
func (f *Fake) Calls(t testing.TB) []any {
	t.Helper()
	calls := []any{}
	data, err := os.ReadFile(f.log)
	if os.IsNotExist(err) {
		return calls
	}
	if err != nil {
		t.Fatal(err)
	}
	scanner := bufio.NewScanner(bytes.NewReader(data))
	scanner.Buffer(make([]byte, 0, 1<<16), 1<<24)
	for scanner.Scan() {
		decoder := json.NewDecoder(bytes.NewReader(scanner.Bytes()))
		decoder.UseNumber()
		var call any
		if err := decoder.Decode(&call); err != nil {
			t.Fatal(err)
		}
		calls = append(calls, call)
	}
	if err := scanner.Err(); err != nil {
		t.Fatal(err)
	}
	return calls
}
