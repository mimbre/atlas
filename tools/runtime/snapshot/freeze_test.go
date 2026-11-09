package snapshot

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"strings"
	"syscall"
	"testing"
)

const (
	packetA = "5c0ffee0-0000-4000-8000-00000000000a"
	packetB = "5c0ffee0-0000-4000-8000-00000000000b"
)

// authorTurn saves a turn record as Runtime does for a turn that ran in cwd, and returns its ID.
func authorTurn(t *testing.T, home, cwd, state string) string {
	t.Helper()
	id := fmt.Sprintf("turn-%016x", sha256.Sum256([]byte(cwd+state)))[:21]
	run := map[string]any{"id": id, "worker_id": "author", "backend": "codex", "model": "model-x", "requested_model": nil,
		"selection": map[string]any{"reason": "explicit"}, "state": state, "cwd": cwd, "assignment": "work", "source_turn_id": "turn-00000000000000aa"}
	body, _ := json.Marshal(run)
	must(t, os.MkdirAll(filepath.Join(home, "turns", id), 0700))
	must(t, os.WriteFile(filepath.Join(home, "turns", id, "turn.json"), body, 0600))
	return id
}

// packetFolder is a new packet path next to the author folder, removed after the test.
func packetFolder(t *testing.T, parent, name string) string {
	t.Helper()
	path := filepath.Join(parent, name)
	t.Cleanup(func() { remove(path) })
	return path
}

// authorFolder materializes repositories one and two and changes one in every way a packet carries.
func authorFolder(t *testing.T) (*fixture, *fakeCode, string, string) {
	t.Helper()
	f, code, id, dest := submitFixture(t, true, memberA, memberRun, memberL, reg("gone.txt", 0644, "gone\n"))
	at := func(path string) string { return filepath.Join(dest, "one", path) }
	must(t, os.WriteFile(at("a.txt"), []byte("alpha\nbeta\n"), 0644))
	must(t, os.WriteFile(at("data.bin"), []byte("\x00\xff"), 0644))
	must(t, os.Remove(at("gone.txt")))
	must(t, os.Chmod(at("bin/run"), 0644))
	must(t, os.Remove(at("link")))
	must(t, os.Symlink("data.bin", at("link")))
	must(t, os.MkdirAll(at("empty"), 0755))
	must(t, os.WriteFile(filepath.Join(dest, "notes.md"), []byte("outside\n"), 0644))
	return f, code, id, dest
}

func readPacket(t *testing.T, path string) map[string]any {
	t.Helper()
	p, err := decodePacket(mustRead(t, path))
	must(t, err)
	return p
}

// leftNothing asserts a refused freeze left no packet folder, staging, records or packet.
func leftNothing(t *testing.T, home, path, id string) {
	t.Helper()
	if _, err := os.Lstat(path); !errors.Is(err, fs.ErrNotExist) {
		t.Errorf("packet folder %s exists: %v", path, err)
	}
	if left, _ := filepath.Glob(filepath.Join(filepath.Dir(path), ".atlas-packet-*")); len(left) != 0 {
		t.Errorf("staging left: %v", left)
	}
	tree := filepath.Join(path, "tree")
	for _, name := range []string{recordPath(home, tree), preparationDir(home, tree), PacketDir(home, id)} {
		if _, err := os.Lstat(name); !errors.Is(err, fs.ErrNotExist) {
			t.Errorf("%s exists: %v", name, err)
		}
	}
}

