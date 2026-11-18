package snapshot

// S5c P6: local base import, materialize and v3 baselines. No test here contacts Code: each home's
// code.json is a directory, so a path that tried to use Code would fail.

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"syscall"
	"testing"
)

const baseWork = "work-work-0123456789abcdef"

// baseFile is one entry of a test base: a file (data is its content) or a symlink (data is its target).
type baseFile struct{ root, path, kind, mode, data string }

// fixtureBase is the tree of testdata/base-entries.json and testdata/base-manifest.json.
var fixtureBase = []baseFile{
	{"atlas", "README.md", "file", "100644", "hello\n"},
	{"atlas", "bin/run", "file", "100755", "#!/bin/sh\necho ok\n"},
	{"atlas", "copy.txt", "file", "100644", "hello\n"},
	{"atlas", "docs/link", "symlink", "120000", "../README.md"},
	{"atlas", "empty", "file", "100644", ""},
	{"atlas", "nested/deep/file.txt", "file", "100644", "deep\n"},
	{"tools", "x.txt", "file", "100644", "x\n"},
}

// baseHome is a canonical Runtime home with <home>/workers, as the core creates it.
func baseHome(t *testing.T) string {
	t.Helper()
	root, err := filepath.EvalSymlinks(t.TempDir())
	must(t, err)
	home := filepath.Join(root, "runtime")
	must(t, os.MkdirAll(filepath.Join(home, "workers"), 0700))
	t.Cleanup(func() { remove(home) }) // baselines are read-only
	// No Code: code.json is a directory, so any path that tried to read it would fail.
	must(t, os.Mkdir(filepath.Join(home, "code.json"), 0700))
	return home
}

// baseLineOf is line 1 of the base stream of files (B3): roots sorted, entries sorted by path.
func baseLineOf(t *testing.T, files []baseFile) []byte {
	t.Helper()
	byRoot := map[string][]map[string]any{}
	for _, f := range files {
		e := map[string]any{"path": f.path, "op": "write", "kind": f.kind, "mode": f.mode, "size": len(f.data), "sha256": sum(f.data)}
		if f.kind == "symlink" {
			e["target"] = f.data
		}
		byRoot[f.root] = append(byRoot[f.root], e)
	}
	roots := []map[string]any{}
	for _, root := range slices.Sorted(func(yield func(string) bool) {
		for root := range byRoot {
			if !yield(root) {
				return
			}
		}
	}) {
		entries := byRoot[root]
		slices.SortFunc(entries, func(a, b map[string]any) int { return strings.Compare(a["path"].(string), b["path"].(string)) })
		roots = append(roots, map[string]any{"root": root, "entries": entries})
	}
	return []byte(jsonString(t, map[string]any{"format": "atlas-base", "version": 1, "roots": roots}) + "\n")
}

// stage writes the core's staging folder for a base under <home>/bases: entries.json is line and
// blobs/<sha256> holds each file's content.
func stage(t *testing.T, home string, line []byte, files []baseFile) string {
	t.Helper()
	must(t, os.MkdirAll(filepath.Join(home, "bases"), 0700))
	staging, err := os.MkdirTemp(filepath.Join(home, "bases"), ".staging-")
	must(t, err)
	must(t, os.Mkdir(filepath.Join(staging, "blobs"), 0700))
	must(t, os.WriteFile(filepath.Join(staging, "entries.json"), line, 0600))
	for _, f := range files {
		if f.kind == "file" {
			must(t, os.WriteFile(filepath.Join(staging, "blobs", sum(f.data)), []byte(f.data), 0600))
		}
	}
	return staging
}

// imported stages the fixture base and imports it, returning its baseline_id.
func imported(t *testing.T, home string) string {
	t.Helper()
	line, err := os.ReadFile(filepath.Join("testdata", "base-entries.json"))
	must(t, err)
	result, err := ImportBase(home, stage(t, home, line, fixtureBase))
	must(t, err)
	return result["baseline_id"].(string)
}

