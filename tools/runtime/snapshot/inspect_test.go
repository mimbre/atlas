package snapshot

import (
	"archive/tar"
	"crypto/sha256"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

var (
	text       = "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n"
	inspected  = []entry{file(one, "a.txt", "100644", text), file(one, "bin/run", "100755", "#!/bin/sh\n"), file(one, "data.bin", "100644", "\x00\x01\x02"), symlink(one, "link", "a.txt"), file(one, "noeol.txt", "100644", "x\ny"), file(two, "b.txt", "100644", "beta\n"), file(two, "c.txt", "100644", "gamma\n"), file(two, "tool", "100755", "t\n")}
	oneMembers = []member{{"a.txt", tar.TypeReg, 0644, text, ""}, {"bin/run", tar.TypeReg, 0755, "#!/bin/sh\n", ""}, {"data.bin", tar.TypeReg, 0644, "\x00\x01\x02", ""}, {"link", tar.TypeSymlink, 0777, "", "a.txt"}, {"noeol.txt", tar.TypeReg, 0644, "x\ny", ""}}
	twoMembers = []member{{"b.txt", tar.TypeReg, 0644, "beta\n", ""}, {"c.txt", tar.TypeReg, 0644, "gamma\n", ""}, {"tool", tar.TypeReg, 0755, "t\n", ""}}
)

// materializedFolder publishes the two-repository snapshot above and returns its destination.
func materializedFolder(t *testing.T) (*fixture, string, string) {
	t.Helper()
	id, raw := snapshotOf(t, []repository{one, two}, inspected...)
	f := newFixture(t, raw, map[string][]byte{"one": archiveOf(t, oneMembers...), "two": archiveOf(t, twoMembers...)})
	dest := filepath.Join(f.parent, "work")
	if _, err := Materialize(f.home, id, dest); err != nil {
		t.Fatal(err)
	}
	return f, id, dest
}

func inspect(t *testing.T, home, dest string, paths []string, diffs bool) (map[string]any, []change) {
	t.Helper()
	result, err := Inspect(home, dest, paths, diffs)
	if err != nil {
		t.Fatal(err)
	}
	return result, result["changes"].([]change)
}

// state lists every path below the roots with its kind, mode, content or target and mtime.
func state(t *testing.T, roots ...string) map[string]string {
	t.Helper()
	result := map[string]string{}
	for _, root := range roots {
		for path, description := range describe(t, root) {
			info, err := os.Lstat(filepath.Join(root, path))
			if err != nil {
				t.Fatal(err)
			}
			result[filepath.Join(root, path)] = description + " " + info.ModTime().Format(time.RFC3339Nano)
		}
	}
	return result
}

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

func TestUnchangedMaterializationIsClean(t *testing.T) {
	f, id := codeFixture(t)
	dest := filepath.Join(f.parent, "work")
	_, err := Materialize(f.home, id, dest)
	must(t, err)
	before := state(t, dest, f.home)
	for _, diffs := range []bool{false, true} {
		// A relative destination resolves like Materialize resolved it.
		t.Chdir(f.parent)
		result, changes := inspect(t, f.home, "work", nil, diffs)
		if result["snapshot_id"] != id || result["destination"] != dest || result["clean"] != true || changes == nil || len(changes) != 0 {
			t.Fatalf("diffs=%v: got %v", diffs, result)
		}
	}
	_, changes := inspect(t, f.home, dest, []string{"beta", "repos/alpha"}, true)
	if len(changes) != 0 {
		t.Fatalf("got %v", changes)
	}
	equal(t, state(t, dest, f.home), before)
}

func TestInspectionReportsEveryChangeKindWithoutWriting(t *testing.T) {
	f, id, dest := materializedFolder(t)
	outside := t.TempDir()
	must(t, os.WriteFile(filepath.Join(outside, "secret.txt"), []byte("not in the snapshot\n"), 0644))
	at := func(path string) string { return filepath.Join(dest, path) }
	must(t, os.WriteFile(at("one/a.txt"), []byte(strings.Replace(text, "5\n", "five\n", 1)), 0644))
	must(t, os.WriteFile(at("one/noeol.txt"), []byte("x\nz"), 0644))
	must(t, os.WriteFile(at("one/data.bin"), []byte("\x00\x09"), 0644))
	must(t, os.Chmod(at("one/bin/run"), 0644))
	must(t, os.MkdirAll(at("one/new/empty"), 0755))
	must(t, os.WriteFile(at("one/new/file.txt"), []byte("hello\n"), 0644))
	must(t, os.WriteFile(at("one/big.txt"), []byte(strings.Repeat("big\n", maxText/4+1)), 0644))
	must(t, os.Remove(at("one/link")))
	must(t, os.Symlink("noeol.txt", at("one/link")))
	must(t, os.Symlink(outside, at("one/outside")))
	must(t, os.Remove(at("two/b.txt")))
	must(t, os.Symlink("c.txt", at("two/b.txt")))
	must(t, os.Remove(at("two/c.txt")))
	must(t, os.WriteFile(at("two/tool"), []byte("u\n"), 0644))
	must(t, os.Chmod(at("two/tool"), 0644))
	must(t, os.WriteFile(at("notes.txt"), []byte("outside\n"), 0644))
	before := state(t, dest, f.home)

	r1, r2 := one.Repository, two.Repository
	want := []change{
		{Repository: "", Path: "notes.txt", Change: "added", Diff: "--- /dev/null\n+++ b/notes.txt\n@@ -0,0 +1 @@\n+outside\n"},
		{Repository: r1, Path: "one/a.txt", Change: "modified", Diff: "--- a/one/a.txt\n+++ b/one/a.txt\n@@ -2,7 +2,7 @@\n 2\n 3\n 4\n-5\n+five\n 6\n 7\n 8\n"},
		{Repository: r1, Path: "one/big.txt", Change: "added", Note: "larger than 1 MiB: not classified or diffed"},
		{Repository: r1, Path: "one/bin/run", Change: "mode", OldMode: "100755", NewMode: "100644"},
		{Repository: r1, Path: "one/data.bin", Change: "modified", Binary: true},
		{Repository: r1, Path: "one/link", Change: "symlink", OldTarget: "a.txt", NewTarget: "noeol.txt"},
		{Repository: r1, Path: "one/new/file.txt", Change: "added", Diff: "--- /dev/null\n+++ b/one/new/file.txt\n@@ -0,0 +1 @@\n+hello\n"},
		{Repository: r1, Path: "one/noeol.txt", Change: "modified", Diff: "--- a/one/noeol.txt\n+++ b/one/noeol.txt\n@@ -1,2 +1,2 @@\n x\n-y\n\\ No newline at end of file\n+z\n\\ No newline at end of file\n"},
		{Repository: r1, Path: "one/outside", Change: "added", NewTarget: outside},
		{Repository: r2, Path: "two/b.txt", Change: "kind", OldKind: "file", NewKind: "symlink", NewTarget: "c.txt"},
		{Repository: r2, Path: "two/c.txt", Change: "deleted", Diff: "--- a/two/c.txt\n+++ /dev/null\n@@ -1 +0,0 @@\n-gamma\n"},
		{Repository: r2, Path: "two/tool", Change: "modified", OldMode: "100755", NewMode: "100644", Diff: "--- a/two/tool\n+++ b/two/tool\n@@ -1 +1 @@\n-t\n+u\n"},
	}
	result, changes := inspect(t, f.home, dest, nil, true)
	if result["snapshot_id"] != id || result["clean"] != false || !reflect.DeepEqual(changes, want) {
		t.Fatalf("got %v\n%#v", result, changes)
	}
	status := []change{}
	for _, c := range want {
		c.Diff = ""
		status = append(status, c)
	}
	if _, changes = inspect(t, f.home, dest, nil, false); !reflect.DeepEqual(changes, status) {
		t.Fatalf("status: %#v", changes)
	}
	// --path selects repositories and leaves out everything outside them.
	if _, changes = inspect(t, f.home, dest, []string{"two"}, false); !reflect.DeepEqual(changes, status[9:]) {
		t.Fatalf("two: %#v", changes)
	}
	if _, changes = inspect(t, f.home, dest, []string{"two", "one"}, true); !reflect.DeepEqual(changes, want[1:]) {
		t.Fatalf("one and two: %#v", changes)
	}
	equal(t, state(t, dest, f.home), before)
}

func TestKindChangesAndReplacedFolders(t *testing.T) {
	f, _, dest := materializedFolder(t)
	at := func(path string) string { return filepath.Join(dest, path) }
	// A directory replaces a file, a file replaces a symlink, a symlink replaces a folder.
	must(t, os.Remove(at("one/a.txt")))
	must(t, os.MkdirAll(at("one/a.txt"), 0755))
	must(t, os.WriteFile(at("one/a.txt/inner"), []byte("i\n"), 0644))
	must(t, os.Remove(at("one/link")))
	must(t, os.WriteFile(at("one/link"), []byte("now a file\n"), 0644))
	must(t, os.Remove(at("one/bin/run")))
	must(t, os.Remove(at("one/bin")))
	must(t, os.Symlink("../two", at("one/bin")))
	r1 := one.Repository
	want := []change{
		{Repository: r1, Path: "one/a.txt", Change: "kind", OldKind: "file", NewKind: "directory"},
		{Repository: r1, Path: "one/a.txt/inner", Change: "added"},
		{Repository: r1, Path: "one/bin", Change: "added", NewTarget: "../two"},
		{Repository: r1, Path: "one/bin/run", Change: "deleted"},
		{Repository: r1, Path: "one/link", Change: "kind", OldKind: "symlink", NewKind: "file", OldTarget: "a.txt"},
	}
	if _, changes := inspect(t, f.home, dest, []string{"one"}, false); !reflect.DeepEqual(changes, want) {
		t.Fatalf("got %#v", changes)
	}

	// A whole repository folder replaced by a symlink is never followed.
	must(t, os.Rename(at("two"), at("moved")))
	must(t, os.Symlink("moved", at("two")))
	_, changes := inspect(t, f.home, dest, []string{"two"}, false)
	if len(changes) != 4 || changes[0] != (change{Repository: two.Repository, Path: "two", Change: "added", NewTarget: "moved"}) || changes[1].Change != "deleted" {
		t.Fatalf("got %#v", changes)
	}
}

func TestInspectionRefusesMissingOrInvalidBaselines(t *testing.T) {
	writable := func(t *testing.T, paths ...string) {
		for _, path := range paths {
			must(t, os.Chmod(path, 0755))
		}
	}
	for _, test := range []struct {
		name   string
		damage func(t *testing.T, f *fixture, baseline, dest string)
		paths  []string
		want   string
	}{
		{"unknown path", func(*testing.T, *fixture, string, string) {}, []string{"one", "three"}, `--path "three" is not a materialized repository path; use one of ["one" "two"]`},
		{"missing record", func(t *testing.T, f *fixture, _, _ string) {
			must(t, os.RemoveAll(filepath.Join(f.home, "materializations")))
		}, nil, "no materialization record for "},
		{"record for another folder", func(t *testing.T, f *fixture, _, dest string) {
			path := filepath.Join(f.home, "materializations", fmt.Sprintf("%x.json", sha256.Sum256([]byte(dest))))
			data := mustRead(t, path)
			must(t, os.WriteFile(path, []byte(strings.Replace(string(data), dest, dest+"x", 1)), 0600))
		}, nil, "invalid materialization record "},
		{"missing destination", func(t *testing.T, _ *fixture, _, dest string) {
			must(t, os.Rename(dest, dest+".moved"))
		}, nil, "does not exist"},
		{"destination replaced by a symlink", func(t *testing.T, _ *fixture, _, dest string) {
			must(t, os.Rename(dest, dest+".moved"))
			must(t, os.Symlink(dest+".moved", dest))
		}, nil, "is not a directory"},
		{"missing baseline", func(t *testing.T, _ *fixture, baseline, _ string) {
			remove(baseline)
		}, nil, "is missing or incomplete"},
		{"missing completion marker", func(t *testing.T, _ *fixture, baseline, _ string) {
			writable(t, baseline)
			must(t, os.Remove(filepath.Join(baseline, "complete")))
		}, nil, "is missing or incomplete"},
		{"tampered manifest", func(t *testing.T, _ *fixture, baseline, _ string) {
			writable(t, baseline, filepath.Join(baseline, "manifest.json"))
			path := filepath.Join(baseline, "manifest.json")
			must(t, os.WriteFile(path, []byte(strings.Replace(string(mustRead(t, path)), `"size":5`, `"size":6`, 1)), 0644))
		}, nil, "hashes to sha256:"},
		{"missing baseline file", func(t *testing.T, _ *fixture, baseline, dest string) {
			writable(t, filepath.Join(baseline, "tree", "one"))
			must(t, os.Remove(filepath.Join(baseline, "tree", "one", "a.txt")))
			must(t, os.WriteFile(filepath.Join(dest, "one", "a.txt"), []byte("edited\n"), 0644))
		}, nil, "/tree/one/a.txt is missing or does not match the manifest"},
		{"altered baseline file", func(t *testing.T, _ *fixture, baseline, dest string) {
			path := filepath.Join(baseline, "tree", "two", "c.txt")
			writable(t, path)
			must(t, os.WriteFile(path, []byte("GAMMA\n"), 0644))
			must(t, os.Remove(filepath.Join(dest, "two", "c.txt")))
		}, nil, "/tree/two/c.txt is missing or does not match the manifest"},
	} {
		t.Run(test.name, func(t *testing.T) {
			f, id, dest := materializedFolder(t)
			test.damage(t, f, filepath.Join(f.home, "snapshots", strings.TrimPrefix(id, "sha256:")), dest)
			for _, diffs := range []bool{false, true} {
				result, err := Inspect(f.home, dest, test.paths, diffs)
				if err == nil || !strings.Contains(err.Error(), test.want) {
					t.Fatalf("diffs=%v: got %v, %v; want error containing %q", diffs, result, err, test.want)
				}
			}
		})
	}
}

func TestUnifiedDiff(t *testing.T) {
	numbered := func(from, to int, change map[int]string) string {
		var b strings.Builder
		for i := from; i <= to; i++ {
			if line, ok := change[i]; ok {
				b.WriteString(line)
			} else {
				fmt.Fprintf(&b, "%d\n", i)
			}
		}
		return b.String()
	}
	for _, test := range []struct{ name, a, b, want string }{
		{"identical", "a\nb\n", "a\nb\n", ""},
		{"both empty", "", "", ""},
		{"empty to text", "", "a\n", "@@ -0,0 +1 @@\n+a\n"},
		{"insert at start", "a\nb\n", "x\na\nb\n", "@@ -1,2 +1,3 @@\n+x\n a\n b\n"},
		{"delete at end", "a\nb\nc\n", "a\nb\n", "@@ -1,3 +1,2 @@\n a\n b\n-c\n"},
		{"add trailing newline", "a\nb", "a\nb\n", "@@ -1,2 +1,2 @@\n a\n-b\n\\ No newline at end of file\n+b\n"},
		{"changes 6 lines apart merge", numbered(1, 20, nil), numbered(1, 20, map[int]string{5: "five\n", 12: "twelve\n"}),
			"@@ -2,14 +2,14 @@\n 2\n 3\n 4\n-5\n+five\n 6\n 7\n 8\n 9\n 10\n 11\n-12\n+twelve\n 13\n 14\n 15\n"},
		{"changes 7 lines apart split", numbered(1, 20, nil), numbered(1, 20, map[int]string{5: "five\n", 13: "thirteen\n"}),
			"@@ -2,7 +2,7 @@\n 2\n 3\n 4\n-5\n+five\n 6\n 7\n 8\n@@ -10,7 +10,7 @@\n 10\n 11\n 12\n-13\n+thirteen\n 14\n 15\n 16\n"},
		{"interleaved edits", "a\nb\nc\nd\n", "b\nx\nd\ny\n", "@@ -1,4 +1,4 @@\n-a\n b\n-c\n+x\n d\n+y\n"},
	} {
		t.Run(test.name, func(t *testing.T) {
			got, ok := unified("a/f", "b/f", lines([]byte(test.a)), lines([]byte(test.b)))
			if test.want != "" {
				test.want = "--- a/f\n+++ b/f\n" + test.want
			}
			if !ok || got != test.want {
				t.Fatalf("got %q, want %q", got, test.want)
			}
		})
	}
	// Long input with few changes at both ends, so trimming common lines leaves the whole file to Myers.
	count := 3 * maxEdits
	diff, ok := unified("a/f", "b/f", lines([]byte(numbered(1, count, nil))), lines([]byte(numbered(1, count, map[int]string{1: "first\n", count: "last\n"}))))
	if want := fmt.Sprintf("--- a/f\n+++ b/f\n@@ -1,4 +1,4 @@\n-1\n+first\n 2\n 3\n 4\n@@ -%d,4 +%d,4 @@\n %d\n %d\n %d\n-%d\n+last\n", count-3, count-3, count-3, count-2, count-1, count); !ok || diff != want {
		t.Fatalf("got %v %q", ok, diff)
	}
	odd := func(n int) []string {
		result := make([]string, n)
		for i := range result {
			result[i] = fmt.Sprintf("%d-%d\n", n, i)
		}
		return result
	}
	if diff, ok := unified("a/f", "b/f", odd(maxEdits/2+1), odd(maxEdits/2)); ok || diff != "" {
		t.Fatalf("more than %d changed lines: %v %q", maxEdits, ok, diff)
	}
}

func TestTooManyChangedLinesGetANote(t *testing.T) {
	f, _, dest := materializedFolder(t)
	var b strings.Builder
	for i := range maxEdits {
		fmt.Fprintf(&b, "line %d\n", i)
	}
	must(t, os.WriteFile(filepath.Join(dest, "one", "a.txt"), []byte(b.String()), 0644))
	_, changes := inspect(t, f.home, dest, []string{"one"}, true)
	want := []change{{Repository: one.Repository, Path: "one/a.txt", Change: "modified", Note: fmt.Sprintf("more than %d changed lines: no text diff", maxEdits)}}
	if !reflect.DeepEqual(changes, want) {
		t.Fatalf("got %#v", changes)
	}
	if _, changes = inspect(t, f.home, dest, []string{"one"}, false); !reflect.DeepEqual(changes, []change{{Repository: one.Repository, Path: "one/a.txt", Change: "modified"}}) {
		t.Fatalf("status: %#v", changes)
	}
}
