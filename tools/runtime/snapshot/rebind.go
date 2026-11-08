package snapshot

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"syscall"
	"time"
)

// Rebind moves the materialized folder dest from its snapshot from before revision handles to
// the successor Code names for it, without touching the folder. The successor must have exactly
// the old entries and the same repository names and paths. Its baseline is copied from the old
// one with every file re-hashed. Then the saved turns bound to the folder's old scope, their
// Claude contexts and the materialization record are switched to the new scope, so those turns
// still continue. Admissions, process logs and events stay as they were, and so do the old
// baseline and any turn whose scope is not exactly the old one.
//
// Each step is recorded in rebinds/<sha256 of dest>/journal.json before it happens, and every
// original file is backed up there first, so an interrupted rebind resumes when repeated;
// until it is done, the folder's scope, status, diff and submit refuse. A finished rebind also
// leaves its done marker there. The Runtime service must be stopped and nothing may own the folder.
func Rebind(home, dest string) (map[string]any, error) {
	home, err := filepath.EvalSymlinks(home)
	if err != nil {
		return nil, err
	}
	if dest, err = materialized(dest); err != nil {
		return nil, err
	}
	service, err := stopped(home)
	if err != nil {
		return nil, err
	}
	defer service.Close()
	folder, err := own(dest)
	if err != nil {
		return nil, err
	}
	defer folder.Close()

	dir := rebindDir(home, dest)
	j, err := loadJournal(dir)
	if err != nil {
		return nil, err
	}
	if j == nil {
		if j, err = plan(home, dest, dir); err != nil || j == nil {
			return map[string]any{"state": "current", "destination": dest}, err
		}
	}
	for j.Phase != "done" {
		if err = rebindStep(j.Phase); err == nil {
			err = j.step(home, dir)
		}
		if err != nil {
			return nil, fmt.Errorf("rebind of %s stopped in phase %s: %v; repeat the command to resume", dest, j.Phase, err)
		}
	}
	// A repeat also writes the marker of a rebind that finished without one.
	if err = j.mark(dir); err != nil {
		return nil, fmt.Errorf("rebind of %s is done but its done marker is not written: %v; repeat the command", dest, err)
	}
	return j.result(dir), nil
}

// rebindDir holds the rebind of dest: its journal, backups and done marker.
func rebindDir(home, dest string) string {
	return filepath.Join(home, "rebinds", fmt.Sprintf("%x", sha256.Sum256([]byte(dest))))
}

// RebindMarker is where a finished rebind of dest leaves its done marker, which holds only dest.
// A worker's sandbox may read it, never the journal with its plan of turns and scopes.
func RebindMarker(home, dest string) string {
	return filepath.Join(rebindDir(home, dest), "done")
}

// mark writes the done marker of a finished rebind unless it is already there.
func (j *journal) mark(dir string) error {
	path := filepath.Join(dir, "done")
	if data, err := os.ReadFile(path); err == nil && string(data) == j.Destination+"\n" {
		return nil
	}
	return replace(path, []byte(j.Destination+"\n"), 0600)
}

// rebindStep runs before each phase and each file swap; tests interrupt a rebind there.
var rebindStep = func(string) error { return nil }

// rebound refuses a folder whose rebind has started and not finished. Where the journal exists
// but may not be read, as in a worker's sandbox, only the done marker shows the rebind finished;
// without it the folder refuses with both read errors, not as unfinished.
func rebound(home, dest string) error {
	path := filepath.Join(rebindDir(home, dest), "journal.json")
	data, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return nil
	} else if errors.Is(err, fs.ErrPermission) {
		marker := RebindMarker(home, dest)
		done, merr := os.ReadFile(marker)
		if merr == nil && string(done) == dest+"\n" {
			return nil
		} else if merr == nil {
			merr = errors.New("it names another folder")
		}
		return fmt.Errorf("cannot tell whether the rebind of %s finished: cannot read its journal %s: %v; cannot read its done marker %s: %v; "+
			"outside the worker sandbox, atlas-runtime snapshot rebind --dest %s finishes it or writes the marker", dest, path, reason(err), marker, reason(merr), dest)
	} else if err != nil {
		return fmt.Errorf("cannot read the rebind journal %s of %s: %v", path, dest, reason(err))
	}
	var j journal
	if json.Unmarshal(data, &j) != nil || j.Phase != "done" {
		return fmt.Errorf("the rebind of %s is unfinished; run atlas-runtime snapshot rebind --dest %s again", dest, dest)
	}
	return nil
}