// refusedWith reports, as a test error, unless err is a *Failure with code and rule (empty: none)
// whose text names no path below the temporary folders roots (a Runtime home, a packet's parent).
func refusedWith(t *testing.T, what string, err error, code, rule string, roots ...string) bool {
	t.Helper()
	var failure *Failure
	if !errors.As(err, &failure) || failure.Code != code || failure.Rule != rule {
		t.Errorf("%s: got %v (%+v); want code %q, rule %q", what, err, failure, code, rule)
		return false
	}
	for _, root := range roots {
		if strings.Contains(err.Error(), root) {
			t.Errorf("%s: the refusal names a path below %s: %v", what, root, err)
			return false
		}
	}
	return true
}

// listing is describe plus every entry's modification time, to show nothing was written.
func listing(t *testing.T, root string) map[string]string {
	t.Helper()
	result := describe(t, root)
	for path := range result {
		info, err := os.Lstat(filepath.Join(root, path))
		must(t, err)
		result[path] += " " + info.ModTime().String()
	}
	return result
}

func TestBaseImportMaterializeAndStatusRoundTrip(t *testing.T) {
	home := baseHome(t)
	line, err := os.ReadFile(filepath.Join("testdata", "base-entries.json"))
	must(t, err)
	var got, want any
	must(t, json.Unmarshal(line, &got))
	must(t, json.Unmarshal(baseLineOf(t, fixtureBase), &want))
	if jsonString(t, got) != jsonString(t, want) || !strings.HasSuffix(string(line), "}\n") {
		t.Fatalf("testdata/base-entries.json is not the B3 line of fixtureBase:\n%s\n%s", line, baseLineOf(t, fixtureBase))
	}
	staging := stage(t, home, line, fixtureBase)
	before := listing(t, staging)
	result, err := ImportBase(home, staging)
	must(t, err)

	// The baseline is the version 3 manifest, byte for byte, and its id is that manifest's sha256.
	manifest, err := os.ReadFile(filepath.Join("testdata", "base-manifest.json"))
	must(t, err)
	digest := sha256.Sum256(manifest)
	id := "sha256:" + hex.EncodeToString(digest[:])
	if want := map[string]any{"baseline_id": id, "files": int64(6), "bytes": int64(37)}; jsonString(t, result) != jsonString(t, want) {
		t.Fatalf("import result %v, want %v", result, want)
	}
	baseline := filepath.Join(home, "snapshots", hex.EncodeToString(digest[:]))
	if got := string(mustRead(t, filepath.Join(baseline, "manifest.json"))); got != string(manifest) {
		t.Fatalf("baseline manifest:\n%s\nwant\n%s", got, manifest)
	}
	if got := string(mustRead(t, filepath.Join(baseline, "complete"))); got != id+"\n" {
		t.Fatalf("completion marker %q", got)
	}
	noWriteBits(t, baseline)
	equal(t, listing(t, staging), before) // staging is the core's: never written
	if left, _ := filepath.Glob(filepath.Join(home, "snapshots", ".staging-*")); len(left) != 0 {
		t.Fatalf("import left its build folder: %v", left)
	}

	dest := filepath.Join(home, "workers", baseWork)
	materialized, err := MaterializeBaseline(home, id, dest)
	must(t, err)
	if want := map[string]any{"baseline_id": id, "destination": dest}; jsonString(t, materialized) != jsonString(t, want) {
		t.Fatalf("materialize result %v", materialized)
	}
	equal(t, describe(t, dest), map[string]string{".": "dir 755", "atlas": "dir 755", "atlas/README.md": `file 644 "hello\n"`,
		"atlas/bin": "dir 755", "atlas/bin/run": `file 755 "#!/bin/sh\necho ok\n"`, "atlas/copy.txt": `file 644 "hello\n"`,
		"atlas/docs": "dir 755", "atlas/docs/link": "link ../README.md", "atlas/empty": `file 644 ""`, "atlas/nested": "dir 755",
		"atlas/nested/deep": "dir 755", "atlas/nested/deep/file.txt": `file 644 "deep\n"`, "tools": "dir 755", "tools/x.txt": `file 644 "x\n"`})
	if left, _ := filepath.Glob(filepath.Join(home, "workers", ".atlas-snapshot-*")); len(left) != 0 {
		t.Fatalf("materialize left its staging: %v", left)
	}

	status, err := Inspect(home, dest, nil, false)
	must(t, err)
	if status["clean"] != true || status["snapshot_id"] != id {
		t.Fatalf("fresh folder status: %v", status)
	}
	must(t, os.WriteFile(filepath.Join(dest, "atlas", "README.md"), []byte("edited\n"), 0644))
	status, err = Inspect(home, dest, []string{"atlas"}, true)
	must(t, err)
	changes := status["changes"].([]change)
	if status["clean"] != false || len(changes) != 1 || changes[0].Repository != "atlas" || changes[0].Path != "atlas/README.md" ||
		changes[0].Change != "modified" || !strings.Contains(changes[0].Diff, "+edited") {
		t.Fatalf("edited folder status: %+v", status)
	}
	scope, err := Verified(home, dest)
	must(t, err)
	if jsonString(t, scope["repositories"]) != `["atlas","tools"]` || scope["snapshot_id"] != id || scope["baseline"] != baseline {
		t.Fatalf("verified scope: %v", scope)
	}
}

