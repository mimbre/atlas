package snapshot

import (
	"encoding/json"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
)

// composeInput edits materializedFolder's folder, runs Changes on it and writes the change set
// file. It returns the fixture, snapshot, edited folder, change set file and blob folder.
func composeInput(t *testing.T) (*fixture, string, string, string, string) {
	t.Helper()
	f, id, dest := materializedFolder(t)
	editFolder(t, dest)
	offline(t, f.home)
	blobs := filepath.Join(t.TempDir(), "blobs")
	set := changeSetOf(t, f.home, dest, blobs)
	file := filepath.Join(t.TempDir(), "change-set.json")
	must(t, os.WriteFile(file, []byte(jsonString(t, map[string]any{"base": set["snapshot_id"], "roots": set["roots"]})), 0600))
	return f, id, dest, file, blobs
}

// noWriteBits asserts that nothing below root, root included, has a write bit.
func noWriteBits(t *testing.T, root string) {
	t.Helper()
	must(t, filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		info, err := os.Lstat(path)
		if err != nil {
			return err
		}
		if info.Mode()&fs.ModeSymlink == 0 && info.Mode().Perm()&0222 != 0 {
			t.Errorf("%s is %o", path, info.Mode().Perm())
		}
		if info.IsDir() && info.Mode().Perm() != 0555 {
			t.Errorf("directory %s is %o, not 555", path, info.Mode().Perm())
		}
		return nil
	}))
}

func TestComposeOfChangesRoundTrips(t *testing.T) {
	for _, readOnly := range []bool{false, true} {
		t.Run(map[bool]string{false: "writable", true: "read-only"}[readOnly], func(t *testing.T) {
			f, id, dest, file, blobs := composeInput(t)
			composed := filepath.Join(f.parent, "composed")
			t.Cleanup(func() { remove(composed) }) // a sealed folder
			result, err := Compose(f.home, id, file, blobs, composed, readOnly)
			if err != nil {
				t.Fatal(err)
			}
			if !jsonEqual(result, map[string]any{"snapshot_id": id, "destination": composed, "read_only": readOnly}) {
				t.Fatalf("result %v", result)
			}
			// The same content and modes as the edited folder, recorded on the same baseline, so
			// its change set is identical: a chain of composed folders stays relative to one base.
			if recordedID, err := recorded(f.home, composed); err != nil || recordedID != id {
				t.Fatalf("record %v %v", recordedID, err)
			}
			if again := changeSetOf(t, f.home, composed, filepath.Join(t.TempDir(), "blobs")); !jsonEqual(again, changeSetOf(t, f.home, dest, blobs)) {
				t.Fatalf("changes of the composed folder differ: %v", again)
			}
			want := describe(t, dest)
			if readOnly {
				noWriteBits(t, composed)
				for path, description := range want {
					description = strings.Replace(description, "file 644", "file 444", 1)
					description = strings.Replace(description, "file 755", "file 555", 1)
					want[path] = strings.Replace(description, "dir 755", "dir 555", 1)
				}
			}
			equal(t, describe(t, composed), want)
			if left, _ := os.ReadDir(f.parent); len(left) != 2 {
				t.Fatalf("staging left behind: %v", left)
			}
		})
	}
}

func TestComposeRefusesAWrongOrMissingBlob(t *testing.T) {
	for name, damage := range map[string]func(t *testing.T, blob string){
		"other bytes":  func(t *testing.T, blob string) { replaceFile(t, blob, "chanGed\n") },
		"longer blob":  func(t *testing.T, blob string) { replaceFile(t, blob, "changed\n!") },
		"missing blob": func(t *testing.T, blob string) { must(t, os.Remove(blob)) },
		// The link's target holds exactly the expected bytes, so only refusing the link itself,
		// never following it, makes this compose fail.
		"symlink blob": func(t *testing.T, blob string) {
			target := filepath.Join(t.TempDir(), "right-bytes")
			must(t, os.WriteFile(target, []byte("changed\n"), 0444))
			must(t, os.Remove(blob))
			must(t, os.Symlink(target, blob))
		},
		"directory blob": func(t *testing.T, blob string) {
			must(t, os.Remove(blob))
			must(t, os.Mkdir(blob, 0700))
		},
	} {
		// Every damage is refused both where the blob is cloned (macOS) and where it is streamed
		// (Linux, or a filesystem without clones): the streamed copy is forced here on every OS.
		for _, streamed := range []bool{false, true} {
			t.Run(name+map[bool]string{false: "", true: " streamed"}[streamed], func(t *testing.T) {
				if streamed {
					forceStreamedCopy(t)
				}
				f, id, _, file, blobs := composeInput(t)
				damage(t, filepath.Join(blobs, sum("changed\n")))
				composed := filepath.Join(f.parent, "composed")
				_, err := Compose(f.home, id, file, blobs, composed, false)
				failed(t, err, "blob_mismatch")
				refusedCompose(t, f, composed)
			})
		}
	}
	t.Run("size differs from the entry", func(t *testing.T) {
		f, id, _, file, blobs := composeInput(t)
		rewrite(t, file, `"size":8`, `"size":9`)
		composed := filepath.Join(f.parent, "composed")
		_, err := Compose(f.home, id, file, blobs, composed, false)
		failed(t, err, "blob_mismatch")
		refusedCompose(t, f, composed)
	})
}