// stopped holds the Runtime service lock, so no service starts meanwhile, and proves no service
// listens on the socket: absent, or present with the connection refused. Anything else refuses.
func stopped(home string) (*os.File, error) {
	lock, err := os.OpenFile(filepath.Join(home, "service.lock"), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	if err = syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		lock.Close()
		return nil, errors.New("the Runtime service is starting or stopping; nothing was changed, run the command again once it is stopped")
	}
	socket := filepath.Join(home, "runtime.sock")
	if _, err = os.Lstat(socket); errors.Is(err, fs.ErrNotExist) {
		return lock, nil
	}
	conn, err := net.DialTimeout("unix", socket, time.Second)
	if err == nil {
		conn.Close()
		lock.Close()
		return nil, errors.New("the Runtime service is running; stop it with atlas-runtime service stop, then rebind")
	}
	if !errors.Is(err, syscall.ECONNREFUSED) {
		lock.Close()
		return nil, fmt.Errorf("cannot establish that the Runtime service is stopped (%v); nothing was changed", reason(err))
	}
	return lock, nil
}

// oldManifest is a manifest from before revision handles. Only Rebind reads one.
type oldManifest struct {
	Entries      []entry `json:"entries"`
	Repositories []struct {
		Commit     string `json:"commit"`
		Path       string `json:"path"`
		Repository string `json:"repository"`
	} `json:"repositories"`
}

func (m *oldManifest) canonical() []byte {
	var b bytes.Buffer
	writeEntries(&b, m.Entries)
	b.WriteString(`,"repositories":[`)
	for i, r := range m.Repositories {
		if i > 0 {
			b.WriteByte(',')
		}
		field(&b, `{"commit":`, r.Commit)
		field(&b, `,"path":`, r.Path)
		field(&b, `,"repository":`, r.Repository)
		b.WriteByte('}')
	}
	b.WriteString(`]}`)
	return b.Bytes()
}