func TestBaseImportRefusesUnsafeTrees(t *testing.T) {
	file := func(root, path, data string) baseFile { return baseFile{root, path, "file", "100644", data} }
	link := func(root, path, target string) baseFile { return baseFile{root, path, "symlink", "120000", target} }
	alpha := `{"kind":"file","mode":"100644","op":"write","path":"a.txt","sha256":"` + sum("alpha") + `","size":5}`
	// Each case breaks exactly one rule; the refusal is code invalid with that rule's id (R1).
	for _, c := range []struct {
		name  string
		files []baseFile
		line  func(line []byte) []byte
		blob  func(staging string)
		rule  string
	}{
		{name: "traversal", files: []baseFile{file("atlas", "../x", "x")}, rule: "unsafe_path"},
		{name: "git segment", files: []baseFile{file("atlas", "a/.git/config", "x")}, rule: "unsafe_path"},
		{name: "git root", files: []baseFile{file(".git", "config", "x")}, rule: "unsafe_entry"},
		{name: "git root without entries", files: []baseFile{},
			line: func([]byte) []byte {
				return []byte(`{"format":"atlas-base","roots":[{"entries":[],"root":".git"}],"version":1}` + "\n")
			}, rule: "unsafe_root"},
		{name: "nested root", files: []baseFile{file("a/b", "x", "x")}, rule: "unsafe_root"},
		{name: "entry under a symlink", files: []baseFile{link("atlas", "l", "d"), file("atlas", "l/x", "x")}, rule: "unsafe_tree"},
		{name: "entry under a file", files: []baseFile{file("atlas", "f", "x"), file("atlas", "f/x", "x")}, rule: "unsafe_tree"},
		{name: "symlink leaving its root", files: []baseFile{link("atlas", "out", "../tools/x")}, rule: "unsafe_tree"},
		{name: "absolute symlink", files: []baseFile{link("atlas", "out", "/etc/passwd")}, rule: "unsafe_entry"},
		{name: "case collision", files: []baseFile{file("atlas", "A", "x"), file("atlas", "a", "y")}, rule: "case_fold"},
		{name: "case collision of directories", files: []baseFile{file("atlas", "D/x", "x"), file("atlas", "d/y", "y")}, rule: "case_fold"},
		{name: "case collision of roots", files: []baseFile{file("Atlas", "x", "x"), file("atlas", "y", "y")}, rule: "case_fold"},
		{name: "wrong blob hash", files: []baseFile{file("atlas", "a.txt", "alpha")},
			blob: func(staging string) {
				must(t, os.WriteFile(filepath.Join(staging, "blobs", sum("alpha")), []byte("alphA"), 0600))
			},
			rule: "blob_mismatch"},
		{name: "short blob", files: []baseFile{file("atlas", "a.txt", "alpha")},
			blob: func(staging string) {
				must(t, os.WriteFile(filepath.Join(staging, "blobs", sum("alpha")), []byte("alph"), 0600))
			},
			rule: "blob_mismatch"},
		{name: "missing blob", files: []baseFile{file("atlas", "a.txt", "alpha")},
			blob: func(staging string) { must(t, os.Remove(filepath.Join(staging, "blobs", sum("alpha")))) },
			rule: "blob_missing"},
		{name: "blob is a symlink", files: []baseFile{file("atlas", "a.txt", "alpha")},
			blob: func(staging string) {
				name := filepath.Join(staging, "blobs", sum("alpha"))
				must(t, os.Rename(name, name+".real"))
				must(t, os.Symlink(name+".real", name))
			},
			rule: "blob_missing"},
		{name: "blob is a directory", files: []baseFile{file("atlas", "a.txt", "alpha")},
			blob: func(staging string) {
				name := filepath.Join(staging, "blobs", sum("alpha"))
				must(t, os.Remove(name))
				must(t, os.Mkdir(name, 0700))
			},
			rule: "blob_not_regular"},
		{name: "delete", files: []baseFile{file("atlas", "a.txt", "alpha")},
			line: func(line []byte) []byte {
				return []byte(strings.Replace(string(line), alpha, `{"op":"delete","path":"a.txt"}`, 1))
			},
			rule: "writes_only"},
		{name: "entry with an extra key", files: []baseFile{file("atlas", "a.txt", "alpha")},
			line: func(line []byte) []byte {
				return []byte(strings.Replace(string(line), `"op":"write",`, `"op":"write","x":1,`, 1))
			},
			rule: "entry_shape"},
		{name: "duplicate path", files: []baseFile{file("atlas", "a.txt", "alpha"), file("atlas", "a.txt", "alpha")}, rule: "duplicate_path"},
		{name: "duplicate root", files: []baseFile{file("atlas", "a.txt", "alpha")},
			line: func(line []byte) []byte {
				root := `{"entries":[` + alpha + `],"root":"atlas"}`
				return []byte(strings.Replace(string(line), root, root+","+root, 1))
			},
			rule: "duplicate_root"},
		{name: "unknown field", files: []baseFile{file("atlas", "a.txt", "alpha")},
			line: func(line []byte) []byte {
				return []byte(strings.Replace(string(line), `"version":1`, `"version":1,"extra":true`, 1))
			},
			rule: "not_a_base_object"},
		{name: "wrong version", files: []baseFile{file("atlas", "a.txt", "alpha")},
			line: func(line []byte) []byte {
				return []byte(strings.Replace(string(line), `"version":1`, `"version":2`, 1))
			},
			rule: "wrong_format"},
		{name: "trailing line", files: []baseFile{file("atlas", "a.txt", "alpha")},
			line: func(line []byte) []byte { return append(line, "{}\n"...) }, rule: "more_than_one_line"},
		{name: "no roots", files: []baseFile{}, rule: "no_roots"},
	} {
		t.Run(c.name, func(t *testing.T) {
			home := baseHome(t)
			line := baseLineOf(t, c.files)
			if c.line != nil {
				before := string(line)
				if line = c.line(line); string(line) == before {
					t.Fatalf("the case did not change line 1: %s", line)
				}
			}
			staging := stage(t, home, line, c.files)
			if c.blob != nil {
				c.blob(staging)
			}
			result, err := ImportBase(home, staging)
			if result != nil {
				t.Errorf("an invalid base was imported: %v", result)
			}
			refusedWith(t, "import", err, "invalid", c.rule, filepath.Dir(home))
			if left, _ := os.ReadDir(filepath.Join(home, "snapshots")); len(left) != 0 {
				t.Fatalf("a refused import left %v under snapshots", left)
			}
		})
	}
}

