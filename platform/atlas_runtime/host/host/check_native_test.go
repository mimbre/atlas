//go:build darwin

package host

import (
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// checkAtomicTemporaries are the atomic-write temps and staging paths of the core and the helper in
// the Runtime home, relative to it, beside the records they replace (`path <> ".tmp"` then rename in
// the core; CreateTemp/MkdirTemp then rename in host/snapshot). HN requires each create to be denied.
var checkAtomicTemporaries = []struct {
	path      string
	directory bool
}{
	{path: "x.tmp"},
	{path: "execution-events.json.tmp"},              // persistence/execution_events.ex
	{path: "availability.json.tmp"},                  // availability.ex
	{path: "workers/.work-x.tmp"},                    // a sibling of the folder
	{path: "workers/slot1/admission-latch.json.tmp"}, // persistence/history.ex
	{path: "work/w1.json.tmp"},                       // work/store.ex
	{path: "turns/t1/turn.json.tmp"},                 // persistence/history.ex, restart_reconciliation.ex
	{path: "turns/t1/handoff.json.tmp"},              // handoffs/handoff_records.ex
	{path: "turns/t1/questions/q1.json.tmp"},         // interactions/question_records.ex
	{path: "turns/t1/peer-questions/q1.json.tmp"},    // interactions/peer_question_records.ex
	{path: "admissions/a1.json.tmp"},                 // execution/command_admissions.ex
	{path: "passes/p1.json.tmp"},                     // flow_passes.ex
	{path: "materializations/.record-x"},             // snapshot.go record
	{path: "frozen/blobs/.b.tmp"},
	{path: "frozen/blobs/.blob-x"},          // submit.go
	{path: "packets/k1/.discarded-x"},       // discard.go
	{path: "packets/k1/findings/.record-x"}, // findings.go publish
	{path: "rebinds/r1/.journal-1.tmp"},     // rebind.go
	{path: "scratch/rebuild-x", directory: true},
	{path: "scratch/prepare-x", directory: true},          // prepare.go
	{path: "workers/.atlas-snapshot-x", directory: true},  // snapshot.go, compose.go: beside the folder
	{path: "snapshots/.staging-x", directory: true},       // snapshot.go, rebind.go
	{path: "frozen/blobs/.changes-x", directory: true},    // changes.go
	{path: "packets/k1/.atlas-packet-x", directory: true}, // freeze.go
	{path: "preparations/.claim-x", directory: true},      // snapshot/prepare.go
	{path: "submissions/tmp-x", directory: true},          // submit.go
}

// TestCheckSandboxDeniesRuntimeSockets is gate HN: `host check` under the installed `codex sandbox`,
// with both of the turn's profiles, on a folder at <home>/workers/work-x (B6) beside a sibling worker
// and three listening Runtime sockets. It runs only with ATLAS_RUNTIME_NATIVE_SANDBOX=1, on macOS,
// outside any agent sandbox; with the variable set, a missing codex or a denied nested Seatbelt fails it.
func TestCheckSandboxDeniesRuntimeSockets(t *testing.T) {
	if os.Getenv("ATLAS_RUNTIME_NATIVE_SANDBOX") != "1" {
		t.Skip("gate HN: set ATLAS_RUNTIME_NATIVE_SANDBOX=1 on the mini, outside any agent sandbox (skipped = not run)")
	}
	codex, err := exec.LookPath("codex")
	if err != nil || !filepath.IsAbs(codex) {
		t.Fatalf("gate HN requires the installed codex on PATH: %q %v", codex, err)
	}
	if out, err := exec.Command("/usr/bin/sandbox-exec", "-p", "(version 1)(allow default)", "/usr/bin/true").CombinedOutput(); err != nil {
		t.Fatalf("gate HN must run outside any sandbox (nested Seatbelt): %v %s", err, out)
	}
	if out, err := exec.Command(codex, "--version").CombinedOutput(); err == nil {
		t.Logf("HN codex %s: %s", codex, strings.TrimSpace(string(out)))
	}
	user := installedCodexHome(t)
	t.Setenv("GH_TOKEN", "GH-SENTINEL")
	// Unix socket paths are limited to 104 bytes, so the home lives directly under /tmp.
	root, err := os.MkdirTemp("/tmp", "ck-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { removeScratch(root) })
	home, err := filepath.EvalSymlinks(root)
	if err != nil {
		t.Fatal(err)
	}
	if err = os.Chmod(home, 0700); err != nil {
		t.Fatal(err)
	}
	dest, scope := checkHome(t, user, home)
	fixture := &checkFixture{user: user, home: home, dest: dest, scope: scope}
	for path, body := range map[string]string{
		filepath.Join(home, "workers", "slot1", "sentinel"): "SLOT-SENTINEL",
		filepath.Join(home, "frozen", "blobs", "b"):         "FROZEN-SENTINEL",
	} {
		if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(body), 0600); err != nil {
			t.Fatal(err)
		}
	}
	// Existing records the cases below try to overwrite or rename (atomic-write targets).
	for path, body := range map[string]string{
		filepath.Join(home, "execution-events.json"): "EVENTS-SENTINEL",
	} {
		if err := os.WriteFile(path, []byte(body), 0600); err != nil {
			t.Fatal(err)
		}
	}
	// Control: the parent of every atomic temp exists and the same create works outside the check,
	// so a failure under the check is the profile's denial, not a missing directory.
	for _, temporary := range checkAtomicTemporaries {
		path := filepath.Join(home, temporary.path)
		if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			t.Fatal(err)
		}
		create := func() error { return os.WriteFile(path, nil, 0600) }
		if temporary.directory {
			create = func() error { return os.Mkdir(path, 0700) }
		}
		if err := create(); err != nil {
			t.Fatalf("control: cannot create %s outside the check: %v", path, err)
		}
		if err := os.Remove(path); err != nil {
			t.Fatal(err)
		}
	}
	accepted := map[string]*atomic.Int64{}
	for _, name := range expectedRuntimeSockets {
		listener, err := net.Listen("unix", filepath.Join(home, name))
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { listener.Close() })
		count := &atomic.Int64{}
		accepted[name] = count
		go func() {
			for {
				connection, err := listener.Accept()
				if err != nil {
					return
				}
				count.Add(1)
				connection.Close()
			}
		}()
	}
	// Control: the same nc outside host check connects to each socket.
	for _, name := range expectedRuntimeSockets {
		command := exec.Command("/usr/bin/nc", "-U", "-w", "2", filepath.Join(home, name))
		out, err := command.CombinedOutput()
		time.Sleep(200 * time.Millisecond)
		t.Logf("HN control %s: err=%v accepted=%d output=%q", name, err, accepted[name].Load(), out)
		if err != nil || accepted[name].Load() != 1 {
			t.Fatalf("control nc did not connect to %s: %v %s", name, err, out)
		}
	}

	exitOf := func(line map[string]any) any { return line["exit_status"] }
	for _, mode := range []string{"materialized-folder", "read-only"} {
		run := func(argv ...string) map[string]any {
			args := fixture.args(t, 60, 2, 16384, argv...)
			if mode == "read-only" {
				args = fixture.readOnlyArgs(60, 2, 16384, argv...)
			}
			return ended(t, args, 90*time.Second)
		}
		report := func(name string, line map[string]any, accepted string) {
			tail, _ := tailOf(line)
			t.Logf("HN %s | %s: exit_status=%v signal=%v accepted=%s output=%q", mode, name, exitOf(line), line["signal"], accepted, tail)
		}
		denied := func(name string, line map[string]any) {
			t.Helper()
			report(name, line, "-")
			tail, _ := tailOf(line)
			if exitOf(line) == 0.0 || strings.Contains(tail, "SENTINEL") {
				t.Errorf("HN %s | %s was allowed or leaked: %v", mode, name, line)
			}
		}

		probe := filepath.Join(dest, "p")
		line := run("touch", probe)
		report("write the folder", line, "-")
		_, statErr := os.Lstat(probe)
		if mode == "materialized-folder" && (exitOf(line) != 0.0 || statErr != nil) || mode == "read-only" && (exitOf(line) == 0.0 || statErr == nil) {
			t.Errorf("HN %s | write the folder: %v (file: %v)", mode, line, statErr)
		}
		os.Remove(probe)
		// Positive control in both profiles: the folder is readable, so a denial below is the profile's.
		if line := run("ls", "-A", dest); exitOf(line) != 0.0 {
			t.Errorf("HN %s | list the folder: %v", mode, line)
		} else {
			report("list the folder (positive control)", line, "-")
		}
		denied("read a sibling worker", run("cat", filepath.Join(home, "workers", "slot1", "sentinel")))
		denied("list the frozen store", run("ls", filepath.Join(home, "frozen")))
		denied("list the Runtime home", run("ls", home))
		// B2: no write or create in the Runtime home outside the folder and the check's own scratch,
		// at every place where the core or the helper puts an atomic temp or a rename target.
		for _, temporary := range checkAtomicTemporaries {
			path := filepath.Join(home, temporary.path)
			argv := []string{"touch", path}
			if temporary.directory {
				argv = []string{"mkdir", path}
			}
			denied("create "+temporary.path, run(argv...))
			if _, err := os.Lstat(path); !errors.Is(err, os.ErrNotExist) {
				t.Errorf("HN %s | create %s: the path exists afterwards (%v)", mode, temporary.path, err)
				os.RemoveAll(path)
			}
		}
		events := filepath.Join(home, "execution-events.json")
		denied("overwrite execution-events.json", run("sh", "-c", `printf X > "$0"`, events))
		denied("rename a sibling worker's file", run("mv", filepath.Join(home, "workers", "slot1", "sentinel"), filepath.Join(home, "workers", "slot1", "sentinel.tmp")))
		for path, want := range map[string]string{events: "EVENTS-SENTINEL", filepath.Join(home, "workers", "slot1", "sentinel"): "SLOT-SENTINEL"} {
			if body, err := os.ReadFile(path); err != nil || string(body) != want {
				t.Errorf("HN %s | %s was changed: %q %v", mode, path, body, err)
				os.WriteFile(path, []byte(want), 0600) // S3: the next profile starts from the seeded state
			}
		}
		if _, err := os.Lstat(filepath.Join(home, "workers", "slot1", "sentinel.tmp")); !errors.Is(err, os.ErrNotExist) {
			t.Errorf("HN %s | rename target exists afterwards: %v", mode, err)
			os.Remove(filepath.Join(home, "workers", "slot1", "sentinel.tmp"))
		}
		for _, name := range expectedRuntimeSockets {
			before := accepted[name].Load()
			line := run("nc", "-U", "-w", "2", filepath.Join(home, name))
			time.Sleep(200 * time.Millisecond)
			connected := accepted[name].Load() != before
			report("connect "+name, line, fmt.Sprint(connected))
			if exitOf(line) == 0.0 || connected {
				t.Errorf("HN %s | the check reached %s: %v accepted=%v", mode, name, line, connected)
			}
		}
		if mode == "materialized-folder" {
			line := run("sh", "-c", `nc -U -l "$TMPDIR/p.sock" & sleep 1; nc -U -w 2 "$TMPDIR/p.sock" </dev/null`)
			report("Unix socket inside the scratch (positive control)", line, "-")
			if exitOf(line) != 0.0 {
				t.Errorf("HN positive control: %v", line)
			}
		} else {
			// B24: the read-only profile grants no scratch (P0 T4 not run: this is the first evidence).
			denied("write the scratch", run("sh", "-c", `touch "$TMPDIR/x"`))
		}
		line = run("env")
		tail, _ := tailOf(line)
		report("environment", line, "-")
		if exitOf(line) != 0.0 || !strings.Contains(tail, "TMPDIR=") {
			t.Errorf("HN %s | env did not run: %v", mode, line)
		}
		for _, entry := range strings.Split(strings.TrimSpace(tail), "\n") {
			if !checkEnvironmentAllows(entry) {
				t.Errorf("HN %s | environment holds %q", mode, entry)
			}
		}
	}
	// No S3 TCP listener exists in this tree (backend.sock only), so P0 T3c has no case here.
}
