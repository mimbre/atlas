package snapshot

import (
	"archive/tar"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io/fs"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"
)

const (
	token      = "runtime-secret-7f3a91"
	wrongToken = "wrong-secret-123"
)

// fixture is a fake Code service plus a Runtime home and a destination parent.
type fixture struct {
	home, parent string
	manifest     []byte
	archives     map[string][]byte
	hook         func(w http.ResponseWriter, r *http.Request) bool
	archiveHits  int
}

func newFixture(t *testing.T, manifest []byte, archives map[string][]byte) *fixture {
	t.Helper()
	parent, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	f := &fixture{home: t.TempDir(), parent: parent, manifest: manifest, archives: archives}
	server := httptest.NewServer(http.HandlerFunc(f.serve))
	t.Cleanup(server.Close)
	t.Cleanup(func() { remove(f.home) }) // baselines are read-only
	f.configure(t, server.URL, token)
	return f
}

func (f *fixture) configure(t *testing.T, url, secret string) {
	t.Helper()
	file := filepath.Join(t.TempDir(), "runtime.token")
	config, _ := json.Marshal(map[string]string{"url": url, "token_file": file})
	if os.WriteFile(file, []byte(secret+"\n"), 0600) != nil || os.WriteFile(filepath.Join(f.home, "code.json"), config, 0600) != nil {
		t.Fatal("cannot write Code configuration")
	}
}

func codeError(w http.ResponseWriter, status int, code, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	fmt.Fprintf(w, `{"error":{"code":%q,"message":%q,"details":{}}}`, code, message)
}

func (f *fixture) serve(w http.ResponseWriter, r *http.Request) {
	if r.Header.Get("Authorization") != "Bearer "+token {
		codeError(w, 401, "unauthorized", "Missing or wrong bearer token")
		return
	}
	if strings.HasSuffix(r.URL.Path, "/archive") {
		f.archiveHits++
	}
	if f.hook != nil && f.hook(w, r) {
		return
	}
	archive, ok := f.archives[r.URL.Query().Get("path")]
	switch {
	case strings.HasSuffix(r.URL.Path, "/manifest"):
		w.Write(f.manifest)
	case strings.HasSuffix(r.URL.Path, "/archive") && ok:
		w.Header().Set("Content-Length", strconv.Itoa(len(archive)))
		w.Write(archive)
	default:
		codeError(w, 404, "not_found", "Snapshot not found")
	}
}

// refused asserts a failed materialization left no destination, staging or baseline behind.
func (f *fixture) refused(t *testing.T, id, want string) {
	t.Helper()
	dest := filepath.Join(f.parent, "work")
	result, err := Materialize(f.home, id, dest)
	if err == nil || !strings.Contains(err.Error(), want) {
		t.Fatalf("got %v, %v; want error containing %q", result, err, want)
	}
	if strings.Contains(err.Error(), token) || strings.Contains(err.Error(), wrongToken) {
		t.Fatalf("error exposes the token: %v", err)
	}
	if left, _ := os.ReadDir(f.parent); len(left) != 0 {
		t.Fatalf("destination parent is not empty: %v", left)
	}
	if left, _ := os.ReadDir(filepath.Join(f.home, "snapshots")); len(left) != 0 {
		t.Fatalf("baseline storage is not empty: %v", left)
	}
}