// TestBaseImportCapsLineOne (B7): an entries.json of more than 64 MiB is refused as line_too_large,
// even when it is otherwise a valid base line (one object padded with spaces); one of exactly
// 64 MiB is imported.
func TestBaseImportCapsLineOne(t *testing.T) {
	files := []baseFile{{"atlas", "a.txt", "file", "100644", "alpha"}}
	line := bytes.TrimSuffix(baseLineOf(t, files), []byte("\n"))
	padded := func(size int64) []byte {
		out := bytes.Repeat([]byte(" "), int(size))
		copy(out, line)
		out[size-1] = '\n'
		return out
	}
	home := baseHome(t)
	result, err := ImportBase(home, stage(t, home, padded(maxBaseLine+1), files))
	if result != nil {
		t.Fatalf("an oversized line 1 was imported: %v", result)
	}
	refusedWith(t, "import", err, "invalid", "line_too_large", filepath.Dir(home))
	if left, _ := os.ReadDir(filepath.Join(home, "snapshots")); len(left) != 0 {
		t.Fatalf("a refused import left %v under snapshots", left)
	}
	result, err = ImportBase(home, stage(t, home, padded(maxBaseLine), files))
	must(t, err)
	if result["files"] != int64(1) || result["bytes"] != int64(5) {
		t.Fatalf("a line 1 of exactly the cap: %v", result)
	}
}