func TestFreezeMakesARecordedReadOnlyPacketWithSubmitsFingerprints(t *testing.T) {
	f, code, id, dest := authorFolder(t)
	turn := authorTurn(t, f.home, dest, "finished")
	path := packetFolder(t, f.parent, "packet")
	baseline := filepath.Join(f.home, "snapshots", strings.TrimPrefix(id, "sha256:"))
	before, base := state(t, dest), state(t, baseline)

	result, err := Freeze(f.home, dest, turn, path, packetA, "")
	must(t, err)
	equal(t, state(t, dest), before)
	equal(t, state(t, baseline), base)
	if !contend(t, dest) {
		t.Fatal("freeze kept the folder lock")
	}
	tree := filepath.Join(path, "tree")

	// The tree is a recorded materialization of the same snapshot whose status and diff are the folder's.
	for _, diffs := range []bool{false, true} {
		got, _ := inspect(t, f.home, tree, nil, diffs)
		want, _ := inspect(t, f.home, dest, nil, diffs)
		if got["snapshot_id"] != id || got["destination"] != tree || !reflect.DeepEqual(got["changes"], want["changes"]) {
			t.Fatalf("diffs %v: tree %v, folder %v", diffs, got, want)
		}
	}
	var record map[string]string
	must(t, json.Unmarshal(mustRead(t, recordPath(f.home, tree)), &record))
	if record["destination"] != tree || record["snapshot_id"] != id || record["packet_id"] != packetA {
		t.Fatalf("tree record %v", record)
	}

	// Each repository fingerprint is what submit reports, from the folder and from the tree.
	p := readPacket(t, filepath.Join(path, "packet.json"))
	repositories := p["repositories"].([]any)
	fingerprints := map[string]string{}
	for _, r := range repositories {
		r := r.(map[string]any)
		fingerprints[r["path"].(string)] = r["fingerprint"].(string)
	}
	for _, source := range []string{dest, tree} {
		for _, repo := range []string{"one", "two"} {
			submitted, err := Submit(f.home, source, repo, changeA, "")
			must(t, err)
			if submitted["fingerprint"] != fingerprints[repo] {
				t.Fatalf("submit of %s in %s: %v, packet %s", repo, source, submitted["fingerprint"], fingerprints[repo])
			}
		}
	}
	if approve(t, code.bodies[changeA]) != fingerprints["one"] {
		t.Fatal("Code's request.json does not hash to the packet's fingerprint")
	}
	canonical := fmt.Sprintf(`{"repositories":[{"fingerprint":"%s","path":"one","repository":"github.com/test/one"},{"fingerprint":"%s","path":"two","repository":"github.com/test/two"}],"snapshot_id":"%s","version":1}`,
		fingerprints["one"], fingerprints["two"], id)
	sum := sha256.Sum256([]byte(canonical))
	if p["fingerprint"] != "fpr_"+hex.EncodeToString(sum[:]) || result["fingerprint"] != p["fingerprint"] {
		t.Fatalf("packet fingerprint %v, want the hash of %s", p["fingerprint"], canonical)
	}
	alpha, beta := repositories[0].(map[string]any), repositories[1].(map[string]any)
	if alpha["state"] != "changed" || beta["state"] != "clean" || !reflect.DeepEqual(beta["entries"], []any{}) || alpha["base_revision"] != one.Revision {
		t.Fatalf("repositories %v", repositories)
	}
	if !reflect.DeepEqual(alpha["entries"], jsonValue(t, []map[string]any{written("a.txt", "100644", "alpha\nbeta\n"), written("bin/run", "100644", "#!"),
		written("data.bin", "100644", "\x00\xff"), deleted("gone.txt"), linked("link", "data.bin")})) {
		t.Fatalf("entries %v", alpha["entries"])
	}

	// Metadata: the author turn, no previous packet, what is outside and what has no text diff.
	author := map[string]any{"dest": dest, "turn_id": turn, "source_turn_id": "turn-00000000000000aa", "worker_id": "author", "backend": "codex", "model": "model-x", "state": "finished"}
	if p["version"] != 1.0 || p["packet_id"] != packetA || p["previous"] != nil || p["snapshot_id"] != id || !reflect.DeepEqual(p["author"], author) ||
		p["tree"] != tree || p["findings"] != filepath.Join(path, "findings") || p["preparation"] != nil ||
		!reflect.DeepEqual(p["outside"], []any{"notes.md"}) || !reflect.DeepEqual(p["incomplete_diffs"], []any{map[string]any{"path": "one/data.bin", "reason": "binary"}}) {
		t.Fatalf("packet %v", p)
	}
	diff := mustRead(t, filepath.Join(path, "diff.json"))
	report, _ := inspect(t, f.home, tree, nil, true)
	if !reflect.DeepEqual(jsonValue(t, report), jsonValue(t, json.RawMessage(diff))) {
		t.Fatalf("diff.json %s is not snapshot diff of the tree %v", diff, report)
	}
	for name, data := range map[string][]byte{"packet.json": mustRead(t, filepath.Join(path, "packet.json")), "diff.json": diff} {
		if kept := mustRead(t, filepath.Join(PacketDir(f.home, packetA), name)); string(kept) != string(data) {
			t.Errorf("authoritative %s differs from the packet's", name)
		}
	}
	delete(result, "cost")
	delete(result, "state")
	delete(result, "packet")
	if !reflect.DeepEqual(result, p) {
		t.Fatalf("result %v is not packet.json %v", result, p)
	}

	// Read-only: the tree, packet.json and diff.json; only findings is writable.
	modes := map[string]string{}
	for rel, description := range describe(t, path) {
		modes[rel] = strings.SplitN(description, " ", 3)[0] + " " + strings.SplitN(description, " ", 3)[1]
	}
	equal(t, modes, map[string]string{".": "dir 555", "findings": "dir 700", "packet.json": "file 444", "diff.json": "file 444",
		"tree": "dir 555", "tree/notes.md": "file 444", "tree/one": "dir 555", "tree/one/a.txt": "file 444", "tree/one/bin": "dir 555", "tree/one/bin/run": "file 444",
		"tree/one/data.bin": "file 444", "tree/one/empty": "dir 555", "tree/one/link": "link data.bin", "tree/two": "dir 555", "tree/two/b.txt": "file 444"})
	if err = os.WriteFile(filepath.Join(tree, "one", "a.txt"), []byte("x"), 0644); !errors.Is(err, fs.ErrPermission) {
		t.Fatalf("writing a tree file: %v", err)
	}
	if err = os.WriteFile(filepath.Join(tree, "one", "new.txt"), []byte("x"), 0644); !errors.Is(err, fs.ErrPermission) {
		t.Fatalf("adding a tree file: %v", err)
	}
	if entries, _ := os.ReadDir(filepath.Join(path, "findings")); len(entries) != 0 {
		t.Fatalf("findings is not empty: %v", entries)
	}
}