// forceStreamedCopy makes every clone fail as on a filesystem without clones, as Linux always does.
func forceStreamedCopy(t *testing.T) {
	t.Helper()
	clone := cloneFile
	cloneFile = func(from, to string) error {
		return &os.LinkError{Op: "clonefile", Old: from, New: to, Err: syscall.ENOTSUP}
	}
	t.Cleanup(func() { cloneFile = clone })
}

func replaceFile(t *testing.T, path, data string) {
	t.Helper()
	must(t, os.Remove(path))
	must(t, os.WriteFile(path, []byte(data), 0444))
}

func rewrite(t *testing.T, path, old, replacement string) {
	t.Helper()
	data := string(mustRead(t, path))
	if !strings.Contains(data, old) {
		t.Fatalf("%s holds no %s: %s", path, old, data)
	}
	must(t, os.WriteFile(path, []byte(strings.Replace(data, old, replacement, 1)), 0600))
}

// refusedCompose asserts a refused compose left no destination, staging or record behind.
func refusedCompose(t *testing.T, f *fixture, composed string) {
	t.Helper()
	if _, err := os.Lstat(composed); err == nil {
		t.Fatalf("%s exists", composed)
	}
	if left, _ := os.ReadDir(filepath.Dir(composed)); len(left) > 1 {
		t.Fatalf("staging left behind: %v", left)
	}
	if _, err := os.Lstat(recordPath(f.home, composed)); err == nil {
		t.Fatal("refused folder was recorded")
	}
}

func TestComposeRefusesAnExistingDestinationOrMissingBaseline(t *testing.T) {
	f, id, dest, file, blobs := composeInput(t)
	before := state(t, dest)
	_, err := Compose(f.home, id, file, blobs, dest, false)
	failed(t, err, "destination_exists")
	equal(t, state(t, dest), before)

	other := "sha256:" + strings.Repeat("e", 64)
	rewrite(t, file, id, other)
	composed := filepath.Join(f.parent, "composed")
	_, err = Compose(f.home, other, file, blobs, composed, false)
	failed(t, err, "baseline_missing")
	_, err = Compose(f.home, "sha256:ABC", file, blobs, composed, false)
	failed(t, err, "baseline_missing")
	refusedCompose(t, f, composed)
}

func TestComposeRefusesAnInvalidChangeSet(t *testing.T) {
	f, id, _, file, blobs := composeInput(t)
	good := string(mustRead(t, file))
	write := func(path string) string {
		return `{"path":"` + path + `","op":"write","kind":"file","mode":"100644","size":8,"sha256":"` + sum("changed\n") + `"}`
	}
	set := func(entries ...string) string {
		return `{"base":"` + id + `","roots":[{"root":"one","entries":[` + strings.Join(entries, ",") + `]}]}`
	}
	for name, body := range map[string]string{
		"another base":           strings.Replace(good, id, "sha256:"+strings.Repeat("f", 64), 1),
		"unknown root":           `{"base":"` + id + `","roots":[{"root":"three","entries":[]}]}`,
		"nested root":            `{"base":"` + id + `","roots":[{"root":"one/bin","entries":[]}]}`,
		"duplicate root":         `{"base":"` + id + `","roots":[{"root":"one","entries":[]},{"root":"one","entries":[]}]}`,
		"unknown key":            `{"base":"` + id + `","roots":[],"extra":1}`,
		"not json":               `{"base":`,
		"two documents":          good + good,
		"delete with extra keys": set(`{"path":"a.txt","op":"delete","kind":"file"}`),
		"delete of nothing":      set(`{"path":"absent.txt","op":"delete"}`),
		"delete of a directory":  set(`{"path":"bin","op":"delete"}`),
		"unknown op":             set(`{"path":"a.txt","op":"move"}`),
		"file with target":       set(`{"path":"x","op":"write","kind":"file","mode":"100644","size":8,"sha256":"` + sum("changed\n") + `","target":"a.txt"}`),
		"symlink without target": set(`{"path":"x","op":"write","kind":"symlink","mode":"120000","size":5,"sha256":"` + sum("a.txt") + `"}`),
		"mode and kind differ":   set(`{"path":"x","op":"write","kind":"file","mode":"120000","size":8,"sha256":"` + sum("changed\n") + `"}`),
		"uppercase digest":       set(strings.Replace(write("x"), sum("changed\n"), strings.ToUpper(sum("changed\n")), 1)),
		"duplicate path":         set(write("x"), write("x")),
		"absolute path":          set(write("/x")),
		"traversal":              set(write("../two/b.txt")),
		"dot segment":            set(write("./x")),
		"git path":               set(write(".git/config")),
		"inside a file":          set(write("a.txt/x")),
		"escaping symlink":       set(`{"path":"x","op":"write","kind":"symlink","mode":"120000","size":15,"sha256":"` + sum("../two/b.txt/..") + `","target":"../two/b.txt/.."}`),
		"symlink digest":         set(`{"path":"x","op":"write","kind":"symlink","mode":"120000","size":5,"sha256":"` + sum("other") + `","target":"a.txt"}`),
		"fractional size":        set(strings.Replace(write("x"), `"size":8`, `"size":8.5`, 1)),
	} {
		t.Run(name, func(t *testing.T) {
			must(t, os.WriteFile(file, []byte(body), 0600))
			composed := filepath.Join(f.parent, "composed")
			_, err := Compose(f.home, id, file, blobs, composed, false)
			failed(t, err, "invalid_change_set")
			refusedCompose(t, f, composed)
		})
	}
	// The same shapes are accepted when they are valid: a write replacing a deleted file's path.
	must(t, os.WriteFile(file, []byte(set(`{"path":"a.txt","op":"delete"}`, write("a.txt/x"))), 0600))
	composed := filepath.Join(f.parent, "composed")
	if _, err := Compose(f.home, id, file, blobs, composed, false); err != nil {
		t.Fatal(err)
	}
	if got := string(mustRead(t, filepath.Join(composed, "one/a.txt/x"))); got != "changed\n" {
		t.Fatalf("got %q", got)
	}
}