// TestBaseImportChecksTheCopyItself: the blob is checked again after it is copied into the
// baseline, so a copy that differs from the verified blob is refused as blob_mismatch and nothing
// is published. The copy is replaced through the cloneFile seam.
func TestBaseImportChecksTheCopyItself(t *testing.T) {
	home := baseHome(t)
	files := []baseFile{{"atlas", "a.txt", "file", "100644", "alpha"}}
	staging := stage(t, home, baseLineOf(t, files), files)
	cloneFile = func(from, to string) error { return os.WriteFile(to, []byte("alphA"), 0600) }
	t.Cleanup(func() { cloneFile = clone })
	result, err := ImportBase(home, staging)
	if result != nil {
		t.Fatalf("a baseline with a changed copy was imported: %v", result)
	}
	refusedWith(t, "import", err, "invalid", "blob_mismatch", filepath.Dir(home))
	if left, _ := os.ReadDir(filepath.Join(home, "snapshots")); len(left) != 0 {
		t.Fatalf("a refused import left %v under snapshots", left)
	}
}

// TestBaseImportReportsAFailureThatIsNotTheBasesAsIO: a step that fails for a reason of its own
// is code io without a rule, never invalid, and names no Runtime path.
func TestBaseImportReportsAFailureThatIsNotTheBasesAsIO(t *testing.T) {
	home := baseHome(t)
	files := []baseFile{{"atlas", "a.txt", "file", "100644", "alpha"}}
	staging := stage(t, home, baseLineOf(t, files), files)
	cloneFile = func(from, to string) error { return &os.PathError{Op: "clonefileat", Path: to, Err: syscall.EIO} }
	t.Cleanup(func() { cloneFile = clone })
	_, err := ImportBase(home, staging)
	refusedWith(t, "a failed copy", err, "io", "", filepath.Dir(home))
	cloneFile = clone
	_, err = ImportBase(home, filepath.Join(home, "bases", "absent"))
	refusedWith(t, "an absent staging folder", err, "io", "", filepath.Dir(home))
	must(t, os.Remove(filepath.Join(staging, "entries.json")))
	_, err = ImportBase(home, staging)
	refusedWith(t, "no entries.json", err, "io", "", filepath.Dir(home))
}