func jsonValue(t *testing.T, v any) any {
	t.Helper()
	data, err := json.Marshal(v)
	must(t, err)
	var out any
	must(t, json.Unmarshal(data, &out))
	return out
}

func TestFreezeReportsItsCostAndRepeatsByID(t *testing.T) {
	f, _, _, dest := authorFolder(t)
	turn := authorTurn(t, f.home, dest, "stopped")
	path := packetFolder(t, f.parent, "packet")
	result, err := Freeze(f.home, dest, turn, path, packetA, "")
	must(t, err)
	cost := result["cost"].(map[string]any)
	// notes.md, a.txt, bin/run, data.bin and b.txt; the link and the empty directory are not files.
	if result["state"] != "frozen" || result["packet"] != path || cost["files"] != int64(5) || cost["bytes"] != int64(len("outside\nalpha\nbeta\n#!\x00\xffbeta")) ||
		cost["cloned_files"].(int64)+cost["copied_files"].(int64) != 5 || cost["elapsed_ms"].(int64) < 0 {
		t.Fatalf("result %v", result)
	}
	for _, key := range []string{"free_bytes_before", "free_bytes_after", "disk_used_bytes"} {
		if _, ok := cost[key].(int64); !ok {
			t.Fatalf("cost has no %s: %v", key, cost)
		}
	}
	if runtime.GOOS == "darwin" && (cost["cloned_files"] != int64(5) || cost["copied_bytes"] != int64(0)) {
		t.Fatalf("APFS freeze did not clone every file: %v", cost)
	}

	// A repeat returns the recorded packet without scanning, even while the folder is owned or changed.
	must(t, os.WriteFile(filepath.Join(dest, "one", "a.txt"), []byte("later\n"), 0644))
	owner, err := os.Open(dest)
	must(t, err)
	defer owner.Close()
	must(t, syscall.Flock(int(owner.Fd()), syscall.LOCK_EX|syscall.LOCK_NB))
	again, err := Freeze(f.home, dest, turn, path, packetA, "")
	must(t, err)
	p := readPacket(t, filepath.Join(path, "packet.json"))
	if again["state"] != "existing" || again["packet"] != path || again["cost"] != nil {
		t.Fatalf("repeat %v", again)
	}
	delete(again, "state")
	delete(again, "packet")
	if !reflect.DeepEqual(again, p) {
		t.Fatalf("repeat %v, packet %v", again, p)
	}
	// Any other use of the ID is a conflict, and nothing new is made.
	other := authorTurn(t, f.home, dest, "finished")
	for name, args := range map[string][]string{"turn": {other, path, ""}, "packet": {turn, filepath.Join(f.parent, "elsewhere"), ""}, "previous": {turn, path, packetB}} {
		if _, err := Freeze(f.home, dest, args[0], args[1], packetA, args[2]); err == nil || !strings.Contains(err.Error(), "packet ID "+packetA+" was already used") {
			t.Errorf("%s: %v", name, err)
		}
	}
	if _, err = os.Lstat(filepath.Join(f.parent, "elsewhere")); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("a conflicting freeze made a folder: %v", err)
	}
}