// loadOld verifies an older baseline's marker and identity and returns its manifest.
func loadOld(baseline, id string) (*oldManifest, error) {
	marker, err := os.ReadFile(filepath.Join(baseline, "complete"))
	if err != nil || string(marker) != id+"\n" {
		return nil, fmt.Errorf("baseline %s for %s is missing or incomplete", baseline, id)
	}
	raw, err := os.ReadFile(filepath.Join(baseline, "manifest.json"))
	if err != nil {
		return nil, fmt.Errorf("cannot read baseline manifest: %v", err)
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	var m oldManifest
	if err = decoder.Decode(&m); err != nil {
		return nil, fmt.Errorf("baseline manifest %s is neither version 2 nor from before revision handles: %v", baseline, err)
	}
	if sum := sha256.Sum256(raw); "sha256:"+hex.EncodeToString(sum[:]) != id || !bytes.Equal(m.canonical(), raw) {
		return nil, fmt.Errorf("baseline manifest %s is not the canonical manifest of %s", filepath.Join(baseline, "manifest.json"), id)
	}
	return &m, nil
}

// successor asks Code which snapshot replaces id: Code refuses id itself with snapshot_superseded.
func (c *code) successor(id string) (string, error) {
	request, err := http.NewRequest(http.MethodGet, c.url+"/v1/snapshots/"+id+"/manifest", nil)
	if err != nil {
		return "", unavailable("%v", err)
	}
	request.Header.Set("Authorization", "Bearer "+c.token)
	response, err := c.client.Do(request)
	if err != nil {
		return "", unavailable("%v", err)
	}
	defer response.Body.Close()
	var reply struct {
		Error struct {
			Code    string `json:"code"`
			Message string `json:"message"`
			Details struct {
				Successor *string `json:"successor"`
			} `json:"details"`
		} `json:"error"`
	}
	decoded := json.NewDecoder(io.LimitReader(response.Body, 1<<20)).Decode(&reply) == nil
	switch {
	case response.StatusCode == http.StatusOK:
		return "", fmt.Errorf("Code still serves %s as it was; it has not been migrated to revision handles", id)
	case response.StatusCode == http.StatusConflict && decoded && reply.Error.Code == "snapshot_superseded" &&
		reply.Error.Details.Successor != nil && snapshotID.MatchString(*reply.Error.Details.Successor):
		return *reply.Error.Details.Successor, nil
	case decoded && reply.Error.Code != "":
		return "", fmt.Errorf("Code refused snapshot %s: %d %s: %s", id, response.StatusCode, reply.Error.Code, reply.Error.Message)
	}
	return "", unavailable("HTTP %d", response.StatusCode)
}

// journal is a rebind's plan and progress. Phases: baseline, backups, files, record, done.
type journal struct {
	Destination string `json:"destination"`
	Record      string `json:"record"`
	From        side   `json:"from"`
	To          side   `json:"to"`
	// Repositories are the successor's, with its revisions.
	Repositories []repository   `json:"repositories"`
	OldScope     map[string]any `json:"old_scope"`
	NewScope     map[string]any `json:"new_scope"`
	Files        []string       `json:"files"`
	NotBound     []string       `json:"not_bound"`
	ReboundAt    string         `json:"rebound_at"`
	Phase        string         `json:"phase"`
}

type side struct {
	SnapshotID string `json:"snapshot_id"`
	Baseline   string `json:"baseline"`
}

var turnID = regexp.MustCompile(`^turn-[0-9a-f]+$`)

// plan checks everything a rebind needs before any change and records it; nil means dest
// already uses revision handles.
func plan(home, dest, dir string) (*journal, error) {
	id, err := recorded(home, dest)
	if err != nil {
		return nil, err
	}
	oldBaseline := filepath.Join(home, "snapshots", id[len("sha256:"):])
	if _, _, err = loadBaseline(oldBaseline, id); err == nil {
		return nil, nil
	} else if !errors.Is(err, errPredates) {
		return nil, err
	}
	old, err := loadOld(oldBaseline, id)
	if err != nil {
		return nil, err
	}
	code, err := connect(home)
	if err != nil {
		return nil, err
	}
	next, err := code.successor(id)
	if err != nil {
		return nil, err
	}
	m, err := code.manifest(next)
	if err != nil {
		return nil, err
	}
	if _, err = m.check(next, m.canonical()); err != nil {
		return nil, err
	}
	var before, after bytes.Buffer
	writeEntries(&before, old.Entries)
	writeEntries(&after, m.Entries)
	same := bytes.Equal(before.Bytes(), after.Bytes()) && len(old.Repositories) == len(m.Repositories)
	for i := 0; same && i < len(m.Repositories); i++ {
		same = old.Repositories[i].Path == m.Repositories[i].Path && old.Repositories[i].Repository == m.Repositories[i].Repository
	}
	if !same {
		return nil, fmt.Errorf("Code's successor %s of %s differs in its entries or repositories; nothing was changed", next, id)
	}

	paths := []any{}
	for _, r := range m.Repositories {
		paths = append(paths, r.Path)
	}
	scope := func(snapshot, baseline string) map[string]any {
		return map[string]any{"baseline": baseline, "home": home, "profile": "materialized-folder", "record": recordPath(home, dest),
			"repositories": paths, "root": dest, "snapshot_id": snapshot, "version": json.Number("1")}
	}
	j := &journal{Destination: dest, Record: recordPath(home, dest), From: side{id, oldBaseline},
		To: side{next, filepath.Join(home, "snapshots", next[len("sha256:"):])}, Repositories: m.Repositories, Files: []string{}, NotBound: []string{},
		ReboundAt: time.Now().UTC().Format(time.RFC3339), Phase: "baseline"}
	j.OldScope, j.NewScope = scope(id, oldBaseline), scope(next, j.To.Baseline)
	// Round-trip both scopes, so they compare like scopes read back from disk.
	if err = roundTrip(&j.OldScope); err != nil {
		return nil, err
	}
	if err = roundTrip(&j.NewScope); err != nil {
		return nil, err
	}

	turns, err := os.ReadDir(filepath.Join(home, "turns"))
	if err != nil && !errors.Is(err, fs.ErrNotExist) {
		return nil, err
	}
	for _, t := range turns {
		if !t.IsDir() || !turnID.MatchString(t.Name()) {
			continue
		}
		for _, name := range []string{"turn.json", "claude-context.json"} {
			rel := filepath.Join("turns", t.Name(), name)
			data, err := os.ReadFile(filepath.Join(home, rel))
			if errors.Is(err, fs.ErrNotExist) {
				continue
			} else if err != nil {
				return nil, fmt.Errorf("cannot read %s: %v", rel, reason(err))
			}
			start, end, err := locate(data, "permissions")
			if errors.Is(err, errAbsent) {
				continue
			} else if err != nil {
				return nil, fmt.Errorf("%s: %v; nothing was changed", rel, err)
			}
			var permissions any
			if err = decode(data[start:end], &permissions); err != nil {
				return nil, fmt.Errorf("%s: %v; nothing was changed", rel, err)
			}
			fields, _ := permissions.(map[string]any)
			switch {
			case reflect.DeepEqual(permissions, any(j.OldScope)):
				j.Files = append(j.Files, rel)
			case fields["profile"] == "materialized-folder" && fields["root"] == dest:
				j.NotBound = append(j.NotBound, rel)
			}
		}
	}
	if err = os.MkdirAll(dir, 0700); err != nil {
		return nil, err
	}
	data, err := json.Marshal(j)
	if err != nil {
		return nil, err
	}
	// The journal is created once; a concurrent plan of the same folder cannot replace it.
	temporary := filepath.Join(dir, fmt.Sprintf(".journal-%d.tmp", os.Getpid()))
	if err = os.WriteFile(temporary, data, 0600); err != nil {
		return nil, err
	}
	defer os.Remove(temporary)
	if err = os.Link(temporary, filepath.Join(dir, "journal.json")); err != nil {
		return nil, fmt.Errorf("cannot record the rebind of %s: %v", dest, err)
	}
	return j, nil
}

func loadJournal(dir string) (*journal, error) {
	data, err := os.ReadFile(filepath.Join(dir, "journal.json"))
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	} else if err != nil {
		return nil, err
	}
	var j journal
	if err = decode(data, &j); err != nil || j.Destination == "" || j.Phase == "" {
		return nil, fmt.Errorf("rebind journal %s is invalid; nothing was changed", filepath.Join(dir, "journal.json"))
	}
	return &j, nil
}

