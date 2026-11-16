package snapshot

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const changeUUID = "6f1c2b8e-3d4a-4f5b-9c6d-7e8f9a0b1c2d"

// localFolder records dest as Materialize would for a snapshot of repository one holding files,
// without a Code service, and returns the Runtime home, destination and snapshot ID.
func localFolder(t *testing.T, files map[string]string) (string, string, string) {
	t.Helper()
	root, err := canonicalDirectory(t.TempDir())
	must(t, err)
	home, dest := filepath.Join(root, "runtime"), filepath.Join(root, "work")
	m := manifest{Repositories: []repository{one}, Version: 2}
	for rel, data := range files {
		m.Entries = append(m.Entries, file(one, rel, "100644", data))
	}
	raw := m.canonical()
	id, _ := snapshotOf(t, m.Repositories, m.Entries...)
	baseline := filepath.Join(home, "snapshots", strings.TrimPrefix(id, "sha256:"))
	for rel, data := range files {
		for _, path := range []string{filepath.Join(baseline, "tree", one.Path, rel), filepath.Join(dest, one.Path, rel)} {
			must(t, os.MkdirAll(filepath.Dir(path), 0755))
			must(t, os.WriteFile(path, []byte(data), 0644))
		}
	}
	must(t, os.WriteFile(filepath.Join(baseline, "manifest.json"), raw, 0444))
	must(t, os.WriteFile(filepath.Join(baseline, "complete"), []byte(id+"\n"), 0444))
	must(t, record(home, dest, id))
	return home, dest, id
}

// prepared records a succeeded npm-ci preparation of one/app, as the preparation command would.
func prepared(t *testing.T, home, dest, id string) {
	t.Helper()
	p := &Preparation{Version: 1, Destination: dest, SnapshotID: id, Kind: "npm-ci", Path: "one/app", Outputs: []string{"one/app/node_modules"},
		State: "running", StartedAt: "2026-11-09T00:00:00Z"}
	must(t, BeginPreparation(home, p, map[string]any{"private": true}))
	p.State, p.EndedAt = "succeeded", "2026-11-09T00:01:00Z"
	must(t, FinishPreparation(home, p))
}

func TestPreparedOutputIsSkippedOnlyAsARealDirectory(t *testing.T) {
	home, dest, id := localFolder(t, map[string]string{"app/package.json": "{}\n", "app/main.js": "run()\n"})
	result, _ := inspect(t, home, dest, nil, false)
	if _, present := result["preparation"]; present {
		t.Fatalf("a folder that was never prepared reports a preparation: %v", result)
	}
	prepared(t, home, dest, id)
	outside := t.TempDir()
	must(t, os.WriteFile(filepath.Join(outside, "secret.txt"), []byte("outside\n"), 0644))
	modules := filepath.Join(dest, "one", "app", "node_modules")
	must(t, os.MkdirAll(filepath.Join(modules, "pkg"), 0755))
	must(t, os.WriteFile(filepath.Join(modules, "pkg", "index.js"), []byte("x\n"), 0644))
	must(t, os.Symlink(outside, filepath.Join(modules, "escape")))
	for _, diffs := range []bool{false, true} {
		result, changes := inspect(t, home, dest, nil, diffs)
		want := map[string]any{"kind": "npm-ci", "path": "one/app", "outputs": []string{"one/app/node_modules"}, "state": "succeeded", "ready": true}
		if result["clean"] != true || len(changes) != 0 || fmt.Sprint(result["preparation"]) != fmt.Sprint(want) {
			t.Fatalf("diffs=%v: the prepared output is not skipped: %v", diffs, result)
		}
	}
	// Only the output is skipped: a tracked edit beside it is still a change, also with --path.
	must(t, os.WriteFile(filepath.Join(dest, "one", "app", "main.js"), []byte("edited()\n"), 0644))
	if _, changes := inspect(t, home, dest, []string{"one"}, false); len(changes) != 1 || changes[0].Path != "one/app/main.js" {
		t.Fatalf("got %v", changes)
	}
	must(t, os.WriteFile(filepath.Join(dest, "one", "app", "main.js"), []byte("run()\n"), 0644))
	if submitted, err := Submit(home, dest, "", changeUUID, ""); err != nil || submitted["state"] != "clean" {
		t.Fatalf("a folder changed only in its output must submit as clean without Code: %v %v", submitted, err)
	}

	// A symlink in the output's place is an ordinary added link, never followed, and submit refuses
	// it locally because it leaves the repository.
	must(t, os.RemoveAll(modules))
	must(t, os.Symlink(outside, modules))
	_, changes := inspect(t, home, dest, nil, false)
	if len(changes) != 1 || changes[0].Path != "one/app/node_modules" || changes[0].Change != "added" || changes[0].NewTarget != outside {
		t.Fatalf("a symlinked output must be reported as the link itself: %v", changes)
	}
	token := filepath.Join(t.TempDir(), "runtime.token")
	must(t, os.WriteFile(token, []byte("secret\n"), 0600))
	must(t, os.WriteFile(filepath.Join(home, "code.json"), []byte(fmt.Sprintf(`{"url":"http://127.0.0.1:1","token_file":%q}`, token)), 0600))
	if _, err := Submit(home, dest, "", changeUUID, ""); err == nil || !strings.Contains(err.Error(), "cannot submit one/app/node_modules") {
		t.Fatalf("submit must refuse the escaping output link locally: %v", err)
	}
}

