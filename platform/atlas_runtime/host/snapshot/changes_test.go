package snapshot

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"go/ast"
	"go/parser"
	gotoken "go/token"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"syscall"
	"testing"
)

func sum(data string) string {
	s := sha256.Sum256([]byte(data))
	return hex.EncodeToString(s[:])
}

// changeSetOf runs Changes and returns its result as JSON-decoded data.
func changeSetOf(t *testing.T, home, dest, blobs string) map[string]any {
	t.Helper()
	result, err := Changes(home, dest, blobs)
	if err != nil {
		t.Fatal(err)
	}
	return jsonValue(t, result).(map[string]any)
}

// failed asserts err is a Failure with code.
func failed(t *testing.T, err error, code string) {
	t.Helper()
	var failure *Failure
	if !errors.As(err, &failure) || failure.Code != code {
		t.Fatalf("got %v, want a %s failure", err, code)
	}
}

// offline makes the home's Code configuration unusable, so a command that needed Code would fail.
func offline(t *testing.T, home string) {
	t.Helper()
	must(t, os.Remove(filepath.Join(home, "code.json")))
	must(t, os.Mkdir(filepath.Join(home, "code.json"), 0700))
}

// editFolder makes one change of every kind in repository one of materializedFolder's folder and none
// in repository two.
func editFolder(t *testing.T, dest string) {
	t.Helper()
	must(t, os.WriteFile(filepath.Join(dest, "one/a.txt"), []byte("changed\n"), 0644))
	must(t, os.Mkdir(filepath.Join(dest, "one/new"), 0755))
	must(t, os.WriteFile(filepath.Join(dest, "one/new/tool.sh"), []byte("#!/bin/sh\n"), 0755))
	must(t, os.Chmod(filepath.Join(dest, "one/noeol.txt"), 0755))
	must(t, os.Remove(filepath.Join(dest, "one/link")))
	must(t, os.Symlink("bin/run", filepath.Join(dest, "one/link")))
	must(t, os.Symlink("a.txt", filepath.Join(dest, "one/new/alias")))
	must(t, os.Remove(filepath.Join(dest, "one/data.bin")))
}

func TestChangesReportsEveryRootAndKeepsBlobsOnce(t *testing.T) {
	f, id, dest := materializedFolder(t)
	editFolder(t, dest)
	must(t, os.WriteFile(filepath.Join(dest, "stray.txt"), []byte("outside\n"), 0644))
	offline(t, f.home)
	blobs := filepath.Join(t.TempDir(), "blobs")
	before := state(t, dest, f.home)

	got := changeSetOf(t, f.home, dest, blobs)
	want := jsonValue(t, map[string]any{"snapshot_id": id, "outside": []string{"stray.txt"}, "roots": []any{
		map[string]any{"root": "one", "entries": []any{
			map[string]any{"path": "a.txt", "op": "write", "kind": "file", "mode": "100644", "size": 8, "sha256": sum("changed\n")},
			map[string]any{"path": "data.bin", "op": "delete"},
			map[string]any{"path": "link", "op": "write", "kind": "symlink", "mode": "120000", "size": 7, "sha256": sum("bin/run"), "target": "bin/run"},
			map[string]any{"path": "new/alias", "op": "write", "kind": "symlink", "mode": "120000", "size": 5, "sha256": sum("a.txt"), "target": "a.txt"},
			map[string]any{"path": "new/tool.sh", "op": "write", "kind": "file", "mode": "100755", "size": 10, "sha256": sum("#!/bin/sh\n")},
			map[string]any{"path": "noeol.txt", "op": "write", "kind": "file", "mode": "100755", "size": 3, "sha256": sum("x\ny")},
		}},
		map[string]any{"root": "two", "entries": []any{}},
	}})
	if !jsonEqual(got, want) {
		t.Fatalf("got  %v\nwant %v", got, want)
	}
	equal(t, state(t, dest, f.home), before)

	// Every written file's content is kept once, read-only, under its sha256; nothing else is left.
	blobState := func() map[string]os.FileInfo {
		entries, err := os.ReadDir(blobs)
		must(t, err)
		result := map[string]os.FileInfo{}
		for _, e := range entries {
			info, err := os.Lstat(filepath.Join(blobs, e.Name()))
			must(t, err)
			result[e.Name()] = info
		}
		return result
	}
	kept := blobState()
	if len(kept) != 3 {
		t.Fatalf("blobs %v", kept)
	}
	for _, data := range []string{"changed\n", "#!/bin/sh\n", "x\ny"} {
		info := kept[sum(data)]
		if info == nil || info.Mode().Perm() != 0444 || !info.Mode().IsRegular() || string(mustRead(t, filepath.Join(blobs, sum(data)))) != data {
			t.Fatalf("blob of %q: %v", data, info)
		}
	}

	// A second run reports the same and keeps the existing blobs, not new copies.
	if again := changeSetOf(t, f.home, dest, blobs); !jsonEqual(again, want) {
		t.Fatalf("second run: %v", again)
	}
	for name, info := range blobState() {
		if !os.SameFile(info, kept[name]) || !info.ModTime().Equal(kept[name].ModTime()) {
			t.Fatalf("blob %s was replaced", name)
		}
	}
	if len(blobState()) != 3 {
		t.Fatal("second run added blobs")
	}
}