func TestBaseReimportReusesTheBaselineAndWritesNothing(t *testing.T) {
	home := baseHome(t)
	id := imported(t, home)
	before := listing(t, filepath.Join(home, "snapshots"))
	if again := imported(t, home); again != id {
		t.Fatalf("re-import gave %s, not %s", again, id)
	}
	equal(t, listing(t, filepath.Join(home, "snapshots")), before)

	// The same tree listed in another order is the same base.
	reversed := slices.Clone(fixtureBase)
	slices.Reverse(reversed)
	var line struct {
		Format  string           `json:"format"`
		Version int              `json:"version"`
		Roots   []map[string]any `json:"roots"`
	}
	must(t, json.Unmarshal(baseLineOf(t, reversed), &line))
	slices.Reverse(line.Roots)
	result, err := ImportBase(home, stage(t, home, []byte(jsonString(t, line)+"\n"), reversed))
	must(t, err)
	if result["baseline_id"] != id {
		t.Fatalf("reordered import gave %v, not %s", result["baseline_id"], id)
	}
	equal(t, listing(t, filepath.Join(home, "snapshots")), before)

	// A reused baseline that no longer verifies is refused, not trusted.
	baseline := filepath.Join(home, "snapshots", strings.TrimPrefix(id, "sha256:"))
	must(t, os.Chmod(baseline, 0755))
	must(t, os.Chmod(filepath.Join(baseline, "manifest.json"), 0644))
	must(t, os.WriteFile(filepath.Join(baseline, "manifest.json"), []byte(`{"entries":[],"roots":[{"root":"atlas"}],"version":3}`), 0444))
	line2, err := os.ReadFile(filepath.Join("testdata", "base-entries.json"))
	must(t, err)
	result, err = ImportBase(home, stage(t, home, line2, fixtureBase))
	if result != nil {
		t.Fatalf("a tampered baseline was reused: %v", result)
	}
	refusedWith(t, "a tampered baseline", err, "io", "", filepath.Dir(home))
}

func TestMaterializeBaselineRefusesAnExistingOrWrongDestination(t *testing.T) {
	home := baseHome(t)
	id := imported(t, home)
	workers := filepath.Join(home, "workers")
	existing := filepath.Join(workers, baseWork)
	must(t, os.Mkdir(existing, 0700))
	must(t, os.WriteFile(filepath.Join(existing, "keep"), []byte("mine"), 0600))
	before := listing(t, home)
	for dest, code := range map[string]string{
		existing:                              "destination_exists",
		filepath.Join(home, "snapshots", "x"): "destination_not_allowed",
		filepath.Join(workers, "w1", "b"):     "destination_not_allowed",
		filepath.Join(home, "elsewhere"):      "destination_not_allowed",
		"relative/work-work-0123456789abcdef": "destination_not_allowed",
		workers + "/./" + baseWork + "x":      "destination_not_allowed",
	} {
		result, err := MaterializeBaseline(home, id, dest)
		if result != nil {
			t.Errorf("%s: materialized %v", dest, result)
		}
		refusedWith(t, dest, err, code, "")
	}
	for _, missing := range []string{"sha256:" + strings.Repeat("0", 64), "sha256:x"} {
		_, err := MaterializeBaseline(home, missing, filepath.Join(workers, "work-work-1111111111111111"))
		refusedWith(t, missing, err, "baseline_missing", "")
	}
	equal(t, listing(t, home), before)
}

// TestMaterializeNeverReplacesAPathCreatedMeanwhile: an empty directory created at the destination
// between the check and the publish is refused and left as it is (an exclusive rename, not os.Rename).
func TestMaterializeNeverReplacesAPathCreatedMeanwhile(t *testing.T) {
	home := baseHome(t)
	id := imported(t, home)
	dest := filepath.Join(home, "workers", baseWork)
	beforeMaterializePublish = func(path string) { must(t, os.Mkdir(path, 0700)) }
	t.Cleanup(func() { beforeMaterializePublish = func(string) {} })
	result, err := MaterializeBaseline(home, id, dest)
	if result != nil || !refusedWith(t, "materialize", err, "destination_exists", "") {
		t.Fatalf("got %v, %v; want the destination refused", result, err)
	}
	if entries, err := os.ReadDir(dest); err != nil || len(entries) != 0 {
		t.Fatalf("the directory created meanwhile was changed: %v %v", entries, err)
	}
	if left, _ := filepath.Glob(filepath.Join(home, "workers", ".atlas-snapshot-*")); len(left) != 0 {
		t.Fatalf("staging left: %v", left)
	}
	if _, err := os.Stat(recordPath(home, dest)); !os.IsNotExist(err) {
		t.Fatalf("a refused materialization was recorded: %v", err)
	}
}