// Of all Runtime-home paths, compose accepts only <home>/workers/work-<name>.
func TestComposeIntoTheRuntimeHomeOnlyAsAWorkFolder(t *testing.T) {
	f, id, dest, file, blobs := composeInput(t)
	home, err := canonicalDirectory(f.home)
	must(t, err)
	for _, dir := range []string{"workers/slot1", "frozen", "scratch"} {
		must(t, os.MkdirAll(filepath.Join(home, dir), 0700))
	}
	link := filepath.Join(f.parent, "home-link")
	must(t, os.Symlink(home, link))
	refused := []string{
		filepath.Join(home, "workers", "slot2"),
		filepath.Join(home, "workers", "work-"),
		filepath.Join(home, "workers", "work-X"),
		filepath.Join(home, "workers", "work-1x"),
		filepath.Join(home, "frozen", "x"),
		filepath.Join(home, "scratch", "work-x"),
		filepath.Join(home, "workers", "slot1", "work-x"),
		filepath.Join(home, "work-x"),
		filepath.Join(link, "workers", "slot2"),
		filepath.Join(home, "workers", "..", "frozen", "y"),
	}
	if folded := swapCase(home); folded != home {
		if _, err := os.Stat(folded); err == nil {
			refused = append(refused, filepath.Join(folded, "frozen", "z"))
		}
	}
	for _, path := range refused {
		_, err := Compose(f.home, id, file, blobs, path, false)
		failed(t, err, "destination_not_allowed")
		if _, err := os.Lstat(path); err == nil {
			t.Fatalf("%s was composed", path)
		}
	}

	accepted := filepath.Join(home, "workers", "work-work-0123456789abcdef")
	result, err := Compose(f.home, id, file, blobs, accepted, true)
	if err != nil {
		t.Fatal(err)
	}
	if result["destination"] != accepted {
		t.Fatalf("result %v", result)
	}
	if again := changeSetOf(t, f.home, accepted, filepath.Join(t.TempDir(), "blobs")); !jsonEqual(again, changeSetOf(t, f.home, dest, blobs)) {
		t.Fatalf("changes differ: %v", again)
	}
	if _, err = Compose(f.home, id, file, blobs, filepath.Join(home, "workers", "work-x"), false); err != nil {
		t.Fatal(err)
	}
	if left, _ := os.ReadDir(filepath.Join(home, "workers")); len(left) != 3 {
		t.Fatalf("workers: %v", left)
	}
	_, err = Compose(f.home, id, file, blobs, accepted, false)
	failed(t, err, "destination_exists")
}

func swapCase(path string) string {
	return strings.Map(func(r rune) rune {
		switch {
		case r >= 'a' && r <= 'z':
			return r - 'a' + 'A'
		case r >= 'A' && r <= 'Z':
			return r - 'A' + 'a'
		}
		return r
	}, path)
}

// The change set Compose reads is the one Changes printed, as the CLI prints it.
func TestComposeReadsTheChangeSetAsPrinted(t *testing.T) {
	f, id, dest, _, blobs := composeInput(t)
	result, err := Changes(f.home, dest, blobs)
	must(t, err)
	printed, err := json.Marshal(result)
	must(t, err)
	var set map[string]json.RawMessage
	must(t, json.Unmarshal(printed, &set))
	file := filepath.Join(t.TempDir(), "set.json")
	must(t, os.WriteFile(file, []byte(`{"base":`+string(set["snapshot_id"])+`,"roots":`+string(set["roots"])+`}`), 0600))
	if _, err = Compose(f.home, id, file, blobs, filepath.Join(f.parent, "composed"), false); err != nil {
		t.Fatal(err)
	}
}