func TestChangesOfAnUnchangedFolderListsEveryRootEmpty(t *testing.T) {
	f, id, dest := materializedFolder(t)
	got := changeSetOf(t, f.home, dest, filepath.Join(t.TempDir(), "blobs"))
	want := jsonValue(t, map[string]any{"snapshot_id": id, "outside": []string{}, "roots": []any{
		map[string]any{"root": "one", "entries": []any{}}, map[string]any{"root": "two", "entries": []any{}}}})
	if !jsonEqual(got, want) {
		t.Fatalf("got %v", got)
	}
}

func TestChangesRefusesAConcurrentChange(t *testing.T) {
	f, _, dest := materializedFolder(t)
	must(t, os.WriteFile(filepath.Join(dest, "two/b.txt"), []byte("first\n"), 0644))
	blobs := filepath.Join(t.TempDir(), "blobs")
	afterChangesCapture = func() { os.WriteFile(filepath.Join(dest, "two/b.txt"), []byte("second\n"), 0644) }
	t.Cleanup(func() { afterChangesCapture = func() {} })
	_, err := Changes(f.home, dest, blobs)
	failed(t, err, "changed_during_scan")
	if left, _ := os.ReadDir(blobs); len(left) != 0 {
		t.Fatalf("a refused scan left blobs: %v", left)
	}
}

func TestChangesRefusals(t *testing.T) {
	f, _, dest := materializedFolder(t)
	blobs := filepath.Join(t.TempDir(), "blobs")

	_, err := Changes(f.home, t.TempDir(), blobs)
	failed(t, err, "not_materialized")
	_, err = Changes(f.home, filepath.Join(t.TempDir(), "missing"), blobs)
	failed(t, err, "io")

	// The lock workers and submissions hold.
	lock, err := hold(dest, "test", "nothing")
	must(t, err)
	_, err = Changes(f.home, dest, blobs)
	failed(t, err, "busy")
	lock.Close()

	for _, path := range []string{"one/pipe", "pipe"} {
		must(t, syscall.Mkfifo(filepath.Join(dest, path), 0644))
		_, err = Changes(f.home, dest, blobs)
		failed(t, err, "unsupported_entry")
		must(t, os.Remove(filepath.Join(dest, path)))
	}
	must(t, os.Symlink("../../two/b.txt", filepath.Join(dest, "one/escape")))
	_, err = Changes(f.home, dest, blobs)
	failed(t, err, "unsupported_entry")
	must(t, os.Remove(filepath.Join(dest, "one/escape")))

	// A blob folder inside the folder is refused before anything is created, however it is spelled:
	// directly, through a symlink to the folder or to one of its directories, or in another case.
	link := filepath.Join(t.TempDir(), "link")
	must(t, os.Symlink(dest, link))
	inner := filepath.Join(t.TempDir(), "inner")
	must(t, os.Symlink(filepath.Join(dest, "one"), inner))
	inside := []string{filepath.Join(dest, "one/blobs"), dest, filepath.Join(link, "one/blobs"), filepath.Join(link, "new/deeper/blobs"), link, inner, filepath.Join(inner, "blobs")}
	if _, err = os.Lstat(swapCase(dest)); err == nil {
		inside = append(inside, filepath.Join(swapCase(dest), "one/blobs"))
	}
	before := names(t, dest, "one")
	for _, dir := range inside {
		_, err = Changes(f.home, dest, dir)
		if err == nil || !strings.Contains(err.Error(), "lies inside the folder") {
			t.Errorf("%s: got %v, want a refusal of a blob folder inside the folder", dir, err)
		}
		failed(t, err, "io")
		if after := names(t, dest, "one"); !reflect.DeepEqual(after, before) {
			t.Fatalf("%s: changes wrote into the folder: %v, was %v", dir, after, before)
		}
	}
	if _, err = Changes(f.home, dest, blobs); err != nil {
		t.Fatal(err)
	}
}

// names lists the entries of dest and of each of its directories dirs.
func names(t *testing.T, dest string, dirs ...string) []string {
	t.Helper()
	listed := []string{}
	for _, dir := range append([]string{""}, dirs...) {
		entries, err := os.ReadDir(filepath.Join(dest, dir))
		must(t, err)
		for _, e := range entries {
			listed = append(listed, filepath.Join(dir, e.Name()))
		}
	}
	return listed
}

// changes and compose are offline: they never import an HTTP client or connect to Code.
func TestChangesAndComposeNeverContactCode(t *testing.T) {
	for _, name := range []string{"changes.go", "compose.go"} {
		file, err := parser.ParseFile(gotoken.NewFileSet(), name, nil, parser.ImportsOnly)
		must(t, err)
		for _, spec := range file.Imports {
			if path, _ := strconv.Unquote(spec.Path.Value); strings.HasPrefix(path, "net") {
				t.Fatalf("%s imports %s", name, path)
			}
		}
		full, err := parser.ParseFile(gotoken.NewFileSet(), name, nil, 0)
		must(t, err)
		ast.Inspect(full, func(n ast.Node) bool {
			switch n := n.(type) {
			case *ast.Ident:
				if n.Name == "connect" || n.Name == "code" {
					t.Errorf("%s uses %s", name, n.Name)
				}
			case *ast.BasicLit:
				if strings.Contains(n.Value, "code.json") {
					t.Errorf("%s names code.json", name)
				}
			}
			return true
		})
	}
}

func jsonString(t *testing.T, v any) string {
	t.Helper()
	data, err := json.Marshal(v)
	must(t, err)
	return string(data)
}
