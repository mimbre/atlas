package snapshot

import (
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"syscall"
	"testing"
)

// old is a folder materialized before revision handles, with saved turns bound to its scope.
type old struct {
	f                    *fixture
	home, dest           string
	oldID, newID         string
	turn, other, nothing string // turns/<id>: bound to the old scope, to another scope, to none
	successor            func(w http.ResponseWriter, r *http.Request) bool
}

// oldFolder materializes Code's fixture successor, then turns the result into what Runtime wrote
// before revision handles: the old baseline under the old ID with the manifest Code really
// served then, and a record naming it. Code now refuses the old ID as superseded.
func oldFolder(t *testing.T) *old {
	t.Helper()
	f, newID := codeFixture(t)
	v1 := mustRead(t, filepath.Join("testdata", "code-manifest-v1.json"))
	var reply struct {
		SnapshotID string `json:"snapshot_id"`
	}
	must(t, json.Unmarshal(v1, &reply))
	o := &old{f: f, oldID: reply.SnapshotID, newID: newID, turn: "turn-0000000000000001", other: "turn-0000000000000002", nothing: "turn-0000000000000003"}
	var err error
	o.home, err = filepath.EvalSymlinks(f.home)
	must(t, err)
	o.dest = filepath.Join(f.parent, "work")
	_, err = Materialize(f.home, newID, o.dest)
	must(t, err)

	built, baseline := filepath.Join(o.home, "snapshots", newID[7:]), filepath.Join(o.home, "snapshots", o.oldID[7:])
	must(t, os.Chmod(built, 0755))
	for name, data := range map[string][]byte{"manifest.json": bytes.Replace(v1, []byte(`,"snapshot_id":"`+o.oldID+`"`), nil, 1), "complete": []byte(o.oldID + "\n")} {
		must(t, os.Chmod(filepath.Join(built, name), 0644))
		must(t, os.WriteFile(filepath.Join(built, name), data, 0644))
		must(t, os.Chmod(filepath.Join(built, name), 0444))
	}
	must(t, os.Chmod(built, 0555))
	must(t, os.Rename(built, baseline))
	record, _ := json.Marshal(map[string]string{"destination": o.dest, "materialized_at": "2026-11-08T22:40:09Z", "snapshot_id": o.oldID})
	must(t, os.WriteFile(recordPath(o.home, o.dest), record, 0600))

	o.successor = func(w http.ResponseWriter, r *http.Request) bool {
		if !strings.Contains(r.URL.Path, o.oldID) {
			return false
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(409)
		fmt.Fprintf(w, `{"error":{"code":"snapshot_superseded","message":"use its successor","details":{"snapshot_id":%q,"successor":%q}}}`, o.oldID, newID)
		return true
	}
	f.hook = o.successor

	// Saved turns as the Elixir service writes them: unsorted keys, numbers as written.
	turn := func(id string, permissions any) string {
		scope := "null"
		if permissions != nil {
			data, err := marshal(permissions)
			must(t, err)
			scope = string(data)
		}
		return `{"id":"` + id + `","state":"finished","cwd":"` + o.dest + `","permissions":` + scope + `,"exit_code":0,"ratio":1.50,"session_id":"s"}`
	}
	o.write(t, filepath.Join("turns", o.turn, "turn.json"), turn(o.turn, o.scope(o.oldID)))
	o.write(t, filepath.Join("turns", o.turn, "claude-context.json"), `{"cwd":"`+o.dest+`","git":null,"permissions":`+o.json(t, o.scope(o.oldID))+`}`)
	o.write(t, filepath.Join("turns", o.turn, "process.json"), `{"args":[`+o.json(t, o.scope(o.oldID))+`]}`)
	o.write(t, filepath.Join("turns", o.other, "turn.json"), turn(o.other, o.scope("sha256:"+strings.Repeat("e", 64))))
	o.write(t, filepath.Join("turns", o.nothing, "turn.json"), turn(o.nothing, nil))
	o.write(t, filepath.Join("admissions", "a.json"), `{"binding":{"permissions":`+o.json(t, o.scope(o.oldID))+`}}`)
	return o
}

// scope is the materialized-folder scope of the folder at snapshot id, as FolderScope builds it.
func (o *old) scope(id string) map[string]any {
	return map[string]any{"baseline": filepath.Join(o.home, "snapshots", id[7:]), "home": o.home, "profile": "materialized-folder",
		"record": recordPath(o.home, o.dest), "repositories": []any{"beta", "repos/alpha"}, "root": o.dest, "snapshot_id": id, "version": 1}
}

func (o *old) json(t *testing.T, v any) string {
	data, err := marshal(v)
	must(t, err)
	return string(data)
}

func (o *old) write(t *testing.T, rel, data string) {
	must(t, os.MkdirAll(filepath.Dir(filepath.Join(o.home, rel)), 0700))
	must(t, os.WriteFile(filepath.Join(o.home, rel), []byte(data), 0600))
}

func (o *old) journal() string {
	return filepath.Join(o.home, "rebinds", fmt.Sprintf("%x", sha256.Sum256([]byte(o.dest))))
}

// records reads every file of the Runtime home outside the baselines.
func (o *old) records(t *testing.T) map[string]string {
	result := map[string]string{}
	for path, description := range describe(t, o.home) {
		if !strings.HasPrefix(path, "snapshots") && !strings.HasPrefix(path, "rebinds") {
			result[path] = description
		}
	}
	return result
}

// rewritten asserts after is before with only its permissions replaced by scope.
func rewritten(t *testing.T, before, after []byte, scope map[string]any) {
	t.Helper()
	s1, e1, err := locate(before, "permissions")
	must(t, err)
	s2, e2, err := locate(after, "permissions")
	must(t, err)
	var got, want any
	must(t, decode(after[s2:e2], &got))
	data, _ := marshal(scope)
	must(t, decode(data, &want))
	if !bytes.Equal(before[:s1], after[:s2]) || !bytes.Equal(before[e1:], after[e2:]) || !reflect.DeepEqual(got, want) {
		t.Fatalf("not an exact scope swap:\n%s\n%s", before, after)
	}
}

func refusedFolder(t *testing.T, home, dest, want string) {
	t.Helper()
	_, err := Inspect(home, dest, nil, false)
	_, verr := Verified(home, dest)
	_, serr := Submit(home, dest, "beta", changeA)
	for _, err := range []error{err, verr, serr} {
		if err == nil || !strings.Contains(err.Error(), want) {
			t.Fatalf("got %v, want an error containing %q", err, want)
		}
	}
}

func TestRebindMovesAnOldFolderAndItsSavedTurnsToTheSuccessor(t *testing.T) {
	o := oldFolder(t)
	must(t, os.WriteFile(filepath.Join(o.dest, "beta", "README.md"), []byte("worker edit\n"), 0644))
	must(t, os.WriteFile(filepath.Join(o.dest, "beta", "NEW.txt"), []byte("new\n"), 0644))
	must(t, os.WriteFile(filepath.Join(o.dest, "repos", "alpha", "other.txt"), []byte("other\n"), 0644))
	refusedFolder(t, o.home, o.dest, "predates revision handles; run atlas-runtime snapshot rebind --dest "+o.dest)

	folder := state(t, o.dest)
	oldBaseline := filepath.Join(o.home, "snapshots", o.oldID[7:])
	baseline := state(t, oldBaseline)
	before := o.records(t)
	turn := mustRead(t, filepath.Join(o.home, "turns", o.turn, "turn.json"))
	context := mustRead(t, filepath.Join(o.home, "turns", o.turn, "claude-context.json"))
	record := mustRead(t, recordPath(o.home, o.dest))

	result, err := Rebind(o.f.home, o.dest)
	must(t, err)
	files := []string{filepath.Join("turns", o.turn, "turn.json"), filepath.Join("turns", o.turn, "claude-context.json")}
	newBaseline := filepath.Join(o.home, "snapshots", o.newID[7:])
	want := map[string]any{"state": "rebound", "destination": o.dest, "snapshot_id": o.newID, "rebound_from": o.oldID, "baseline": newBaseline,
		"files": files, "not_bound": []string{filepath.Join("turns", o.other, "turn.json")}, "journal": filepath.Join(o.journal(), "journal.json")}
	if !reflect.DeepEqual(result, want) {
		t.Fatalf("got %v\nwant %v", result, want)
	}

	// The folder with its edits and the old baseline are untouched; the new baseline is the old tree.
	equal(t, state(t, o.dest), folder)
	equal(t, state(t, oldBaseline), baseline)
	equal(t, describe(t, filepath.Join(newBaseline, "tree")), codeTree(0444, 0555, 0555))
	if sum := sha256.Sum256(mustRead(t, filepath.Join(newBaseline, "manifest.json"))); fmt.Sprintf("sha256:%x", sum) != o.newID ||
		string(mustRead(t, filepath.Join(newBaseline, "complete"))) != o.newID+"\n" {
		t.Fatal("new baseline does not carry the successor's identity")
	}

	// Only the bound turn's two copies of the scope and the record changed, each from its backup.
	rewritten(t, turn, mustRead(t, filepath.Join(o.home, files[0])), o.scope(o.newID))
	rewritten(t, context, mustRead(t, filepath.Join(o.home, files[1])), o.scope(o.newID))
	after := o.records(t)
	for path := range before {
		if path != files[0] && path != files[1] && path != filepath.Join("materializations", filepath.Base(recordPath(o.home, o.dest))) && after[path] != before[path] {
			t.Errorf("%s changed: %s", path, after[path])
		}
	}
	for rel, data := range map[string][]byte{files[0]: turn, files[1]: context, filepath.Join("materializations", filepath.Base(recordPath(o.home, o.dest))): record} {
		if !bytes.Equal(mustRead(t, filepath.Join(o.journal(), "backup", rel)), data) {
			t.Errorf("backup of %s differs from the original", rel)
		}
	}
	var rebound map[string]string
	must(t, json.Unmarshal(mustRead(t, recordPath(o.home, o.dest)), &rebound))
	if rebound["snapshot_id"] != o.newID || rebound["rebound_from"] != o.oldID || rebound["materialized_at"] != "2026-11-08T22:40:09Z" || rebound["destination"] != o.dest {
		t.Fatalf("record %v", rebound)
	}

	// Offline status works on the folder again and reports the worker's edits, nothing else.
	_, changes := inspect(t, o.f.home, o.dest, nil, false)
	got := []string{}
	for _, c := range changes {
		got = append(got, c.Path+" "+c.Change)
	}
	if !slices.Equal(got, []string{"beta/NEW.txt added", "beta/README.md modified", "repos/alpha/other.txt added"}) {
		t.Fatalf("changes %v", got)
	}
	// FolderScope verifies against the canonical home, as Rebind scoped the turns; on macOS the
	// temp home is /var/... and its canonical form /private/var/....
	verified, err := Verified(o.home, o.dest)
	must(t, err)
	scope := o.scope(o.newID)
	if verified["snapshot_id"] != scope["snapshot_id"] || verified["baseline"] != scope["baseline"] || verified["record"] != scope["record"] ||
		verified["root"] != scope["root"] || !reflect.DeepEqual(verified["repositories"], scope["repositories"]) {
		t.Fatalf("verified %v differs from the new scope %v", verified, scope)
	}

	// A repeat reports the same rebind and changes nothing.
	settled := state(t, o.home)
	again, err := Rebind(o.f.home, o.dest)
	must(t, err)
	if !reflect.DeepEqual(again, want) {
		t.Fatalf("repeat got %v", again)
	}
	equal(t, state(t, o.home), settled)

	// A change opened before the migration resumes under its migrated request: Code kept it with
	// the successor and base revision, and only the missing blob is uploaded.
	code := &fakeCode{base: map[string]map[string]bool{"github.com/eyra/fixture-beta": {"README.md": true, "tools/build": true}}, bodies: map[string][]byte{},
		entries: map[string][]map[string]any{}, blobs: map[string][]byte{}, revisions: map[string]string{}}
	o.f.hook = func(w http.ResponseWriter, r *http.Request) bool { return o.successor(w, r) || code.handle(w, r) }
	var m manifest
	must(t, json.Unmarshal(mustRead(t, filepath.Join(newBaseline, "manifest.json")), &m))
	sum := func(data string) string { s := sha256.Sum256([]byte(data)); return fmt.Sprintf("%x", s) }
	entries := []map[string]any{
		{"kind": "file", "mode": "100644", "op": "write", "path": "NEW.txt", "sha256": sum("new\n"), "size": 4},
		{"kind": "file", "mode": "100644", "op": "write", "path": "README.md", "sha256": sum("worker edit\n"), "size": 12}}
	migrated, _ := json.Marshal(map[string]any{"base_revision": m.Repositories[0].Revision, "change_id": changeA, "entries": entries, "repository": "github.com/eyra/fixture-beta", "snapshot_id": o.newID})
	code.bodies[changeA] = migrated
	raw, _ := json.Marshal(entries)
	var decoded []map[string]any
	must(t, json.Unmarshal(raw, &decoded))
	code.entries[changeA] = decoded
	code.blobs[changeA+"/"+sum("new\n")] = []byte("new\n")
	submitted, err := Submit(o.f.home, o.dest, "beta", changeA)
	must(t, err)
	if !slices.Equal(code.log, []string{"POST /v1/changes", "PUT /v1/changes/" + changeA + "/blobs/" + sum("worker edit\n"), "POST /v1/changes/" + changeA + "/seal"}) ||
		submitted["state"] != "sealed" || submitted["base_revision"] != m.Repositories[0].Revision || submitted["snapshot_id"] != o.newID {
		t.Fatalf("submit %v, log %v", submitted, code.log)
	}
	equal(t, state(t, o.dest), folder)
}

// A worker's sandbox denies the Runtime home but the record, baseline and done marker, so status
// of a rebound folder there cannot read the journal: the marker shows the rebind finished, and
// without it the folder refuses with the read errors rather than as unfinished.
func TestStatusOfAReboundFolderWithAnUnreadableJournal(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root reads a file whatever its mode")
	}
	o := oldFolder(t)
	journal, marker := filepath.Join(o.journal(), "journal.json"), RebindMarker(o.home, o.dest)
	denied := func(t *testing.T, wantError bool) {
		t.Helper()
		must(t, os.Chmod(journal, 0))
		defer os.Chmod(journal, 0600)
		_, err := Inspect(o.f.home, o.dest, nil, true)
		_, verr := Verified(o.f.home, o.dest)
		for _, err := range []error{err, verr} {
			if (err != nil) != wantError {
				t.Fatalf("inspection with an unreadable journal: error %v, want refusal %t", err, wantError)
			}
		}
	}

	// Interrupted after the record names the successor: the journal alone says unfinished.
	defer func() { rebindStep = func(string) error { return nil } }()
	rebindStep = func(step string) error {
		if step == "verify" {
			return errors.New("interrupted")
		}
		return nil
	}
	if _, err := Rebind(o.f.home, o.dest); err == nil {
		t.Fatal("interrupted rebind succeeded")
	}
	denied(t, true)
	refusedFolder(t, o.home, o.dest, "the rebind of "+o.dest+" is unfinished")

	rebindStep = func(string) error { return nil }
	result, err := Rebind(o.f.home, o.dest)
	must(t, err)
	if string(mustRead(t, marker)) != o.dest+"\n" {
		t.Fatalf("done marker %q", mustRead(t, marker))
	}
	denied(t, false)
	_, changes := inspect(t, o.f.home, o.dest, nil, false)
	must(t, os.Chmod(journal, 0))
	_, denyChanges := inspect(t, o.f.home, o.dest, nil, false)
	must(t, os.Chmod(journal, 0600))
	if !reflect.DeepEqual(changes, denyChanges) {
		t.Fatalf("changes %v differ from %v", denyChanges, changes)
	}

	// A rebind done before its marker was written: a repeat writes it and reports the same rebind.
	must(t, os.Remove(marker))
	denied(t, true)
	again, err := Rebind(o.f.home, o.dest)
	must(t, err)
	if !reflect.DeepEqual(again, result) || string(mustRead(t, marker)) != o.dest+"\n" {
		t.Fatalf("repeat %v, marker %q", again, mustRead(t, marker))
	}
	denied(t, false)

	must(t, os.WriteFile(marker, []byte("/elsewhere\n"), 0600))
	denied(t, true)
	// Any other read error keeps its reason.
	must(t, os.Remove(journal))
	must(t, os.Mkdir(journal, 0700))
	if _, err := Inspect(o.home, o.dest, nil, true); err == nil {
		t.Fatal("inspection accepted a directory in place of the rebind journal")
	}
}