// run is the JSON of a version 2 npm-run result of one/app with outputs, after an npm-ci in state,
// or with no npm-ci when state is empty; it formats with the destination and snapshot ID.
func run(outputs, state string) string {
	previous := ""
	if state != "" {
		previous = `,"previous":{"version":1,"destination":%[1]q,"snapshot_id":%[2]q,"kind":"npm-ci","path":"one/app","outputs":["one/app/node_modules"],"state":"` + state + `","started_at":"x"}`
	}
	return `{"version":2,"destination":%[1]q,"snapshot_id":%[2]q,"kind":"npm-run","path":"one/app","script":"build","outputs":` + outputs + `,"state":"succeeded","started_at":"x"` + previous + `}`
}

func TestPreparationResultsFailClosed(t *testing.T) {
	for _, test := range []struct {
		name, result, want string
		tracked            bool
	}{
		{"tracked output", `{"version":1,"destination":%q,"snapshot_id":%q,"kind":"npm-ci","path":"one/app","outputs":["one/app/node_modules"],"state":"succeeded","started_at":"x"}`, "would exclude tracked one/app/node_modules/kept.js", true},
		{"other snapshot", `{"version":1,"destination":%q,"snapshot_id":"sha256:` + strings.Repeat("0", 64) + `","kind":"npm-ci","path":"one/app","outputs":["one/app/node_modules"],"state":"succeeded","started_at":"x"}%.0s`, "names snapshot sha256:000", false},
		{"undeclared output", `{"version":1,"destination":%q,"snapshot_id":%q,"kind":"npm-ci","path":"one/app","outputs":["one/app"],"state":"succeeded","started_at":"x"}`, "invalid preparation result", false},
		{"unknown field", `{"version":1,"destination":%q,"snapshot_id":%q,"kind":"npm-ci","path":"one/app","outputs":["one/app/node_modules"],"state":"succeeded","started_at":"x","log":"y"}`, "invalid preparation result", false},
		{"package outside repositories", `{"version":1,"destination":%q,"snapshot_id":%q,"kind":"npm-ci","path":"other","outputs":["other/node_modules"],"state":"succeeded","started_at":"x"}`, "in no repository", false},
		{"version 1 with a script", `{"version":1,"destination":%q,"snapshot_id":%q,"kind":"npm-ci","path":"one/app","script":"build","outputs":["one/app/node_modules"],"state":"succeeded","started_at":"x"}`, "invalid preparation result", false},
		{"run without its npm-ci", run(`["one/app/dist"]`, ""), "invalid preparation result", false},
		{"run after a failed npm-ci", run(`["one/app/dist"]`, "failed"), "invalid preparation result", false},
		{"run with unsorted outputs", run(`["one/app/dist","one/app/.build"]`, "succeeded"), "invalid preparation result", false},
		{"run writing node_modules", run(`["one/app/node_modules/x"]`, "succeeded"), "invalid preparation result", false},
		{"run output in no repository", run(`["other"]`, "succeeded"), "names output other outside the repository of one/app", false},
	} {
		t.Run(test.name, func(t *testing.T) {
			files := map[string]string{"app/package.json": "{}\n"}
			if test.tracked {
				files["app/node_modules/kept.js"] = "tracked\n"
			}
			home, dest, id := localFolder(t, files)
			path := PreparationResult(home, dest)
			must(t, os.MkdirAll(filepath.Dir(path), 0700))
			must(t, os.WriteFile(path, []byte(fmt.Sprintf(test.result, dest, id)), 0600))
			for _, err := range []error{
				func() error { _, err := Inspect(home, dest, nil, false); return err }(),
				func() error { _, err := Submit(home, dest, "", changeUUID, ""); return err }(),
				func() error { _, err := Verified(home, dest); return err }(),
			} {
				if err == nil || !strings.Contains(err.Error(), test.want) {
					t.Fatalf("got %v, want %q", err, test.want)
				}
			}
		})
	}
	// A result that exists but cannot be read is an error, never a folder without exclusions.
	home, dest, id := localFolder(t, map[string]string{"app/package.json": "{}\n"})
	prepared(t, home, dest, id)
	must(t, os.Chmod(PreparationResult(home, dest), 0))
	if _, err := Inspect(home, dest, nil, false); err == nil || !strings.Contains(err.Error(), "cannot read the preparation result") {
		t.Fatalf("got %v", err)
	}
}