func (j *journal) save(dir, phase string) error {
	j.Phase = phase
	data, err := json.Marshal(j)
	if err != nil {
		return err
	}
	return replace(filepath.Join(dir, "journal.json"), data, 0600)
}

// step performs the current phase and records the next one.
func (j *journal) step(home, dir string) error {
	switch j.Phase {
	case "baseline":
		if err := j.copyBaseline(); err != nil {
			return err
		}
		return j.save(dir, "backups")
	case "backups":
		for _, rel := range append([]string{j.recordRel(home)}, j.Files...) {
			backup := filepath.Join(dir, "backup", rel)
			current, err := os.ReadFile(filepath.Join(home, rel))
			if err != nil {
				return err
			}
			if saved, err := os.ReadFile(backup); err == nil {
				if !j.original(rel, saved) {
					return fmt.Errorf("backup %s is not an original", backup)
				}
				continue
			} else if !errors.Is(err, fs.ErrNotExist) {
				return err
			}
			if !j.original(rel, current) {
				return fmt.Errorf("%s changed since the rebind was planned", rel)
			}
			if err = os.MkdirAll(filepath.Dir(backup), 0700); err != nil {
				return err
			}
			if err = replace(backup, current, 0600); err != nil {
				return err
			}
		}
		return j.save(dir, "files")
	case "files", "record":
		rels := j.Files
		if j.Phase == "record" {
			rels = []string{j.recordRel(home)}
		}
		for _, rel := range rels {
			if err := rebindStep(j.Phase + " " + rel); err != nil {
				return err
			}
			if err := j.swap(home, dir, rel); err != nil {
				return err
			}
		}
		return j.save(dir, map[string]string{"files": "record", "record": "verify"}[j.Phase])
	case "verify":
		return j.verify(home, dir)
	}
	return fmt.Errorf("unknown phase %q", j.Phase)
}

func (j *journal) recordRel(home string) string {
	return filepath.Join("materializations", filepath.Base(j.Record))
}

func (j *journal) isRecord(rel string) bool {
	return rel == filepath.Join("materializations", filepath.Base(j.Record))
}