// v2Baseline writes a complete version 2 (Code) baseline of files, each root a repository, and
// returns its snapshot id.
func v2Baseline(t *testing.T, home string, files []baseFile) string {
	t.Helper()
	m := manifest{Version: 2}
	for _, f := range files {
		if !slices.ContainsFunc(m.Repositories, func(r repository) bool { return r.Path == f.root }) {
			m.Repositories = append(m.Repositories, repository{Path: f.root, Repository: "github.com/test/" + f.root, Revision: "rev_" + strings.Repeat("c", 64)})
		}
		r := repository{Path: f.root, Repository: "github.com/test/" + f.root}
		if f.kind == "symlink" {
			m.Entries = append(m.Entries, symlink(r, f.path, f.data))
		} else {
			m.Entries = append(m.Entries, file(r, f.path, f.mode, f.data))
		}
	}
	slices.SortFunc(m.Repositories, func(a, b repository) int { return strings.Compare(a.Path, b.Path) })
	slices.SortFunc(m.Entries, func(a, b entry) int { return strings.Compare(a.Path, b.Path) })
	raw := m.canonical()
	digest := sha256.Sum256(raw)
	id := "sha256:" + hex.EncodeToString(digest[:])
	baseline := filepath.Join(home, "snapshots", hex.EncodeToString(digest[:]))
	tree := filepath.Join(baseline, "tree")
	for _, f := range files {
		name := filepath.Join(tree, f.root, filepath.FromSlash(f.path))
		must(t, os.MkdirAll(filepath.Dir(name), 0755))
		if f.kind == "symlink" {
			must(t, os.Symlink(f.data, name))
		} else {
			perm := os.FileMode(0444)
			if f.mode == "100755" {
				perm = 0555
			}
			must(t, os.WriteFile(name, []byte(f.data), perm))
		}
	}
	must(t, os.WriteFile(filepath.Join(baseline, "manifest.json"), raw, 0444))
	must(t, os.WriteFile(filepath.Join(baseline, "complete"), []byte(id+"\n"), 0444))
	return id
}

// TestChangesAreTheSameForAV2AndAV3BaselineOfOneTree: the A5 scan and the compose that rebuilds
// from it read a v3 baseline like a v2 one; a v2 baseline also materializes locally (B11).
func TestChangesAreTheSameForAV2AndAV3BaselineOfOneTree(t *testing.T) {
	home := baseHome(t)
	v3 := imported(t, home)
	v2 := v2Baseline(t, home, fixtureBase)
	roots := map[string]string{}
	for i, id := range []string{v2, v3} {
		dest := filepath.Join(home, "workers", fmt.Sprintf("work-work-%016d", i))
		_, err := MaterializeBaseline(home, id, dest)
		must(t, err)
		must(t, os.WriteFile(filepath.Join(dest, "atlas", "README.md"), []byte("edited\n"), 0644))
		must(t, os.Remove(filepath.Join(dest, "tools", "x.txt")))
		must(t, os.WriteFile(filepath.Join(dest, "tools", "new.txt"), []byte("new\n"), 0644))
		must(t, os.Chmod(filepath.Join(dest, "atlas", "empty"), 0755))
		blobs := filepath.Join(t.TempDir(), "blobs")
		set := changeSetOf(t, home, dest, blobs)
		if set["snapshot_id"] != id {
			t.Fatalf("changes of %s report %v", id, set["snapshot_id"])
		}
		roots[id] = jsonString(t, set["roots"])

		// Compose rebuilds the edited folder from the baseline plus the change set.
		changeSet := filepath.Join(t.TempDir(), "change-set.json")
		must(t, os.WriteFile(changeSet, []byte(jsonString(t, map[string]any{"base": id, "roots": set["roots"]})), 0600))
		composed := filepath.Join(home, "workers", fmt.Sprintf("work-work-%016d", i+10))
		_, err = Compose(home, id, changeSet, blobs, composed, false)
		must(t, err)
		equal(t, describe(t, composed), describe(t, dest))
	}
	if roots[v2] != roots[v3] {
		t.Fatalf("v2 changes %s\nv3 changes %s", roots[v2], roots[v3])
	}
	if !strings.Contains(roots[v3], `"path":"README.md"`) || !strings.Contains(roots[v3], `"op":"delete","path":"x.txt"`) {
		t.Fatalf("unexpected changes %s", roots[v3])
	}
}