func TestBeginPreparationNeverReplacesARecord(t *testing.T) {
	home, dest, id := localFolder(t, map[string]string{"app/package.json": "{}\n"})
	prepared(t, home, dest, id)
	p := &Preparation{Version: 1, Destination: dest, SnapshotID: id, Kind: "npm-ci", Path: "one/app", Outputs: []string{"one/app/node_modules"}, State: "running", StartedAt: "y"}
	if err := BeginPreparation(home, p, nil); err == nil || !strings.Contains(err.Error(), "already has a preparation record") {
		t.Fatalf("got %v", err)
	}
	recorded, err := LoadPreparation(home, dest)
	if err != nil || recorded.State != "succeeded" || recorded.StartedAt != "2026-11-09T00:00:00Z" {
		t.Fatalf("the recorded preparation changed: %+v %v", recorded, err)
	}
	if entries, _ := os.ReadDir(filepath.Join(home, "preparations")); len(entries) != 1 {
		t.Fatalf("a refused claim left staging behind: %v", entries)
	}
}

func TestRunOutputsAreExcludedOnlyWhileWhollyUntracked(t *testing.T) {
	home, dest, id := localFolder(t, map[string]string{"app/package.json": "{}\n", "app/dist/app.css": "built\n"})
	prepared(t, home, dest, id)
	installed, err := LoadPreparation(home, dest)
	must(t, err)
	p := &Preparation{Version: 2, Destination: dest, SnapshotID: id, Kind: "npm-run", Path: "one/app", Script: "build", Outputs: []string{"one/app/.build", "one/app/dist"},
		State: "running", StartedAt: "2026-11-09T00:02:00Z", Previous: installed}
	must(t, BeginRun(home, p, map[string]any{"private": true}))
	if err := BeginRun(home, p, nil); err == nil || !strings.Contains(err.Error(), "already has an npm-run preparation record") {
		t.Fatalf("got %v", err)
	}
	p.State, p.EndedAt = "succeeded", "2026-11-09T00:03:00Z"
	must(t, FinishPreparation(home, p))
	for _, dir := range []string{filepath.Join(dest, "one", "app", "node_modules", "pkg"), filepath.Join(dest, "one", "app", ".build", "tmp")} {
		must(t, os.MkdirAll(dir, 0755))
		must(t, os.WriteFile(filepath.Join(dir, "x.js"), []byte("x\n"), 0644))
	}
	for _, diffs := range []bool{false, true} {
		result, changes := inspect(t, home, dest, nil, diffs)
		want := "map[excluded:[one/app/node_modules one/app/.build] kind:npm-run outputs:[one/app/.build one/app/dist] path:one/app ready:true script:build state:succeeded]"
		if result["clean"] != true || len(changes) != 0 || fmt.Sprint(result["preparation"]) != want {
			t.Fatalf("diffs=%v: %v", diffs, result)
		}
	}
	if submitted, err := Submit(home, dest, "", changeUUID, ""); err != nil || submitted["state"] != "clean" {
		t.Fatalf("got %v %v", submitted, err)
	}
	// The tracked output is not excluded: a file added there and an edit to its tracked file are changes.
	must(t, os.WriteFile(filepath.Join(dest, "one", "app", "dist", "new.css"), []byte("x\n"), 0644))
	must(t, os.WriteFile(filepath.Join(dest, "one", "app", "dist", "app.css"), []byte("other\n"), 0644))
	if _, changes := inspect(t, home, dest, nil, false); len(changes) != 2 || changes[0].Path != "one/app/dist/app.css" || changes[1].Path != "one/app/dist/new.css" {
		t.Fatalf("got %v", changes)
	}
}