// The streamed copy, forced through the clone seam, makes the same tree.
func TestFreezeFallsBackToAStreamedCopy(t *testing.T) {
	f, _, _, dest := authorFolder(t)
	turn := authorTurn(t, f.home, dest, "killed")
	clones := 0
	cloneFile = func(from, to string) error {
		clones++
		return &os.LinkError{Op: "clonefile", Old: from, New: to, Err: syscall.ENOTSUP}
	}
	t.Cleanup(func() { cloneFile = clone })
	path := packetFolder(t, f.parent, "packet")
	result, err := Freeze(f.home, dest, turn, path, packetA, "")
	must(t, err)
	cost := result["cost"].(map[string]any)
	if clones != 5 || cost["cloned_files"] != int64(0) || cost["copied_files"] != int64(5) || cost["copied_bytes"] != cost["bytes"] {
		t.Fatalf("%d clone attempts, cost %v", clones, cost)
	}
	got, _ := inspect(t, f.home, filepath.Join(path, "tree"), nil, true)
	want, _ := inspect(t, f.home, dest, nil, true)
	if !reflect.DeepEqual(got["changes"], want["changes"]) {
		t.Fatalf("copied tree %v, folder %v", got["changes"], want["changes"])
	}
	tree := describe(t, filepath.Join(path, "tree"))
	if tree["one/a.txt"] != fmt.Sprintf("file 444 %q", "alpha\nbeta\n") || tree["two/b.txt"] != `file 444 "beta"` {
		t.Fatalf("tree %v", tree)
	}

	// Any other clone failure refuses and removes everything it made.
	cloneFile = func(from, to string) error {
		return &os.LinkError{Op: "clonefile", Old: from, New: to, Err: syscall.EIO}
	}
	path = packetFolder(t, f.parent, "second")
	if _, err = Freeze(f.home, dest, turn, path, packetB, ""); !errors.Is(err, syscall.EIO) {
		t.Fatalf("got %v", err)
	}
	leftNothing(t, f.home, path, packetB)
}

func TestFreezeRecordsThePreviousPacket(t *testing.T) {
	f, _, _, dest := authorFolder(t)
	turn := authorTurn(t, f.home, dest, "finished")
	first, err := Freeze(f.home, dest, turn, packetFolder(t, f.parent, "first"), packetA, "")
	must(t, err)

	missing := packetFolder(t, f.parent, "missing")
	if _, err = Freeze(f.home, dest, turn, missing, packetB, "5c0ffee0-0000-4000-8000-0000000000ff"); err == nil || !strings.Contains(err.Error(), "previous packet 5c0ffee0-0000-4000-8000-0000000000ff does not exist") {
		t.Fatalf("missing previous: %v", err)
	}
	leftNothing(t, f.home, missing, packetB)
	if _, err = Freeze(f.home, dest, turn, missing, packetB, packetB); err == nil || !strings.Contains(err.Error(), "cannot follow itself") {
		t.Fatalf("identical previous: %v", err)
	}
	leftNothing(t, f.home, missing, packetB)

	// Rework changes the folder; the next packet links the first by ID and fingerprint.
	must(t, os.WriteFile(filepath.Join(dest, "one", "a.txt"), []byte("reworked\n"), 0644))
	rework := authorTurn(t, f.home, dest, "stopped")
	second, err := Freeze(f.home, dest, rework, packetFolder(t, f.parent, "second"), packetB, packetA)
	must(t, err)
	link := map[string]any{"packet_id": packetA, "fingerprint": first["fingerprint"]}
	if !reflect.DeepEqual(second["previous"], link) || second["fingerprint"] == first["fingerprint"] {
		t.Fatalf("second %v, first fingerprint %v", second["previous"], first["fingerprint"])
	}
	if p := readPacket(t, filepath.Join(PacketDir(f.home, packetB), "packet.json")); !reflect.DeepEqual(p["previous"], link) {
		t.Fatalf("recorded previous %v", p["previous"])
	}
}

