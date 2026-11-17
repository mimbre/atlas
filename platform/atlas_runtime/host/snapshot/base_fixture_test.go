package snapshot

// The shared base fixture (work acquisition M3, #317 Q4): Flow's Bases writes an atlas-base v1
// line, and its own test pins those bytes to platform/atlas_flow/test/fixtures/base_manifest/
// (manifest plus blobs/<sha256>). This is the Runtime's side of that pin: the same files, read in
// place, through ImportBase and readBaseLine, must import to the baseline below. If the reader's
// rules change, this goes red; if Flow's bytes change, Flow's test goes red. Together the two
// sides cannot drift apart unnoticed.

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

// baseFixtureDir is the shared fixture, in place, from this package's folder.
var baseFixtureDir = filepath.Join("..", "..", "..", "atlas_flow", "test", "fixtures", "base_manifest")

// baseFixtureID is the baseline the fixture imports to: sha256 of the version 3 manifest the
// reader derives from it (the id the A1 fix report and its re-review recorded).
const baseFixtureID = "sha256:f195116376d779057f050c6ccc1adcd46f21254da13bb220c4c81ca0d92e4a46"

// baseFixture reads the fixture's manifest (line 1 of a base stream) and its blobs by name.
func baseFixture(t *testing.T) ([]byte, map[string][]byte) {
	t.Helper()
	line, err := os.ReadFile(filepath.Join(baseFixtureDir, "manifest"))
	must(t, err)
	names, err := os.ReadDir(filepath.Join(baseFixtureDir, "blobs"))
	must(t, err)
	blobs := map[string][]byte{}
	for _, name := range names {
		blobs[name.Name()] = mustRead(t, filepath.Join(baseFixtureDir, "blobs", name.Name()))
	}
	if len(line) == 0 || len(blobs) == 0 {
		t.Fatalf("the shared base fixture is missing at %s", baseFixtureDir)
	}
	return line, blobs
}

// stageFixture writes the core's staging folder for line and blobs, as the core stages a base
// (entries.json and blobs/<sha256>), and returns it.
func stageFixture(t *testing.T, home string, line []byte, blobs map[string][]byte) string {
	t.Helper()
	must(t, os.MkdirAll(filepath.Join(home, "bases"), 0700))
	staging, err := os.MkdirTemp(filepath.Join(home, "bases"), ".staging-")
	must(t, err)
	must(t, os.Mkdir(filepath.Join(staging, "blobs"), 0700))
	must(t, os.WriteFile(filepath.Join(staging, "entries.json"), line, 0600))
	for name, data := range blobs {
		must(t, os.WriteFile(filepath.Join(staging, "blobs", name), data, 0600))
	}
	return staging
}