func TestInterruptedRebindResumesAndBlocksTheFolderUntilDone(t *testing.T) {
	for _, phase := range []string{"baseline", "backups", "files", "files turns/turn-0000000000000001/claude-context.json", "record", "verify"} {
		t.Run(phase, func(t *testing.T) {
			o := oldFolder(t)
			turn := mustRead(t, filepath.Join(o.home, "turns", o.turn, "turn.json"))
			context := mustRead(t, filepath.Join(o.home, "turns", o.turn, "claude-context.json"))
			defer func() { rebindStep = func(string) error { return nil } }()
			rebindStep = func(step string) error {
				if step == phase {
					return errors.New("interrupted")
				}
				return nil
			}
			if _, err := Rebind(o.f.home, o.dest); err == nil || !strings.Contains(err.Error(), "repeat the command to resume") {
				t.Fatalf("got %v", err)
			}
			refusedFolder(t, o.home, o.dest, "the rebind of "+o.dest+" is unfinished; run atlas-runtime snapshot rebind --dest "+o.dest+" again")
			// Code is not needed to resume: the journal holds the plan.
			o.f.hook = func(w http.ResponseWriter, r *http.Request) bool { codeError(w, 500, "down", "down"); return true }
			rebindStep = func(string) error { return nil }
			result, err := Rebind(o.f.home, o.dest)
			if err != nil || result["state"] != "rebound" {
				t.Fatalf("resume: %v %v", result, err)
			}
			rewritten(t, turn, mustRead(t, filepath.Join(o.home, "turns", o.turn, "turn.json")), o.scope(o.newID))
			rewritten(t, context, mustRead(t, filepath.Join(o.home, "turns", o.turn, "claude-context.json")), o.scope(o.newID))
			if _, err = Inspect(o.f.home, o.dest, nil, false); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestRebindRefusesBeforeAnyChange(t *testing.T) {
	cases := []struct {
		name, want string
		arrange    func(t *testing.T, o *old) func()
	}{
		{"service starting", "the Runtime service is starting or stopping", func(t *testing.T, o *old) func() {
			lock, err := os.OpenFile(filepath.Join(o.home, "service.lock"), os.O_CREATE|os.O_RDWR, 0600)
			must(t, err)
			must(t, syscall.Flock(int(lock.Fd()), syscall.LOCK_EX))
			return func() { lock.Close() }
		}},
		{"service state unknown", "cannot establish that the Runtime service is stopped", func(t *testing.T, o *old) func() {
			must(t, os.WriteFile(filepath.Join(o.home, "runtime.sock"), nil, 0600))
			return func() { os.Remove(filepath.Join(o.home, "runtime.sock")) }
		}},
		{"folder owned", "has an active Runtime owner", func(t *testing.T, o *old) func() {
			owner, err := os.Open(o.dest)
			must(t, err)
			must(t, syscall.Flock(int(owner.Fd()), syscall.LOCK_EX))
			return func() { owner.Close() }
		}},
		{"Code not migrated", "has not been migrated", func(t *testing.T, o *old) func() {
			o.f.hook = func(w http.ResponseWriter, r *http.Request) bool {
				w.Write(mustRead(t, filepath.Join("testdata", "code-manifest-v1.json")))
				return true
			}
			return func() {}
		}},
		{"successor differs", "differs in its entries or repositories", func(t *testing.T, o *old) func() {
			other, raw := snapshotOf(t, []repository{one}, synthetic[0])
			o.f.hook = func(w http.ResponseWriter, r *http.Request) bool {
				if strings.Contains(r.URL.Path, other) {
					w.Write(raw)
					return true
				}
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(409)
				fmt.Fprintf(w, `{"error":{"code":"snapshot_superseded","message":"m","details":{"successor":%q}}}`, other)
				return true
			}
			return func() {}
		}},
		{"tampered old baseline", "hashes to sha256:", func(t *testing.T, o *old) func() {
			path := filepath.Join(o.home, "snapshots", o.oldID[7:], "manifest.json")
			must(t, os.Chmod(filepath.Dir(path), 0755))
			must(t, os.Chmod(path, 0644))
			data := mustRead(t, path)
			must(t, os.WriteFile(path, append(data, ' '), 0644))
			return func() {}
		}},
		{"Code unavailable", "Code service unavailable", func(t *testing.T, o *old) func() {
			must(t, os.Remove(filepath.Join(o.home, "code.json")))
			return func() {}
		}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			o := oldFolder(t)
			before, folder := o.records(t), state(t, o.dest)
			done := c.arrange(t, o)
			_, err := Rebind(o.f.home, o.dest)
			done()
			if err == nil || !strings.Contains(err.Error(), c.want) {
				t.Fatalf("got %v, want %q", err, c.want)
			}
			after := o.records(t)
			delete(after, "service.lock")
			delete(before, "service.lock")
			if c.name == "Code unavailable" {
				delete(before, "code.json")
			}
			equal(t, after, before)
			equal(t, state(t, o.dest), folder)
			if _, err = os.Stat(o.journal()); !errors.Is(err, os.ErrNotExist) {
				t.Fatalf("a journal was written: %v", err)
			}
			if _, err = os.Stat(filepath.Join(o.home, "snapshots", o.newID[7:])); !errors.Is(err, os.ErrNotExist) {
				t.Fatal("a new baseline was published")
			}
		})
	}
}

func TestRebindStopsOnDriftAndKeepsTheFolderBlocked(t *testing.T) {
	o := oldFolder(t)
	path := filepath.Join(o.home, "turns", o.turn, "turn.json")
	defer func() { rebindStep = func(string) error { return nil } }()
	rebindStep = func(step string) error {
		if step == "files" {
			// The turn changes after it was planned and backed up.
			data := mustRead(t, path)
			must(t, os.WriteFile(path, bytes.Replace(data, []byte(`"state":"finished"`), []byte(`"state":"failed"`), 1), 0600))
		}
		return nil
	}
	_, err := Rebind(o.f.home, o.dest)
	if err == nil || !strings.Contains(err.Error(), "changed since its backup") {
		t.Fatalf("got %v", err)
	}
	drifted := mustRead(t, path)
	rebindStep = func(string) error { return nil }
	if _, err = Rebind(o.f.home, o.dest); err == nil || !strings.Contains(err.Error(), "changed since its backup") {
		t.Fatalf("repeat got %v", err)
	}
	if !bytes.Equal(mustRead(t, path), drifted) {
		t.Fatal("a drifted turn was rewritten")
	}
	var record map[string]string
	must(t, json.Unmarshal(mustRead(t, recordPath(o.home, o.dest)), &record))
	if record["snapshot_id"] != o.oldID {
		t.Fatal("the record moved on despite drift")
	}
	refusedFolder(t, o.home, o.dest, "is unfinished")
}

func TestRebindOfACurrentFolderChangesNothing(t *testing.T) {
	f, id := codeFixture(t)
	dest := filepath.Join(f.parent, "work")
	_, err := Materialize(f.home, id, dest)
	must(t, err)
	before := state(t, f.home)
	result, err := Rebind(f.home, dest)
	must(t, err)
	if result["state"] != "current" {
		t.Fatalf("got %v", result)
	}
	// Holding the service lock creates it, as service start does; nothing else changes.
	after := state(t, f.home)
	for _, path := range []string{f.home, filepath.Join(f.home, "service.lock")} {
		delete(after, path)
		delete(before, path)
	}
	equal(t, after, before)
}