// original reports whether data is the file at rel as it was before the rebind.
func (j *journal) original(rel string, data []byte) bool {
	if j.isRecord(rel) {
		var r map[string]any
		return decode(data, &r) == nil && r["destination"] == j.Destination && r["snapshot_id"] == j.From.SnapshotID
	}
	start, end, err := locate(data, "permissions")
	var permissions any
	return err == nil && decode(data[start:end], &permissions) == nil && reflect.DeepEqual(permissions, any(j.OldScope))
}

// rewritten is the file at rel with the rebind applied to its backed-up original bytes.
func (j *journal) rewritten(rel string, original []byte) ([]byte, error) {
	if !j.original(rel, original) {
		return nil, fmt.Errorf("backup of %s is not an original", rel)
	}
	if j.isRecord(rel) {
		var r map[string]any
		if err := decode(original, &r); err != nil {
			return nil, err
		}
		return marshal(map[string]any{"destination": j.Destination, "snapshot_id": j.To.SnapshotID, "materialized_at": r["materialized_at"],
			"rebound_from": j.From.SnapshotID, "rebound_at": j.ReboundAt})
	}
	start, end, err := locate(original, "permissions")
	if err != nil {
		return nil, err
	}
	scope, err := marshal(j.NewScope)
	if err != nil {
		return nil, err
	}
	return append(append(append([]byte{}, original[:start]...), scope...), original[end:]...), nil
}

// swap replaces rel with its rewritten bytes unless it already holds them; any third content
// is drift and refuses.
func (j *journal) swap(home, dir, rel string) error {
	path := filepath.Join(home, rel)
	backup, err := os.ReadFile(filepath.Join(dir, "backup", rel))
	if err != nil {
		return fmt.Errorf("backup of %s is missing: %v", rel, reason(err))
	}
	want, err := j.rewritten(rel, backup)
	if err != nil {
		return err
	}
	current, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	switch {
	case bytes.Equal(current, want):
		return nil
	case !bytes.Equal(current, backup):
		return fmt.Errorf("%s changed since its backup", rel)
	}
	info, err := os.Stat(path)
	if err != nil {
		return err
	}
	if err = replace(path, want, info.Mode().Perm()); err != nil {
		return err
	}
	if after, err := os.ReadFile(path); err != nil || !bytes.Equal(after, want) {
		return fmt.Errorf("%s does not hold its rewritten bytes", rel)
	}
	return nil
}

// verify reopens the folder as status would and checks every rewritten file.
func (j *journal) verify(home, dir string) error {
	f, err := openRecorded(home, j.Destination)
	if err != nil {
		return err
	}
	if f.id != j.To.SnapshotID || f.baseline != j.To.Baseline {
		return fmt.Errorf("the record of %s does not name %s", j.Destination, j.To.SnapshotID)
	}
	for _, rel := range j.Files {
		data, err := os.ReadFile(filepath.Join(home, rel))
		if err != nil {
			return err
		}
		start, end, err := locate(data, "permissions")
		var permissions any
		if err != nil || decode(data[start:end], &permissions) != nil || !reflect.DeepEqual(permissions, any(j.NewScope)) {
			return fmt.Errorf("%s does not hold the new scope", rel)
		}
	}
	return j.save(dir, "done")
}