func TestSharedBaseFixtureImports(t *testing.T) {
	line, blobs := baseFixture(t)

	// Every blob is named by its own sha256, and the blobs are exactly the distinct file contents
	// the reader asks for: none missing, none extra.
	for name, data := range blobs {
		if sum(string(data)) != name {
			t.Fatalf("fixture blob %s holds content with sha256 %s", name, sum(string(data)))
		}
	}
	b, err := readBaseLine(filepath.Join(stageFixture(t, baseHome(t), line, nil), "entries.json"))
	must(t, err)
	wanted := []string{}
	for _, e := range b.Entries {
		if e.Kind == "file" && !slices.Contains(wanted, e.SHA256) {
			wanted = append(wanted, e.SHA256)
		}
	}
	slices.Sort(wanted)
	if got := slices.Sorted(func(yield func(string) bool) {
		for name := range blobs {
			if !yield(name) {
				return
			}
		}
	}); !slices.Equal(got, wanted) {
		t.Fatalf("fixture blobs %v, the manifest's file contents %v", got, wanted)
	}

	home := baseHome(t)
	result, err := ImportBase(home, stageFixture(t, home, line, blobs))
	must(t, err)
	if want := map[string]any{"baseline_id": baseFixtureID, "files": int64(7), "bytes": int64(49)}; jsonString(t, result) != jsonString(t, want) {
		t.Fatalf("import result %v, want %v", result, want)
	}
	baseline := filepath.Join(home, "snapshots", strings.TrimPrefix(baseFixtureID, "sha256:"))
	if got := sum(string(mustRead(t, filepath.Join(baseline, "manifest.json")))); "sha256:"+got != baseFixtureID {
		t.Fatalf("baseline manifest has sha256 %s, not the baseline id", got)
	}

	// The work folder built from it holds the fixture's tree, modes, symlink and names included.
	dest := filepath.Join(home, "workers", baseWork)
	_, err = MaterializeBaseline(home, baseFixtureID, dest)
	must(t, err)
	equal(t, describe(t, dest), map[string]string{".": "dir 755", "app": "dir 755",
		"app/README.md": `file 644 "hello\n"`, "app/copy.txt": `file 644 "hello\n"`,
		"app/bin": "dir 755", "app/bin/run": `file 755 "#!/bin/sh\necho run\n"`,
		"app/docs": "dir 755", "app/docs/link": "link ../README.md",
		`app/docs/say "hi".txt`: `file 644 "quoted\n"`, "app/docs/ünïcode.md": `file 644 "utf-8\n"`,
		"app/empty": `file 644 ""`, "app/nested": "dir 755", "app/nested/deep": "dir 755",
		"app/nested/deep/file.txt": `file 644 "deep\n"`})
}

// Each case changes one byte or field of the fixture, in memory; the reader refuses it with the
// rule that byte or field breaks. A replacement that does not match exactly once fails the case,
// so a changed fixture cannot turn a case into a no-op.
func TestSharedBaseFixtureMutationsAreRefused(t *testing.T) {
	line, blobs := baseFixture(t)
	once := func(t *testing.T, s, old, new string) []byte {
		t.Helper()
		if n := strings.Count(s, old); n != 1 {
			t.Fatalf("%q occurs %d times in the fixture, not once", old, n)
		}
		return []byte(strings.Replace(s, old, new, 1))
	}
	readme := sum("hello\n")
	for _, c := range []struct {
		name, old, new string
		blob           func(map[string][]byte)
		rule           string
	}{
		{name: "no format", old: `"format":"atlas-base",`, new: ``, rule: "wrong_format"},
		{name: "version 2", old: `"version":1}`, new: `"version":2}`, rule: "wrong_format"},
		{name: "an extra top-level key", old: `"version":1}`, new: `"version":1,"base_id":"x"}`, rule: "not_a_base_object"},
		{name: "a second line", old: "}\n", new: "}\n\n", rule: "more_than_one_line"},
		{name: "symlink without its target", old: `,"target":"../README.md"`, new: ``, rule: "entry_shape"},
		{name: "a mode a base may not hold", old: `"mode":"100755"`, new: `"mode":"100775"`, rule: "unsafe_entry"},
		{name: "an unsafe path", old: `"path":"empty"`, new: `"path":"em\tpty"`, rule: "unsafe_path"},
		{name: "a size that is not the blob's", old: `"size":19`, new: `"size":20`, rule: "blob_mismatch"},
		{name: "one changed blob byte", blob: func(b map[string][]byte) { b[readme] = []byte("hellO\n") }, rule: "blob_mismatch"},
	} {
		t.Run(c.name, func(t *testing.T) {
			mutated := line
			if c.old != "" {
				mutated = once(t, string(line), c.old, c.new)
			}
			served := map[string][]byte{}
			for name, data := range blobs {
				served[name] = data
			}
			if c.blob != nil {
				c.blob(served)
			}
			home := baseHome(t)
			_, err := ImportBase(home, stageFixture(t, home, mutated, served))
			refusedWith(t, c.name, err, "invalid", c.rule, home)
			if left, _ := filepath.Glob(filepath.Join(home, "snapshots", "*")); len(left) != 0 {
				t.Fatalf("a refused base left %v", left)
			}
		})
	}
}