// describe lists every path below root with its kind, permissions and content or target.
func describe(t *testing.T, root string) map[string]string {
	t.Helper()
	result := map[string]string{}
	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(root, path)
		info, err := os.Lstat(path)
		if err != nil {
			return err
		}
		switch {
		case info.Mode()&fs.ModeSymlink != 0:
			target, err := os.Readlink(path)
			result[rel] = "link " + target
			return err
		case info.IsDir():
			result[rel] = fmt.Sprintf("dir %o", info.Mode().Perm())
		default:
			data, err := os.ReadFile(path)
			result[rel] = fmt.Sprintf("file %o %q", info.Mode().Perm(), data)
			return err
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return result
}

func equal(t *testing.T, got, want map[string]string) {
	t.Helper()
	if reflect.DeepEqual(got, want) {
		return
	}
	for path := range want {
		if got[path] != want[path] {
			t.Errorf("%q: got %q, want %q", path, got[path], want[path])
		}
	}
	for path := range got {
		if _, ok := want[path]; !ok {
			t.Errorf("unexpected %q: %q", path, got[path])
		}
	}
	t.FailNow()
}

var long = "long-" + strings.Repeat("x", 110) + ".txt"

// codeTree is the content of the two repositories behind testdata/code-*, which real Code
// served for fixture repositories at 0786d60: POST /v1/snapshots, then GET manifest and archives.
// code-manifest-v1.json is that reply from before revision handles; code-manifest.json is its
// successor as Code's own migration (AtlasCode.Migration) wrote it, with the same entries.
func codeTree(file, executable, dir os.FileMode) map[string]string {
	f := func(mode os.FileMode, data string) string { return fmt.Sprintf("file %o %q", mode, data) }
	binary := make([]byte, 512)
	for i := range binary {
		binary[i] = byte(i)
	}
	tree := map[string]string{
		"beta/README.md":                         f(file, "b\n"),
		"beta/tools/build":                       f(executable, "#!/bin/sh\nexit 0\n"),
		"repos/alpha/bin/data.bin":               f(file, string(binary)),
		"repos/alpha/empty":                      f(file, ""),
		"repos/alpha/line\u2028sep.txt":          f(file, "sep\n"),
		"repos/alpha/naïve/日本 & <tag> \"q\".txt": f(file, "unicode\n"),
		"repos/alpha/nested/deep/dir/file.txt":   f(file, "deep\n"),
		"repos/alpha/nested/" + long:             f(file, "long\n"),
		"repos/alpha/run.sh":                     f(executable, "#!/bin/sh\necho ok\n"),
		"repos/alpha/link":                       "link nested/deep/dir/file.txt",
		"repos/alpha/longlink":                   "link nested/" + long,
		"repos/alpha/nested/up":                  "link ../run.sh",
		"repos/alpha/weird":                      "link x\x1fy\nz",
	}
	for _, d := range []string{".", "beta", "beta/tools", "repos", "repos/alpha", "repos/alpha/bin", "repos/alpha/naïve", "repos/alpha/nested", "repos/alpha/nested/deep", "repos/alpha/nested/deep/dir"} {
		tree[d] = fmt.Sprintf("dir %o", dir)
	}
	return tree
}

func codeFixture(t *testing.T) (*fixture, string) {
	t.Helper()
	read := func(name string) []byte {
		data, err := os.ReadFile(filepath.Join("testdata", name))
		if err != nil {
			t.Fatal(err)
		}
		return data
	}
	raw := read("code-manifest.json")
	var reply struct {
		SnapshotID string `json:"snapshot_id"`
	}
	if err := json.Unmarshal(raw, &reply); err != nil {
		t.Fatal(err)
	}
	return newFixture(t, raw, map[string][]byte{"repos/alpha": read("code-alpha.tar"), "beta": read("code-beta.tar")}), reply.SnapshotID
}

func TestCanonicalManifestMatchesCodeJSON(t *testing.T) {
	raw, err := os.ReadFile("testdata/code-manifest.json")
	if err != nil {
		t.Fatal(err)
	}
	for _, sample := range []string{`\u001F`, `\n`, `\"`, "\u2028", "日本", " & <tag> ", `"github.com/eyra/fixture-alpha"`} {
		if !bytes.Contains(raw, []byte(sample)) {
			t.Fatalf("fixture does not cover %q", sample)
		}
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	var m manifest
	if err = decoder.Decode(&m); err != nil {
		t.Fatal(err)
	}
	// Code's reply is the canonical manifest with snapshot_id among its sorted keys.
	if want := bytes.Replace(raw, []byte(`,"snapshot_id":"`+m.SnapshotID+`"`), nil, 1); !bytes.Equal(m.canonical(), want) {
		t.Fatalf("canonical JSON differs from Code's:\n%s\n%s", m.canonical(), want)
	}
	if sum := sha256.Sum256(m.canonical()); "sha256:"+hex.EncodeToString(sum[:]) != m.SnapshotID {
		t.Fatalf("identity %x differs from %s", sum, m.SnapshotID)
	}
}

func TestMaterializesRealCodeSnapshotWithBaselineAndRecord(t *testing.T) {
	f, id := codeFixture(t)
	hexID := strings.TrimPrefix(id, "sha256:")
	dest := filepath.Join(f.parent, "work")
	result, err := Materialize(f.home, id, dest)
	if err != nil {
		t.Fatal(err)
	}
	baseline := filepath.Join(f.home, "snapshots", hexID)
	repositories, _ := json.Marshal(result["repositories"])
	if result["snapshot_id"] != id || result["destination"] != dest || result["baseline"] != baseline ||
		!strings.Contains(string(repositories), `"path":"beta","repository":"github.com/eyra/fixture-beta"`) {
		t.Fatalf("unexpected result %v %s", result, repositories)
	}
	equal(t, describe(t, dest), codeTree(0644, 0755, 0755))
	equal(t, describe(t, filepath.Join(baseline, "tree")), codeTree(0444, 0555, 0555))
	if strings.HasPrefix(baseline, dest+"/") {
		t.Fatal("baseline is inside the destination")
	}
	stored := mustRead(t, filepath.Join(baseline, "manifest.json"))
	if sum := sha256.Sum256(stored); hex.EncodeToString(sum[:]) != hexID {
		t.Fatal("stored manifest does not hash to the snapshot ID")
	}
	baselineFiles := describe(t, baseline)
	for path := range baselineFiles {
		if strings.HasPrefix(path, "tree/") {
			delete(baselineFiles, path)
		}
	}
	equal(t, baselineFiles, map[string]string{".": "dir 555", "complete": fmt.Sprintf("file 444 %q", id+"\n"), "manifest.json": fmt.Sprintf("file 444 %q", stored), "tree": "dir 555"})
	recordPath := filepath.Join(f.home, "materializations", fmt.Sprintf("%x.json", sha256.Sum256([]byte(dest))))
	var recorded map[string]string
	data := mustRead(t, recordPath)
	if json.Unmarshal(data, &recorded) != nil || recorded["destination"] != dest || recorded["snapshot_id"] != id || recorded["materialized_at"] == "" {
		t.Fatalf("unexpected record %s", data)
	}
	if left, _ := os.ReadDir(f.parent); len(left) != 1 {
		t.Fatalf("staging left behind: %v", left)
	}

	// A second destination reuses the published baseline untouched, sealing it again if a
	// crash between publishing and sealing left it writable.
	if err = os.Chmod(baseline, 0700); err != nil {
		t.Fatal(err)
	}
	before, _ := os.Stat(baseline)
	second := filepath.Join(f.parent, "second")
	if _, err = Materialize(f.home, id, second); err != nil {
		t.Fatal(err)
	}
	after, _ := os.Stat(baseline)
	if !os.SameFile(before, after) {
		t.Fatal("baseline was rebuilt instead of reused")
	} else if after.Mode().Perm() != 0555 {
		t.Fatalf("reused baseline is %o, not read-only", after.Mode().Perm())
	}
	equal(t, describe(t, second), codeTree(0644, 0755, 0755))

	// An existing destination with worker edits is refused and left exactly as it was.
	edited := filepath.Join(dest, "beta", "README.md")
	if err = os.WriteFile(edited, []byte("worker edit\n"), 0644); err != nil {
		t.Fatal(err)
	}
	want := describe(t, dest)
	if _, err = Materialize(f.home, id, dest); err == nil || !strings.Contains(err.Error(), "already exists") {
		t.Fatalf("existing destination: %v", err)
	}
	equal(t, describe(t, dest), want)
	if !bytes.Equal(mustRead(t, recordPath), data) {
		t.Fatal("record changed")
	}

	// So is a symlink, even a dangling one.
	link := filepath.Join(f.parent, "link")
	if err = os.Symlink(filepath.Join(f.parent, "missing"), link); err != nil {
		t.Fatal(err)
	}
	if _, err = Materialize(f.home, id, link); err == nil || !strings.Contains(err.Error(), "already exists") {
		t.Fatalf("existing symlink: %v", err)
	}
	if target, _ := os.Readlink(link); target != filepath.Join(f.parent, "missing") {
		t.Fatal("symlink changed")
	}
	if left, _ := os.ReadDir(f.parent); len(left) != 3 {
		t.Fatalf("staging left behind: %v", left)
	}
	if _, err = Materialize(f.home, id, filepath.Join(f.parent, "missing", "work")); err == nil || !strings.Contains(err.Error(), "destination parent must be an existing directory") {
		t.Fatalf("missing parent: %v", err)
	}
}

func mustRead(t *testing.T, path string) []byte {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func TestPublishingNeverReplacesAPathCreatedMeanwhile(t *testing.T) {
	f, id := codeFixture(t)
	dest := filepath.Join(f.parent, "work")
	// An empty directory is what a plain rename would silently replace.
	f.hook = func(w http.ResponseWriter, r *http.Request) bool {
		if r.URL.Query().Get("path") == "beta" {
			os.Mkdir(dest, 0700)
		}
		return false
	}
	if _, err := Materialize(f.home, id, dest); err == nil || !strings.Contains(err.Error(), "already exists") {
		t.Fatalf("got %v", err)
	}
	if entries, err := os.ReadDir(dest); err != nil || len(entries) != 0 {
		t.Fatalf("destination was replaced: %v %v", entries, err)
	}
	if left, _ := os.ReadDir(f.parent); len(left) != 1 {
		t.Fatalf("staging left behind: %v", left)
	}
}

// Synthetic snapshots: two repositories, a nested executable and a symlink.
var (
	one = repository{Revision: "rev_" + strings.Repeat("a", 64), Path: "one", Repository: "github.com/test/one"}
	two = repository{Revision: "rev_" + strings.Repeat("b", 64), Path: "two", Repository: "github.com/test/two"}
)

func file(r repository, rel, mode, data string) entry {
	sum := sha256.Sum256([]byte(data))
	return entry{Kind: "file", Mode: mode, Path: r.Path + "/" + rel, Repository: r.Repository, SHA256: hex.EncodeToString(sum[:]), Size: int64(len(data))}
}

func symlink(r repository, rel, target string) entry {
	e := file(r, rel, "120000", target)
	e.Kind, e.Target = "symlink", &target
	return e
}

func snapshotOf(t *testing.T, repositories []repository, entries ...entry) (string, []byte) {
	t.Helper()
	m := manifest{Entries: entries, Repositories: repositories, Version: 2}
	sum := sha256.Sum256(m.canonical())
	m.SnapshotID = "sha256:" + hex.EncodeToString(sum[:])
	raw, err := json.Marshal(m)
	if err != nil {
		t.Fatal(err)
	}
	return m.SnapshotID, raw
}

type member struct {
	name     string
	typeflag byte
	mode     int64
	data     string
	link     string
}

func archiveOf(t *testing.T, members ...member) []byte {
	t.Helper()
	var b bytes.Buffer
	w := tar.NewWriter(&b)
	for _, m := range members {
		header := &tar.Header{Name: m.name, Typeflag: m.typeflag, Mode: m.mode, Linkname: m.link, Format: tar.FormatPAX}
		if m.typeflag == tar.TypeReg {
			header.Size = int64(len(m.data))
		}
		if w.WriteHeader(header) != nil {
			t.Fatal("cannot write tar header")
		}
		w.Write([]byte(m.data))
	}
	w.Close()
	return b.Bytes()
}

var (
	synthetic = []entry{file(one, "a.txt", "100644", "alpha"), file(one, "bin/run", "100755", "#!"), symlink(one, "link", "a.txt"), file(two, "b.txt", "100644", "beta")}
	memberA   = member{"a.txt", tar.TypeReg, 0644, "alpha", ""}
	memberRun = member{"bin/run", tar.TypeReg, 0755, "#!", ""}
	memberL   = member{"link", tar.TypeSymlink, 0777, "", "a.txt"}
	memberB   = member{"b.txt", tar.TypeReg, 0644, "beta", ""}
)

func TestSyntheticSnapshotMaterializes(t *testing.T) {
	id, raw := snapshotOf(t, []repository{one, two}, synthetic...)
	f := newFixture(t, raw, map[string][]byte{"one": archiveOf(t, memberA, memberRun, memberL), "two": archiveOf(t, memberB)})
	dest := filepath.Join(f.parent, "work")
	if _, err := Materialize(f.home, id, dest); err != nil {
		t.Fatal(err)
	}
	equal(t, describe(t, dest), map[string]string{".": "dir 755", "one": "dir 755", "one/a.txt": `file 644 "alpha"`, "one/bin": "dir 755",
		"one/bin/run": `file 755 "#!"`, "one/link": "link a.txt", "two": "dir 755", "two/b.txt": `file 644 "beta"`})
}

func TestCorruptArchivesAreRefused(t *testing.T) {
	id, raw := snapshotOf(t, []repository{one, two}, synthetic...)
	for _, test := range []struct {
		name    string
		members []member
		want    string
	}{
		{"member not in manifest", []member{memberA, memberRun, memberL, {"extra", tar.TypeReg, 0644, "x", ""}}, `unexpected or duplicate member "extra"`},
		{"missing member", []member{memberA, memberL}, `archives are missing "one/bin/run"`},
		{"wrong digest", []member{{"a.txt", tar.TypeReg, 0644, "alphA", ""}, memberRun, memberL}, "sha256 differs"},
		{"wrong size", []member{{"a.txt", tar.TypeReg, 0644, "alpha!", ""}, memberRun, memberL}, "size 6 differs"},
		{"wrong mode", []member{{"a.txt", tar.TypeReg, 0755, "alpha", ""}, memberRun, memberL}, "mode 755"},
		{"wrong link target", []member{memberA, memberRun, {"link", tar.TypeSymlink, 0777, "", "bin/run"}}, "symlink target differs"},
		{"hardlink", []member{memberA, memberRun, {"link", tar.TypeLink, 0644, "", "a.txt"}}, "type '1' differs"},
		{"symlink for a file", []member{{"a.txt", tar.TypeSymlink, 0777, "", "link"}, memberRun, memberL}, "type '2' differs"},
		{"directory", []member{{"bin/", tar.TypeDir, 0755, "", ""}, memberA, memberRun, memberL}, `member "bin/"`},
		{"traversal name", []member{memberA, memberRun, memberL, {"../two/b.txt", tar.TypeReg, 0644, "beta", ""}}, `member "../two/b.txt"`},
		{"absolute name", []member{{"/etc/passwd", tar.TypeReg, 0644, "x", ""}, memberA, memberRun, memberL}, `member "/etc/passwd"`},
		{"duplicate member", []member{memberA, memberRun, memberL, memberA}, `unexpected or duplicate member "a.txt"`},
	} {
		t.Run(test.name, func(t *testing.T) {
			f := newFixture(t, raw, map[string][]byte{"one": archiveOf(t, test.members...), "two": archiveOf(t, memberB)})
			f.refused(t, id, test.want)
		})
	}
}

func TestPartialDownloadsLeaveNothing(t *testing.T) {
	id, raw := snapshotOf(t, []repository{one, two}, synthetic...)
	archives := map[string][]byte{"one": archiveOf(t, memberA, memberRun, memberL), "two": archiveOf(t, memberB)}
	t.Run("connection closed mid-archive", func(t *testing.T) {
		f := newFixture(t, raw, archives)
		f.hook = func(w http.ResponseWriter, r *http.Request) bool {
			if r.URL.Query().Get("path") != "two" {
				return false
			}
			w.Header().Set("Content-Length", strconv.Itoa(len(archives["two"])))
			w.Write(archives["two"][:700])
			w.(http.Flusher).Flush()
			panic(http.ErrAbortHandler)
		}
		f.refused(t, id, "unexpected EOF")
	})
	t.Run("second archive fails", func(t *testing.T) {
		f := newFixture(t, raw, archives)
		f.hook = func(w http.ResponseWriter, r *http.Request) bool {
			if r.URL.Query().Get("path") == "two" {
				w.WriteHeader(500)
				return true
			}
			return false
		}
		f.refused(t, id, "Code service unavailable: HTTP 500")
	})
	t.Run("second archive refused", func(t *testing.T) {
		f := newFixture(t, raw, archives)
		f.hook = func(w http.ResponseWriter, r *http.Request) bool {
			if r.URL.Query().Get("path") == "two" {
				codeError(w, 503, "provider_unavailable", "git fetch failed with exit status 128")
				return true
			}
			return false
		}
		f.refused(t, id, "Code refused snapshot "+id+" archive two: 503 provider_unavailable: git fetch failed with exit status 128")
	})
}

func TestUnsafeManifestsAreRefusedBeforeDownloading(t *testing.T) {
	other := two
	other.Repository = one.Repository
	absolute := symlink(one, "abs", "/etc/passwd")
	digestMismatch := symlink(one, "l", "a.txt")
	digestMismatch.SHA256 = strings.Repeat("0", 64)
	fileMode := file(one, "x", "120000", "x")
	for _, test := range []struct {
		name         string
		repositories []repository
		entries      []entry
		want         string
	}{
		{"traversal", []repository{one, two}, []entry{file(one, "../two/x", "100644", "")}, "unsafe manifest entry"},
		{".git", []repository{one}, []entry{file(one, ".git/config", "100644", "")}, "without .git"},
		{".git in any case", []repository{one}, []entry{file(one, "sub/.GiT/hooks/x", "100755", "")}, "without .git"},
		{"control character", []repository{one}, []entry{file(one, "a\x01b", "100644", "")}, "control characters"},
		{"backslash", []repository{one}, []entry{file(one, `a\b`, "100644", "")}, "backslashes"},
		{"outside repositories", []repository{one}, []entry{file(two, "b.txt", "100644", "")}, "outside every repository"},
		{"wrong repository", []repository{one, two}, []entry{file(one, "a", "100644", ""), {Kind: "file", Mode: "100644", Path: "two/b", Repository: one.Repository, SHA256: strings.Repeat("0", 64)}}, "repository does not match"},
		{"overlapping repositories", []repository{one, {Revision: one.Revision, Path: "one/nested", Repository: "github.com/test/nested"}}, nil, "overlapping repository paths"},
		{"same repository path", []repository{one, {Revision: one.Revision, Path: "one", Repository: other.Repository}}, nil, "overlapping repository paths"},
		{"unsafe repository path", []repository{{Revision: one.Revision, Path: "../one", Repository: one.Repository}}, nil, "unsafe repository path"},
		{"duplicate entry", []repository{one}, []entry{file(one, "a", "100644", ""), file(one, "a", "100644", "")}, "duplicate path"},
		{"file and directory", []repository{one}, []entry{file(one, "a", "100644", ""), file(one, "a/b", "100644", "")}, `inside file or symlink "one/a"`},
		{"absolute symlink", []repository{one}, []entry{absolute}, "must be relative"},
		{"escaping symlink", []repository{one, two}, []entry{symlink(one, "l", "../two/b.txt")}, "leaves its repository"},
		{"chained escaping symlink", []repository{one}, []entry{symlink(one, "d/e", ".."), symlink(one, "s", "d/e"), symlink(one, "t", "s/..")}, `"one/t": symlink target "s/.." leaves`},
		{"case-folded chain", []repository{one}, []entry{symlink(one, "d/E", ".."), symlink(one, "s", "d/e"), symlink(one, "t", "s/..")}, "leaves its repository"},
		{"symlink loop", []repository{one}, []entry{symlink(one, "a", "b"), symlink(one, "b", "a")}, "leaves its repository"},
		{"symlink digest", []repository{one}, []entry{digestMismatch}, "does not match its target"},
		{"file with symlink mode", []repository{one}, []entry{fileMode}, "inconsistent"},
		{"unsupported mode", []repository{one}, []entry{file(one, "x", "100664", "")}, "inconsistent"},
		{"no repositories", nil, nil, "no repositories"},
	} {
		t.Run(test.name, func(t *testing.T) {
			id, raw := snapshotOf(t, test.repositories, test.entries...)
			f := newFixture(t, raw, nil)
			f.refused(t, id, test.want)
			if f.archiveHits != 0 {
				t.Fatal("archives were requested")
			}
		})
	}
}

func TestManifestIdentityMismatchIsRefused(t *testing.T) {
	id, raw := snapshotOf(t, []repository{one, two}, synthetic...)
	archives := map[string][]byte{"one": archiveOf(t, memberA, memberRun, memberL), "two": archiveOf(t, memberB)}
	tampered := bytes.Replace(raw, []byte(`"size":5`), []byte(`"size":6`), 1)
	_, other := snapshotOf(t, []repository{one}, synthetic[0])
	for name, manifest := range map[string][]byte{"changed content": tampered, "another snapshot": other} {
		t.Run(name, func(t *testing.T) {
			f := newFixture(t, manifest, archives)
			f.refused(t, id, "snapshot identity mismatch")
			if f.archiveHits != 0 {
				t.Fatal("archives were requested")
			}
		})
	}
}

func TestCodeConnectionErrorsNeverExposeTheToken(t *testing.T) {
	id, raw := snapshotOf(t, []repository{one, two}, synthetic...)
	f := newFixture(t, raw, nil)
	f.refused(t, "sha256:ABC", "snapshot must be sha256:<64 lowercase hex characters>")

	stopped := httptest.NewServer(http.NotFoundHandler())
	stopped.Close()
	f.configure(t, stopped.URL, token)
	f.refused(t, id, "Code service unavailable: Get \""+stopped.URL+"/v1/snapshots/"+id+"/manifest\"")
	f.refused(t, id, "connection refused")

	f.configure(t, "http://localhost:4000", token)
	f.refused(t, id, `code.json must be {"url": "http://127.0.0.1:PORT", "token_file": "/absolute/path"}`)

	server := httptest.NewServer(http.HandlerFunc(f.serve))
	defer server.Close()
	f.configure(t, server.URL, wrongToken)
	f.refused(t, id, "Code refused snapshot "+id+": 401 unauthorized: Missing or wrong bearer token")

	f.configure(t, server.URL, token)
	f.hook = func(w http.ResponseWriter, r *http.Request) bool {
		codeError(w, 404, "not_found", "Snapshot not found")
		return true
	}
	f.refused(t, id, "Code refused snapshot "+id+": 404 not_found: Snapshot not found")

	config, _ := json.Marshal(map[string]string{"url": server.URL, "token_file": filepath.Join(f.home, "absent.token")})
	os.WriteFile(filepath.Join(f.home, "code.json"), config, 0600)
	f.refused(t, id, "Code service unavailable: cannot read token file "+filepath.Join(f.home, "absent.token")+": no such file or directory")

	os.Remove(filepath.Join(f.home, "code.json"))
	f.refused(t, id, "Code service unavailable: not configured; write "+filepath.Join(f.home, "code.json"))
}

func TestCaseCollisionsNeverWriteThroughSymlinks(t *testing.T) {
	probe := t.TempDir()
	if os.WriteFile(filepath.Join(probe, "probe"), nil, 0600) != nil {
		t.Fatal("cannot probe filesystem")
	}
	if _, err := os.Lstat(filepath.Join(probe, "PROBE")); err != nil {
		t.Skip("filesystem is case-sensitive")
	}
	id, raw := snapshotOf(t, []repository{one}, symlink(one, "L", "sub"), file(one, "l/y", "100644", "y"))
	f := newFixture(t, raw, map[string][]byte{"one": archiveOf(t, member{"L", tar.TypeSymlink, 0777, "", "sub"}, member{"l/y", tar.TypeReg, 0644, "y", ""})})
	f.refused(t, id, `cannot create directory "one/l"`)
}
