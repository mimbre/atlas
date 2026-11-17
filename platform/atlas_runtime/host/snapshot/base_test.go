package snapshot

// S5c P6: local base import, materialize and v3 baselines. No test here contacts Code: each home's
// code.json is a directory, so a path that tried to use Code would fail.

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
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
	for _, c := range []struct {
		name  string
		files []baseFile
		line  func(line []byte) []byte
		blob  func(staging string)
		want  string
	}{
		{name: "traversal", files: []baseFile{file("atlas", "../x", "x")}, want: `unsafe path "../x"`},
		{name: "git segment", files: []baseFile{file("atlas", "a/.git/config", "x")}, want: `unsafe path "a/.git/config"`},
		{name: "git root", files: []baseFile{file(".git", "config", "x")}, want: `root ".git"`},
		{name: "nested root", files: []baseFile{file("a/b", "x", "x")}, want: `unsafe root "a/b"`},
		{name: "entry under a symlink", files: []baseFile{link("atlas", "l", "d"), file("atlas", "l/x", "x")}, want: `inside file or symlink "atlas/l"`},
		{name: "entry under a file", files: []baseFile{file("atlas", "f", "x"), file("atlas", "f/x", "x")}, want: `inside file or symlink "atlas/f"`},
		{name: "symlink leaving its root", files: []baseFile{link("atlas", "out", "../tools/x")}, want: `symlink target "../tools/x" leaves its repository`},
		{name: "absolute symlink", files: []baseFile{link("atlas", "out", "/etc/passwd")}, want: "symlink target must be relative"},
		{name: "case collision", files: []baseFile{file("atlas", "A", "x"), file("atlas", "a", "y")}, want: `"atlas/A" and "atlas/a" differ only in case`},
		{name: "case collision of directories", files: []baseFile{file("atlas", "D/x", "x"), file("atlas", "d/y", "y")}, want: `"atlas/D" and "atlas/d" differ only in case`},
		{name: "case collision of roots", files: []baseFile{file("Atlas", "x", "x"), file("atlas", "y", "y")}, want: `"Atlas" and "atlas" differ only in case`},
		{name: "wrong blob hash", files: []baseFile{file("atlas", "a.txt", "alpha")},
			blob: func(staging string) {
				must(t, os.WriteFile(filepath.Join(staging, "blobs", sum("alpha")), []byte("alphA"), 0600))
			},
			want: "blob " + sum("alpha") + ` of "atlas/a.txt": content has 5 bytes and sha256`},
		{name: "short blob", files: []baseFile{file("atlas", "a.txt", "alpha")},
			blob: func(staging string) {
				must(t, os.WriteFile(filepath.Join(staging, "blobs", sum("alpha")), []byte("alph"), 0600))
			},
			want: "content has 4 bytes"},
		{name: "missing blob", files: []baseFile{file("atlas", "a.txt", "alpha")},
			blob: func(staging string) { must(t, os.Remove(filepath.Join(staging, "blobs", sum("alpha")))) },
			want: "missing or unreadable"},
		{name: "blob is a symlink", files: []baseFile{file("atlas", "a.txt", "alpha")},
			blob: func(staging string) {
				name := filepath.Join(staging, "blobs", sum("alpha"))
				must(t, os.Rename(name, name+".real"))
				must(t, os.Symlink(name+".real", name))
			},
			want: "missing or unreadable"},
		{name: "delete", files: []baseFile{file("atlas", "a.txt", "alpha")},
			line: func(line []byte) []byte {
				return []byte(strings.Replace(string(line), `{"kind":"file","mode":"100644","op":"write","path":"a.txt","sha256":"`+sum("alpha")+`","size":5}`, `{"op":"delete","path":"a.txt"}`, 1))
			},
			want: "a base holds writes only"},
		{name: "duplicate path", files: []baseFile{file("atlas", "a.txt", "alpha"), file("atlas", "a.txt", "alpha")}, want: `duplicate path "a.txt"`},
		{name: "unknown field", files: []baseFile{file("atlas", "a.txt", "alpha")},
			line: func(line []byte) []byte {
				return []byte(strings.Replace(string(line), `"version":1`, `"version":1,"extra":true`, 1))
			},
			want: "not one base object"},
		{name: "trailing line", files: []baseFile{file("atlas", "a.txt", "alpha")},
			line: func(line []byte) []byte { return append(line, "{}\n"...) }, want: "more than one line"},
		{name: "no roots", files: []baseFile{}, want: "base has no roots"},
	} {
		t.Run(c.name, func(t *testing.T) {
			home := baseHome(t)
			line := baseLineOf(t, c.files)
			if c.line != nil {
				line = c.line(line)
			}
			staging := stage(t, home, line, c.files)
			if c.blob != nil {
				c.blob(staging)
			}
			result, err := ImportBase(home, staging)
			if err == nil || !strings.Contains(err.Error(), c.want) {
				t.Fatalf("got %v, %v; want an error containing %q", result, err, c.want)
			}
			if strings.Contains(err.Error(), home) {
				t.Errorf("the refusal names a Runtime path: %v", err)
			}
			if left, _ := os.ReadDir(filepath.Join(home, "snapshots")); len(left) != 0 {
				t.Fatalf("a refused import left %v under snapshots", left)
			}
		})
	}
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
	if _, err = ImportBase(home, stage(t, home, line2, fixtureBase)); err == nil || !strings.Contains(err.Error(), "hashes to") {
		t.Fatalf("a tampered baseline was reused: %v", err)
	}
}