// TestPacketCommandsRefuseAnUploadedBase: freeze, findings and discard are Code-shaped review
// packets; on a v3 folder they refuse with code uploaded_base before writing anything (B13). The
// freeze is of a folder whose author turn is recorded and ended, so only the guard stops it.
func TestPacketCommandsRefuseAnUploadedBase(t *testing.T) {
	home := baseHome(t)
	id := imported(t, home)
	dest := filepath.Join(home, "workers", baseWork)
	_, err := MaterializeBaseline(home, id, dest)
	must(t, err)
	// A packet-shaped folder outside the home whose tree is recorded on the same v3 baseline.
	outside, err := filepath.EvalSymlinks(t.TempDir())
	must(t, err)
	t.Cleanup(func() { remove(outside) }) // the packet tree is read-only
	packet := filepath.Join(outside, "packet")
	must(t, os.Mkdir(packet, 0700))
	empty := filepath.Join(outside, "empty.json")
	must(t, os.WriteFile(empty, []byte(jsonString(t, map[string]any{"base": id, "roots": []any{}})), 0600))
	_, err = Compose(home, id, empty, filepath.Join(outside, "no-blobs"), filepath.Join(packet, "tree"), true)
	must(t, err)
	must(t, os.MkdirAll(filepath.Join(packet, "findings"), 0700))
	must(t, os.WriteFile(filepath.Join(packet, "findings", "findings.json"), []byte("[]"), 0600))
	packetID := "00000000-0000-4000-8000-000000000001"
	must(t, os.MkdirAll(PacketDir(home, packetID), 0700))
	must(t, os.WriteFile(filepath.Join(PacketDir(home, packetID), "packet.json"),
		[]byte(jsonString(t, map[string]any{"packet_id": packetID, "fingerprint": "fpr_" + strings.Repeat("d", 64), "tree": filepath.Join(packet, "tree")})), 0600))
	turn := authorTurn(t, home, dest, "finished")
	homeBefore, packetBefore := listing(t, home), listing(t, packet)

	for name, run := range map[string]func() (map[string]any, error){
		"freeze": func() (map[string]any, error) {
			return Freeze(home, dest, turn, filepath.Join(outside, "new-packet"), "00000000-0000-4000-8000-000000000002", "", "")
		},
		"findings": func() (map[string]any, error) { return Findings(home, packet, turn) },
		"discard":  func() (map[string]any, error) { return Discard(home, "", packetID) },
	} {
		result, err := run()
		if result != nil {
			t.Errorf("%s: answered %v", name, result)
		}
		refusedWith(t, name, err, "uploaded_base", "", filepath.Dir(home), outside)
	}
	equal(t, listing(t, home), homeBefore)
	equal(t, listing(t, packet), packetBefore)
	if _, err := os.Lstat(filepath.Join(outside, "new-packet")); !os.IsNotExist(err) {
		t.Fatalf("freeze created the packet folder: %v", err)
	}
}

// TestBaseManifestMustBeCanonical: a v3 manifest.json that is not canonical is not a baseline,
// whatever its hash, so one tree has one baseline_id.
func TestBaseManifestMustBeCanonical(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("testdata", "base-manifest.json"))
	must(t, err)
	if _, _, err := loadBaseManifest(raw, "sha256:x"); err != nil {
		t.Fatalf("the canonical fixture: %v", err)
	}
	for _, bad := range []string{
		strings.Replace(string(raw), `{"kind"`, `{ "kind"`, 1),
		strings.Replace(string(raw), `"version":3}`, `"version":3,"x":1}`, 1),
		strings.Replace(string(raw), `"roots":[{"root":"atlas"},{"root":"tools"}]`, `"roots":[{"root":"tools"},{"root":"atlas"}]`, 1),
	} {
		if _, _, err := loadBaseManifest([]byte(bad), "sha256:x"); err == nil {
			t.Errorf("accepted %s", bad)
		}
	}
}