func TestFreezeRefusesBeforeMakingAPacket(t *testing.T) {
	refused := func(t *testing.T, home, dest, turn, path, want string) {
		t.Helper()
		if _, err := Freeze(home, dest, turn, path, packetA, ""); err == nil || !strings.Contains(err.Error(), want) {
			t.Fatalf("got %v, want %q", err, want)
		}
		leftNothing(t, home, path, packetA)
		if !contend(t, dest) {
			t.Fatal("a refused freeze kept the folder lock")
		}
	}
	t.Run("an active owner", func(t *testing.T) {
		f, _, _, dest := authorFolder(t)
		turn := authorTurn(t, f.home, dest, "finished")
		owner, err := os.Open(dest)
		must(t, err)
		must(t, syscall.Flock(int(owner.Fd()), syscall.LOCK_EX|syscall.LOCK_NB))
		path := packetFolder(t, f.parent, "packet")
		if _, err = Freeze(f.home, dest, turn, path, packetA, ""); err == nil || err.Error() != "folder "+dest+" has an active Runtime owner; nothing was frozen, run the command again after it stops" {
			t.Fatalf("got %v", err)
		}
		leftNothing(t, f.home, path, packetA)
		owner.Close()
	})
	t.Run("turns", func(t *testing.T) {
		f, _, _, dest := authorFolder(t)
		path := packetFolder(t, f.parent, "packet")
		elsewhere := t.TempDir()
		for want, turn := range map[string]string{
			"is running; only a finished, stopped or killed turn":   authorTurn(t, f.home, dest, "running"),
			"is failed; only a finished, stopped or killed turn":    authorTurn(t, f.home, dest, "failed"),
			"ran in \"" + elsewhere + "\", not in " + dest:          authorTurn(t, f.home, elsewhere, "finished"),
			"unknown turn turn-0123456789abcdef":                    "turn-0123456789abcdef",
			"turn must be turn-<16 lowercase hex characters>":       "turn-../../x",
			"ran in \"" + filepath.Join(dest, "one") + "\", not in": authorTurn(t, f.home, filepath.Join(dest, "one"), "finished"),
		} {
			refused(t, f.home, dest, turn, path, want)
		}
	})
	t.Run("packet paths", func(t *testing.T) {
		f, _, _, dest := authorFolder(t)
		turn := authorTurn(t, f.home, dest, "finished")
		existing := packetFolder(t, f.parent, "existing")
		must(t, os.Mkdir(existing, 0755))
		must(t, os.WriteFile(filepath.Join(existing, "keep"), []byte("kept\n"), 0644))
		if _, err := Freeze(f.home, dest, turn, existing, packetA, ""); err == nil || !strings.Contains(err.Error(), "already exists") {
			t.Fatalf("existing: %v", err)
		}
		if data := mustRead(t, filepath.Join(existing, "keep")); string(data) != "kept\n" {
			t.Fatal("an existing packet path was changed")
		}
		repository := filepath.Join(f.parent, "repository")
		must(t, os.MkdirAll(filepath.Join(repository, ".git"), 0755))
		home, err := filepath.EvalSymlinks(f.home)
		must(t, err)
		for want, path := range map[string]string{
			"overlaps the folder " + dest:       filepath.Join(dest, "one", "packet"),
			"overlaps the Runtime home " + home: filepath.Join(f.home, "packet"),
			"inside a Git work tree":            filepath.Join(repository, "packet"),
			"must be an existing directory":     filepath.Join(f.parent, "absent", "packet"),
		} {
			refused(t, f.home, dest, turn, path, want)
		}
		before := state(t, dest)
		for _, bad := range [][]string{{"not-a-uuid", ""}, {packetA, "not-a-uuid"}} {
			if _, err := Freeze(f.home, dest, turn, filepath.Join(f.parent, "packet"), bad[0], bad[1]); err == nil || !strings.Contains(err.Error(), "must be a lowercase UUID") {
				t.Errorf("%q: %v", bad, err)
			}
		}
		equal(t, state(t, dest), before)
	})
	t.Run("unsubmittable content", func(t *testing.T) {
		for want, change := range map[string]func(dest string) error{
			"cannot submit one/fifo: only files, symlinks and directories can be submitted": func(dest string) error { return syscall.Mkfifo(filepath.Join(dest, "one", "fifo"), 0644) },
			"cannot submit one/escape: symlink target \"../../x\" leaves the repository":    func(dest string) error { return os.Symlink("../../x", filepath.Join(dest, "one", "escape")) },
			"cannot freeze fifo: only files, symlinks and directories can be frozen":        func(dest string) error { return syscall.Mkfifo(filepath.Join(dest, "fifo"), 0644) },
			"cannot submit one/big.bin: is larger than Code's blob limit": func(dest string) error {
				return os.WriteFile(filepath.Join(dest, "one", "big.bin"), make([]byte, 65), 0644)
			},
		} {
			f, _, _, dest := authorFolder(t)
			blobLimit := maxBlob
			maxBlob = 64
			turn := authorTurn(t, f.home, dest, "finished")
			must(t, change(dest))
			refused(t, f.home, dest, turn, packetFolder(t, f.parent, "packet"), want)
			maxBlob = blobLimit
		}
	})
	t.Run("a change between the scans", func(t *testing.T) {
		f, _, _, dest := authorFolder(t)
		turn := authorTurn(t, f.home, dest, "finished")
		afterFolderScan = func() { must(t, os.WriteFile(filepath.Join(dest, "one", "a.txt"), []byte("edited meanwhile\n"), 0644)) }
		t.Cleanup(func() { afterFolderScan = func() {} })
		refused(t, f.home, dest, turn, packetFolder(t, f.parent, "packet"), "folder "+dest+" changed during freeze; nothing was frozen")
		// The same for a change outside every repository, which is not in any fingerprint.
		afterFolderScan = func() { must(t, os.WriteFile(filepath.Join(dest, "added.md"), []byte("new\n"), 0644)) }
		refused(t, f.home, dest, turn, packetFolder(t, f.parent, "packet"), "changed during freeze")
	})
	t.Run("an ID claimed by a concurrent freeze", func(t *testing.T) {
		f, _, _, dest := authorFolder(t)
		turn := authorTurn(t, f.home, dest, "finished")
		must(t, os.MkdirAll(PacketDir(f.home, packetA), 0700))
		path := packetFolder(t, f.parent, "packet")
		if _, err := Freeze(f.home, dest, turn, path, packetA, ""); err == nil || !strings.Contains(err.Error(), "used by a concurrent freeze") {
			t.Fatalf("got %v", err)
		}
		must(t, os.Remove(PacketDir(f.home, packetA)))
		leftNothing(t, f.home, path, packetA)
	})
}