func TestMaterializeBaselineRefusesAnExistingOrWrongDestination(t *testing.T) {
	home := baseHome(t)
	id := imported(t, home)
	workers := filepath.Join(home, "workers")
	existing := filepath.Join(workers, baseWork)
	must(t, os.Mkdir(existing, 0700))
	must(t, os.WriteFile(filepath.Join(existing, "keep"), []byte("mine"), 0600))
	before := listing(t, home)
	for dest, want := range map[string]string{
		existing:                              "already exists",
		filepath.Join(home, "snapshots", "x"): "is not a folder directly in",
		filepath.Join(workers, "w1", "b"):     "is not a folder directly in",
		filepath.Join(home, "elsewhere"):      "is not a folder directly in",
		"relative/work-work-0123456789abcdef": "is not a folder directly in",
		workers + "/./" + baseWork + "x":      "is not a folder directly in",
	} {
		if result, err := MaterializeBaseline(home, id, dest); err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("%s: got %v, %v; want %q", dest, result, err, want)
		}
	}
	if _, err := MaterializeBaseline(home, "sha256:"+strings.Repeat("0", 64), filepath.Join(workers, "work-work-1111111111111111")); err == nil ||
		!strings.Contains(err.Error(), "no usable baseline") {
		t.Errorf("a missing baseline: %v", err)
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
	if err == nil || !strings.Contains(err.Error(), "already exists") {
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
// packets; on a v3 folder they refuse before writing anything (B13).
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
	homeBefore, packetBefore := listing(t, home), listing(t, packet)

	turn := "turn-0123456789abcdef"
	for name, run := range map[string]func() (map[string]any, error){
		"freeze": func() (map[string]any, error) {
			return Freeze(home, dest, turn, filepath.Join(outside, "new-packet"), "00000000-0000-4000-8000-000000000002", "", "")
		},
		"findings": func() (map[string]any, error) { return Findings(home, packet, turn) },
		"discard":  func() (map[string]any, error) { return Discard(home, "", packetID) },
	} {
		result, err := run()
		if err == nil || !strings.Contains(err.Error(), "it is built from an uploaded base; use from_work / get_frozen") {
			t.Errorf("%s: got %v, %v; want the uploaded-base refusal", name, result, err)
		}
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