// copyBaseline publishes the successor's baseline from the old one, re-hashing every file.
func (j *journal) copyBaseline() error {
	reuse, err := complete(j.To.Baseline)
	if err != nil || reuse {
		return err
	}
	raw, err := os.ReadFile(filepath.Join(j.From.Baseline, "manifest.json"))
	if err != nil {
		return err
	}
	var old oldManifest
	if err = decode(raw, &old); err != nil {
		return err
	}
	// The successor's manifest is rebuilt from the old entries and must hash to its ID.
	m := &manifest{Entries: old.Entries, Repositories: j.Repositories, SnapshotID: j.To.SnapshotID, Version: 2}
	canonical := m.canonical()
	entries, err := m.check(j.To.SnapshotID, canonical)
	if err != nil {
		return err
	}
	building, err := os.MkdirTemp(filepath.Dir(j.To.Baseline), ".staging-*")
	if err != nil {
		return err
	}
	defer func() {
		if building != "" {
			remove(building)
		}
	}()
	t, err := newTree(filepath.Join(building, "tree"), true)
	if err != nil {
		return err
	}
	for _, r := range m.Repositories {
		if err = t.mkdirs(r.Path); err != nil {
			return err
		}
	}
	for _, e := range entries {
		source := filepath.Join(j.From.Baseline, "tree", filepath.FromSlash(e.Path))
		if e.Kind == "symlink" {
			if target, err := os.Readlink(source); err != nil || target != *e.Target {
				return fmt.Errorf("old baseline symlink %s is missing or differs", source)
			}
			err = t.symlink(e.Path, *e.Target)
		} else {
			err = copyFile(source, e, t)
		}
		if err != nil {
			return err
		}
	}
	if err = t.finish(); err != nil {
		return err
	}
	if err = readOnly(filepath.Join(building, "manifest.json"), canonical); err != nil {
		return err
	}
	if err = readOnly(filepath.Join(building, "complete"), []byte(j.To.SnapshotID+"\n")); err != nil {
		return err
	}
	if err = os.Chmod(building, 0555); err != nil {
		return err
	}
	if err = renameExclusive(building, j.To.Baseline); err == nil {
		building = ""
	} else if ok, cerr := complete(j.To.Baseline); !errors.Is(err, fs.ErrExist) || !ok {
		return errors.Join(err, cerr)
	}
	return nil
}

func copyFile(source string, e *entry, t *tree) error {
	file, err := os.OpenFile(source, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return fmt.Errorf("old baseline file %s: %v", source, reason(err))
	}
	defer file.Close()
	mode := os.FileMode(0644)
	if e.Mode == "100755" {
		mode = 0755
	}
	return write(file, e, mode, []*tree{t})
}

// result is what a finished rebind reports, on every repeat alike.
func (j *journal) result(dir string) map[string]any {
	return map[string]any{"state": "rebound", "destination": j.Destination, "snapshot_id": j.To.SnapshotID, "rebound_from": j.From.SnapshotID,
		"baseline": j.To.Baseline, "files": j.Files, "not_bound": j.NotBound, "journal": filepath.Join(dir, "journal.json")}
}

var errAbsent = errors.New("absent")

// locate returns where the value of the top-level key starts and ends in the JSON object data.
func locate(data []byte, key string) (int, int, error) {
	d := json.NewDecoder(bytes.NewReader(data))
	if token, err := d.Token(); err != nil || token != json.Delim('{') {
		return 0, 0, errors.New("not a JSON object")
	}
	start, end := -1, -1
	for d.More() {
		token, err := d.Token()
		if err != nil {
			return 0, 0, err
		}
		var raw json.RawMessage
		if err = d.Decode(&raw); err != nil {
			return 0, 0, err
		}
		if token == key {
			if start >= 0 {
				return 0, 0, fmt.Errorf("duplicate key %q", key)
			}
			end = int(d.InputOffset())
			start = end - len(raw)
		}
	}
	if _, err := d.Token(); err != nil {
		return 0, 0, err
	}
	if _, err := d.Token(); err != io.EOF {
		return 0, 0, errors.New("trailing data after the JSON object")
	}
	if start < 0 {
		return 0, 0, errAbsent
	}
	return start, end, nil
}

// decode reads one JSON value with exact numbers.
func decode(data []byte, v any) error {
	d := json.NewDecoder(bytes.NewReader(data))
	d.UseNumber()
	return d.Decode(v)
}

// marshal encodes compactly with sorted keys and without HTML escapes.
func marshal(v any) ([]byte, error) {
	var b bytes.Buffer
	e := json.NewEncoder(&b)
	e.SetEscapeHTML(false)
	if err := e.Encode(v); err != nil {
		return nil, err
	}
	return bytes.TrimSuffix(b.Bytes(), []byte("\n")), nil
}

func roundTrip(scope *map[string]any) error {
	data, err := marshal(*scope)
	if err != nil {
		return err
	}
	return decode(data, scope)
}

// replace writes data to path atomically, through a temporary file next to it.
func replace(path string, data []byte, perm os.FileMode) error {
	file, err := os.CreateTemp(filepath.Dir(path), ".rebind-*")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	_, err = file.Write(data)
	if cerr := file.Chmod(perm); err == nil {
		err = cerr
	}
	if cerr := file.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		return err
	}
	return os.Rename(file.Name(), path)
}