// A prepared folder's packet tree carries the preparation, so the tree's status skips the same outputs.
func TestFreezeCopiesThePreparation(t *testing.T) {
	home, dest, id := localFolder(t, map[string]string{"app/package.json": "{}\n", "app/main.js": "run()\n"})
	t.Cleanup(func() { remove(filepath.Dir(home)) })
	prepared(t, home, dest, id)
	modules := filepath.Join(dest, "one", "app", "node_modules", "pkg")
	must(t, os.MkdirAll(modules, 0755))
	must(t, os.WriteFile(filepath.Join(modules, "index.js"), []byte("x\n"), 0644))
	must(t, os.WriteFile(filepath.Join(dest, "one", "app", "main.js"), []byte("run(2)\n"), 0644))
	turn := authorTurn(t, home, dest, "finished")
	path := packetFolder(t, filepath.Dir(dest), "packet")
	result, err := Freeze(home, dest, turn, path, packetA, "")
	must(t, err)
	tree := filepath.Join(path, "tree")
	got, changes := inspect(t, home, tree, nil, false)
	want, _ := inspect(t, home, dest, nil, false)
	if !reflect.DeepEqual(got["changes"], want["changes"]) || len(changes) != 1 || changes[0].Path != "one/app/main.js" || !reflect.DeepEqual(got["preparation"], want["preparation"]) {
		t.Fatalf("tree %v, folder %v", got, want)
	}
	if data := mustRead(t, filepath.Join(tree, "one", "app", "node_modules", "pkg", "index.js")); string(data) != "x\n" {
		t.Fatal("the preparation output was not copied")
	}
	if !reflect.DeepEqual(result["preparation"], jsonValue(t, want["preparation"])) {
		t.Fatalf("packet preparation %v", result["preparation"])
	}
	p, err := LoadPreparation(home, tree)
	must(t, err)
	if p == nil || p.Destination != tree || !p.Ready() {
		t.Fatalf("tree preparation %+v", p)
	}
}
