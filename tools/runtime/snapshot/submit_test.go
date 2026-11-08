package snapshot

import (
	"archive/tar"
	"bytes"
	"crypto/sha1"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"syscall"
	"testing"
)

const changeA = "0b5e1d4c-8f7a-4c2b-9d3e-1a2b3c4d5e6f"

// fakeCode implements the change endpoints of Code's group 6, including its request shape,
// replacement and idempotency rules, closely enough to exercise Submit.
type fakeCode struct {
	base    map[string]map[string]bool // repository → base paths relative to its root
	bodies  map[string][]byte
	entries map[string][]map[string]any
	blobs   map[string][]byte // "<change id>/<sha256>"
	commits map[string]string
	log     []string
	puts    int
	failPut int // the PUT with this 1-based number loses its connection
}

func (c *fakeCode) handle(w http.ResponseWriter, r *http.Request) bool {
	if !strings.HasPrefix(r.URL.Path, "/v1/changes") {
		return false
	}
	body, _ := io.ReadAll(r.Body)
	c.log = append(c.log, r.Method+" "+r.URL.Path)
	parts := strings.Split(r.URL.Path, "/") // "", "v1", "changes", id, "blobs"|"seal", sum
	switch {
	case r.Method == http.MethodPost && len(parts) == 3:
		var request map[string]any
		if json.Unmarshal(body, &request) != nil || len(request) != 5 {
			codeError(w, 400, "invalid_request", "bad body")
			return true
		}
		id, _ := request["change_id"].(string)
		if old, ok := c.bodies[id]; ok {
			if !bytes.Equal(old, body) {
				codeError(w, 409, "conflict", "change_id was already used with a different body")
				return true
			}
		} else {
			var entries []map[string]any
			raw, _ := json.Marshal(request["entries"])
			json.Unmarshal(raw, &entries)
			if why := c.check(request["repository"].(string), entries); why != "" {
				codeError(w, 400, "invalid_request", why)
				return true
			}
			c.bodies[id], c.entries[id] = body, entries
		}
		c.state(w, id)
	case r.Method == http.MethodPut && len(parts) == 6 && parts[4] == "blobs":
		id, sum := parts[3], parts[5]
		if c.puts++; c.puts == c.failPut {
			conn, _, _ := w.(http.Hijacker).Hijack()
			conn.Close()
			return true
		}
		hash := sha256.Sum256(body)
		if !slices.Contains(c.missing(id), sum) && c.blobs[id+"/"+sum] == nil || hex.EncodeToString(hash[:]) != sum {
			codeError(w, 400, "invalid_request", "unexpected blob")
			return true
		}
		c.blobs[id+"/"+sum] = body
		c.state(w, id)
	case r.Method == http.MethodPost && len(parts) == 5 && parts[4] == "seal":
		id := parts[3]
		if len(c.missing(id)) > 0 {
			codeError(w, 422, "incomplete_upload", "Upload every blob before sealing")
			return true
		}
		if c.commits[id] == "" {
			sum := sha1.Sum(c.bodies[id])
			c.commits[id] = hex.EncodeToString(sum[:])
		}
		c.state(w, id)
	default:
		codeError(w, 404, "not_found", "Unknown path")
	}
	return true
}

// check applies Code's entry shape, uniqueness, delete and explicit-replacement rules.
func (c *fakeCode) check(repository string, entries []map[string]any) string {
	tree, writes := map[string]bool{}, []string{}
	for path := range c.base[repository] {
		tree[path] = true
	}
	seen := map[string]bool{}
	for _, e := range entries {
		path := e["path"].(string)
		switch {
		case seen[path]:
			return "duplicate " + path
		case e["op"] == "delete" && (len(e) != 2 || !c.base[repository][path]):
			return "bad delete " + path
		case e["op"] == "write" && !(e["kind"] == "file" && len(e) == 6 || e["kind"] == "symlink" && len(e) == 7):
			return "bad write " + path
		}
		seen[path] = true
		if e["op"] == "delete" {
			delete(tree, path)
		} else {
			writes = append(writes, path)
		}
	}
	for _, path := range writes {
		tree[path] = true
	}
	for _, path := range writes {
		for dir := parent(path); dir != ""; dir = parent(dir) {
			if tree[dir] {
				return "write under file " + path
			}
		}
		for other := range tree {
			if strings.HasPrefix(other, path+"/") {
				return "write over directory " + path
			}
		}
	}
	return ""
}

func (c *fakeCode) missing(id string) []string {
	missing := []string{}
	for _, e := range c.entries[id] {
		sum, _ := e["sha256"].(string)
		if _, ok := c.blobs[id+"/"+sum]; e["kind"] == "file" && !ok && !slices.Contains(missing, sum) {
			missing = append(missing, sum)
		}
	}
	slices.Sort(missing)
	return missing
}

func (c *fakeCode) state(w http.ResponseWriter, id string) {
	reply := map[string]any{"change_id": id, "state": "open", "missing": c.missing(id)}
	if commit := c.commits[id]; commit != "" {
		reply["state"], reply["missing"], reply["commit"] = "sealed", []string{}, commit
	}
	json.NewEncoder(w).Encode(reply)
}

// submitFixture materializes repository one with members, and two with b.txt when both is set.
func submitFixture(t *testing.T, both bool, members ...member) (*fixture, *fakeCode, string, string) {
	t.Helper()
	repositories, entries := []repository{one}, []entry{}
	code := &fakeCode{base: map[string]map[string]bool{one.Repository: {}, two.Repository: {"b.txt": true}}, bodies: map[string][]byte{}, entries: map[string][]map[string]any{}, blobs: map[string][]byte{}, commits: map[string]string{}}
	for _, m := range members {
		code.base[one.Repository][m.name] = true
		switch {
		case m.typeflag == tar.TypeSymlink:
			entries = append(entries, symlink(one, m.name, m.link))
		case m.mode&0111 != 0:
			entries = append(entries, file(one, m.name, "100755", m.data))
		default:
			entries = append(entries, file(one, m.name, "100644", m.data))
		}
	}
	archives := map[string][]byte{"one": archiveOf(t, members...)}
	if both {
		repositories, entries, archives["two"] = append(repositories, two), append(entries, file(two, "b.txt", "100644", "beta")), archiveOf(t, memberB)
	}
	id, raw := snapshotOf(t, repositories, entries...)
	f := newFixture(t, raw, archives)
	dest := filepath.Join(f.parent, "work")
	_, err := Materialize(f.home, id, dest)
	must(t, err)
	f.hook = code.handle
	return f, code, id, dest
}

func written(path, mode, data string) map[string]any {
	sum := sha256.Sum256([]byte(data))
	return map[string]any{"path": path, "op": "write", "kind": "file", "mode": mode, "size": float64(len(data)), "sha256": hex.EncodeToString(sum[:])}
}

func linked(path, target string) map[string]any {
	e := written(path, "120000", target)
	e["kind"], e["target"] = "symlink", target
	return e
}

func deleted(path string) map[string]any { return map[string]any{"path": path, "op": "delete"} }

func reg(name string, mode int64, data string) member {
	return member{name, tar.TypeReg, mode, data, ""}
}

func lnk(name, target string) member { return member{name, tar.TypeSymlink, 0777, "", target} }

func noTemporaries(t *testing.T, home string) {
	t.Helper()
	if left, _ := os.ReadDir(filepath.Join(home, "submissions")); len(left) != 0 {
		t.Fatalf("submission temporaries left: %v", left)
	}
}

func TestSubmitConvertsEveryChangeKindAndSeals(t *testing.T) {
	f, code, id, dest := submitFixture(t, true,
		reg("a.txt", 0644, "alpha\n"), reg("data.bin", 0644, "\x00\x01"), reg("gone.txt", 0644, "gone\n"), reg("run.sh", 0755, "#!/bin/sh\n"),
		lnk("link", "a.txt"), reg("became-dir", 0644, "x\n"), reg("dir/one", 0644, "1\n"), reg("dir/two", 0644, "2\n"), reg("tolink", 0644, "t\n"),
		lnk("linkfile", "a.txt"), lnk("linkdir", "a.txt"), reg("unchanged.txt", 0644, "same\n"))
	at := func(path string) string { return filepath.Join(dest, "one", path) }
	must(t, os.WriteFile(at("a.txt"), []byte("alpha\nbeta\n"), 0644))
	must(t, os.WriteFile(at("data.bin"), []byte("\x00\xff\x10"), 0644))
	must(t, os.Remove(at("gone.txt")))
	must(t, os.Chmod(at("run.sh"), 0644))
	must(t, os.Remove(at("link")))
	must(t, os.Symlink("data.bin", at("link")))
	must(t, os.Remove(at("became-dir")))
	must(t, os.MkdirAll(at("became-dir"), 0755))
	must(t, os.WriteFile(at("became-dir/inner"), []byte("in\n"), 0644))
	must(t, os.RemoveAll(at("dir")))
	must(t, os.WriteFile(at("dir"), []byte("now a file\n"), 0644))
	must(t, os.Remove(at("tolink")))
	must(t, os.Symlink("a.txt", at("tolink")))
	must(t, os.Remove(at("linkfile")))
	must(t, os.WriteFile(at("linkfile"), []byte("lf\n"), 0644))
	must(t, os.Remove(at("linkdir")))
	must(t, os.MkdirAll(at("linkdir"), 0755))
	must(t, os.WriteFile(at("linkdir/f"), []byte("f\n"), 0644))
	must(t, os.MkdirAll(at("new/empty"), 0755))
	must(t, os.WriteFile(at("new/file.txt"), []byte("hello\n"), 0644))
	must(t, os.WriteFile(at("new/tool"), []byte("#!t\n"), 0755))
	must(t, os.Symlink("new/file.txt", at("alias")))
	must(t, os.WriteFile(filepath.Join(dest, "two", "b.txt"), []byte("BETA\n"), 0644))
	baseline := filepath.Join(f.home, "snapshots", strings.TrimPrefix(id, "sha256:"))
	before := state(t, dest, baseline)

	result, err := Submit(f.home, dest, "one", changeA)
	must(t, err)
	want := []map[string]any{
		written("a.txt", "100644", "alpha\nbeta\n"),
		linked("alias", "new/file.txt"),
		deleted("became-dir"),
		written("became-dir/inner", "100644", "in\n"),
		written("data.bin", "100644", "\x00\xff\x10"),
		written("dir", "100644", "now a file\n"),
		deleted("dir/one"),
		deleted("dir/two"),
		deleted("gone.txt"),
		linked("link", "data.bin"),
		deleted("linkdir"),
		written("linkdir/f", "100644", "f\n"),
		written("linkfile", "100644", "lf\n"),
		written("new/file.txt", "100644", "hello\n"),
		written("new/tool", "100755", "#!t\n"),
		written("run.sh", "100644", "#!/bin/sh\n"),
		linked("tolink", "a.txt"),
	}
	if !reflect.DeepEqual(code.entries[changeA], want) {
		t.Fatalf("entries:\n%v\nwant\n%v", code.entries[changeA], want)
	}
	var request map[string]any
	must(t, json.Unmarshal(code.bodies[changeA], &request))
	delete(request, "entries")
	if !reflect.DeepEqual(request, map[string]any{"change_id": changeA, "snapshot_id": id, "repository": one.Repository, "base_commit": one.Commit}) {
		t.Fatalf("request: %v", request)
	}
	commit := code.commits[changeA]
	if !reflect.DeepEqual(result, map[string]any{"snapshot_id": id, "repository": one.Repository, "path": "one", "base_commit": one.Commit, "change_id": changeA, "state": "sealed", "commit": commit}) || len(commit) != 40 {
		t.Fatalf("result: %v", result)
	}
	// Every file write was uploaded once with its exact bytes (the fake verifies each digest); links never are.
	if puts := len(code.log) - 2; puts != 9 || len(code.missing(changeA)) != 0 {
		t.Fatalf("log: %v", code.log)
	}
	if string(code.blobs[changeA+"/"+want[4]["sha256"].(string)]) != "\x00\xff\x10" {
		t.Fatal("binary blob differs")
	}
	equal(t, state(t, dest, baseline), before)
	noTemporaries(t, f.home)

	// The other repository is untouched by that change and submits on its own.
	result, err = Submit(f.home, dest, "two", "1b5e1d4c-8f7a-4c2b-9d3e-1a2b3c4d5e6f")
	must(t, err)
	if result["repository"] != two.Repository || result["base_commit"] != two.Commit || result["state"] != "sealed" ||
		!reflect.DeepEqual(code.entries["1b5e1d4c-8f7a-4c2b-9d3e-1a2b3c4d5e6f"], []map[string]any{written("b.txt", "100644", "BETA\n")}) {
		t.Fatalf("two: %v %v", result, code.entries)
	}
}

func TestCleanRepositoryMakesNoRequest(t *testing.T) {
	f, code, id, dest := submitFixture(t, false, memberA, memberRun, memberL)
	must(t, os.Remove(filepath.Join(f.home, "code.json"))) // not even Code's configuration is read
	result, err := Submit(f.home, dest, "", changeA)
	must(t, err)
	if !reflect.DeepEqual(result, map[string]any{"snapshot_id": id, "repository": one.Repository, "path": "one", "base_commit": one.Commit, "change_id": changeA, "state": "clean", "commit": nil}) || len(code.log) != 0 {
		t.Fatalf("got %v, log %v", result, code.log)
	}
}

func TestRepeatResumesAPartialUploadAndReturnsTheSameCommit(t *testing.T) {
	f, code, _, dest := submitFixture(t, false, memberA, memberRun, memberL)
	at := func(path string) string { return filepath.Join(dest, "one", path) }
	must(t, os.WriteFile(at("a.txt"), []byte("changed"), 0644))
	must(t, os.WriteFile(at("b.txt"), []byte("new b"), 0644))
	must(t, os.WriteFile(at("c.txt"), []byte("new c"), 0644))
	code.failPut = 2

	_, err := Submit(f.home, dest, "one", changeA)
	if err == nil || !strings.HasPrefix(err.Error(), "Code service unavailable: ") ||
		!strings.HasSuffix(err.Error(), "; change "+changeA+" is not confirmed sealed and nothing was published: repeat the same command with --change-id "+changeA+" to resume") ||
		strings.Contains(err.Error(), token) {
		t.Fatalf("got %v", err)
	}
	if len(code.log) != 3 || code.commits[changeA] != "" || len(code.missing(changeA)) != 2 {
		t.Fatalf("log %v", code.log)
	}
	noTemporaries(t, f.home)

	missing := code.missing(changeA)
	code.log = nil
	result, err := Submit(f.home, dest, "one", changeA)
	must(t, err)
	wantLog := []string{"POST /v1/changes", "PUT /v1/changes/" + changeA + "/blobs/" + missing[0], "PUT /v1/changes/" + changeA + "/blobs/" + missing[1], "POST /v1/changes/" + changeA + "/seal"}
	commit := code.commits[changeA]
	if !reflect.DeepEqual(code.log, wantLog) || result["state"] != "sealed" || result["commit"] != commit || commit == "" {
		t.Fatalf("got %v, log %v", result, code.log)
	}

	// A sealed change returns its commit without uploading or sealing again.
	code.log = nil
	result, err = Submit(f.home, dest, "one", changeA)
	must(t, err)
	if !reflect.DeepEqual(code.log, []string{"POST /v1/changes"}) || result["commit"] != commit {
		t.Fatalf("got %v, log %v", result, code.log)
	}

	// Different content under the same ID is Code's conflict, without a resume hint.
	must(t, os.WriteFile(at("a.txt"), []byte("changed again"), 0644))
	_, err = Submit(f.home, dest, "one", changeA)
	if err == nil || err.Error() != "Code refused change "+changeA+": 409 conflict: change_id was already used with a different body" {
		t.Fatalf("got %v", err)
	}
}

func TestUnavailableCodeIsNotSuccess(t *testing.T) {
	f, _, _, dest := submitFixture(t, false, memberA)
	must(t, os.WriteFile(filepath.Join(dest, "one", "a.txt"), []byte("changed"), 0644))
	f.configure(t, "http://127.0.0.1:1", token)
	result, err := Submit(f.home, dest, "one", changeA)
	if err == nil || !strings.HasPrefix(err.Error(), "Code service unavailable: ") || !strings.Contains(err.Error(), "to resume") || strings.Contains(err.Error(), token) {
		t.Fatalf("got %v, %v", result, err)
	}
	noTemporaries(t, f.home)
}

func TestUnrepresentableChangesAreRefusedBeforeSending(t *testing.T) {
	for _, test := range []struct {
		name, path, id string
		edit, during   func(t *testing.T, at func(string) string)
		want           string
	}{
		{"FIFO added", "one", changeA, func(t *testing.T, at func(string) string) {
			must(t, syscall.Mkfifo(at("one/pipe"), 0644))
		}, nil, "cannot submit one/pipe: only files, symlinks and directories can be submitted, not a FIFO, socket or device"},
		{"file replaced by a FIFO", "one", changeA, func(t *testing.T, at func(string) string) {
			must(t, os.Remove(at("one/a.txt")))
			must(t, syscall.Mkfifo(at("one/a.txt"), 0644))
		}, nil, "cannot submit one/a.txt: only files"},
		{"blob over the limit", "one", changeA, func(t *testing.T, at func(string) string) {
			maxBlob = 8
			t.Cleanup(func() { maxBlob = 64 << 20 })
			must(t, os.WriteFile(at("one/big"), []byte("123456789"), 0644))
		}, nil, "cannot submit one/big: is larger than Code's blob limit of 8 bytes"},
		{".git path", "one", changeA, func(t *testing.T, at func(string) string) {
			must(t, os.MkdirAll(at("one/.git"), 0755))
			must(t, os.WriteFile(at("one/.git/config"), []byte("[core]\n"), 0644))
		}, nil, "cannot submit one/.git/config: path must be relative and normalized, without .git"},
		{"symlink leaving the repository", "one", changeA, func(t *testing.T, at func(string) string) {
			must(t, os.Symlink("../two/b.txt", at("one/out")))
		}, nil, `cannot submit one/out: symlink target "../two/b.txt" leaves the repository`},
		{"absolute symlink", "one", changeA, func(t *testing.T, at func(string) string) {
			must(t, os.Remove(at("one/link")))
			must(t, os.Symlink("/etc/passwd", at("one/link")))
		}, nil, "cannot submit one/link: symlink target must be relative and nonempty"},
		{"repository folder replaced by a symlink", "one", changeA, func(t *testing.T, at func(string) string) {
			must(t, os.Rename(at("one"), at("moved")))
			must(t, os.Symlink("moved", at("one")))
		}, nil, "cannot submit one: the repository folder itself is no longer a directory"},
		{"folder changed during submission", "one", changeA, func(t *testing.T, at func(string) string) {
			must(t, os.WriteFile(at("one/a.txt"), []byte("first"), 0644))
		}, func(t *testing.T, at func(string) string) {
			must(t, os.WriteFile(at("one/a.txt"), []byte("second"), 0644))
		}, "changed during submission; nothing was sent to Code, run the command again"},
		{"several repositories need --path", "", changeA, func(*testing.T, func(string) string) {}, nil, `--path is required: `},
		{"unknown path", "three", changeA, func(*testing.T, func(string) string) {}, nil, `--path "three" is not a materialized repository path`},
		{"invalid change ID", "one", strings.ToUpper(changeA), func(*testing.T, func(string) string) {}, nil, "change ID must be a lowercase UUID"},
	} {
		t.Run(test.name, func(t *testing.T) {
			f, code, id, dest := submitFixture(t, true, memberA, memberRun, memberL)
			at := func(path string) string { return filepath.Join(dest, path) }
			test.edit(t, at)
			baseline := filepath.Join(f.home, "snapshots", strings.TrimPrefix(id, "sha256:"))
			// Reading a FIFO to describe the folder would block, so those cases compare the baseline only.
			fifo := strings.Contains(test.name, "FIFO")
			before, base := map[string]string{}, state(t, baseline)
			if !fifo {
				before = state(t, dest)
			}
			if test.during != nil {
				afterCapture = func() { test.during(t, at) }
				t.Cleanup(func() { afterCapture = func() {} })
			}
			result, err := Submit(f.home, dest, test.path, test.id)
			if err == nil || !strings.Contains(err.Error(), test.want) || strings.Contains(err.Error(), token) {
				t.Fatalf("got %v, %v; want error containing %q", result, err, test.want)
			}
			if len(code.log) != 0 {
				t.Fatalf("Code was called: %v", code.log)
			}
			if test.during == nil && !fifo {
				equal(t, state(t, dest), before)
			}
			equal(t, state(t, baseline), base)
			noTemporaries(t, f.home)
		})
	}
}

// A repository below another folder is hidden from the walk when that folder is replaced, which
// must refuse instead of submitting the repository's base files as deletions.
func TestReplacedRepositoryAncestorIsRefused(t *testing.T) {
	nested := repository{Commit: strings.Repeat("c", 40), Path: "x/app", Repository: "github.com/test/app"}
	setup := func(t *testing.T) (*fixture, *fakeCode, string, string) {
		t.Helper()
		id, raw := snapshotOf(t, []repository{nested, two}, file(nested, "a.txt", "100644", "alpha"), file(two, "b.txt", "100644", "beta"))
		f := newFixture(t, raw, map[string][]byte{"x/app": archiveOf(t, memberA), "two": archiveOf(t, memberB)})
		dest := filepath.Join(f.parent, "work")
		_, err := Materialize(f.home, id, dest)
		must(t, err)
		code := &fakeCode{base: map[string]map[string]bool{nested.Repository: {"a.txt": true}, two.Repository: {"b.txt": true}}, bodies: map[string][]byte{}, entries: map[string][]map[string]any{}, blobs: map[string][]byte{}, commits: map[string]string{}}
		f.hook = code.handle
		return f, code, id, dest
	}
	for _, test := range []struct {
		name    string
		replace func(t *testing.T, x string)
	}{
		{"file", func(t *testing.T, x string) { must(t, os.WriteFile(x, []byte("now a file\n"), 0644)) }},
		{"symlink to a matching folder", func(t *testing.T, x string) {
			must(t, os.Rename(x, x+"-moved"))
			must(t, os.Symlink("x-moved", x))
		}},
		{"dangling symlink", func(t *testing.T, x string) { must(t, os.Symlink("missing", x)) }},
	} {
		t.Run(test.name, func(t *testing.T) {
			f, code, id, dest := setup(t)
			x := filepath.Join(dest, "x")
			if !strings.HasPrefix(test.name, "symlink") {
				must(t, os.RemoveAll(x))
			}
			test.replace(t, x)
			baseline := filepath.Join(f.home, "snapshots", strings.TrimPrefix(id, "sha256:"))
			before, base := state(t, dest), state(t, baseline)
			result, err := Submit(f.home, dest, "x/app", changeA)
			if err == nil || !strings.Contains(err.Error(), "cannot submit x/app: its folder x is no longer a directory") {
				t.Fatalf("got %v, %v", result, err)
			}
			if len(code.log) != 0 {
				t.Fatalf("Code was called: %v", code.log)
			}
			equal(t, state(t, dest), before)
			equal(t, state(t, baseline), base)
			noTemporaries(t, f.home)

			// The other repository does not depend on that folder and still submits.
			must(t, os.WriteFile(filepath.Join(dest, "two", "b.txt"), []byte("BETA\n"), 0644))
			result, err = Submit(f.home, dest, "two", changeA)
			must(t, err)
			if result["state"] != "sealed" || !reflect.DeepEqual(code.entries[changeA], []map[string]any{written("b.txt", "100644", "BETA\n")}) {
				t.Fatalf("two: %v %v", result, code.entries)
			}
		})
	}

	t.Run("valid nested repository", func(t *testing.T) {
		f, code, _, dest := setup(t)
		must(t, os.WriteFile(filepath.Join(dest, "x", "app", "a.txt"), []byte("changed"), 0644))
		must(t, os.WriteFile(filepath.Join(dest, "x", "outside.txt"), []byte("ignored by --path"), 0644))
		result, err := Submit(f.home, dest, "x/app", changeA)
		must(t, err)
		if result["state"] != "sealed" || !reflect.DeepEqual(code.entries[changeA], []map[string]any{written("a.txt", "100644", "changed")}) {
			t.Fatalf("got %v %v", result, code.entries)
		}
	})

	t.Run("missing ancestor still deletes the repository's files", func(t *testing.T) {
		f, code, _, dest := setup(t)
		must(t, os.RemoveAll(filepath.Join(dest, "x")))
		result, err := Submit(f.home, dest, "x/app", changeA)
		must(t, err)
		if result["state"] != "sealed" || !reflect.DeepEqual(code.entries[changeA], []map[string]any{deleted("a.txt")}) {
			t.Fatalf("got %v %v", result, code.entries)
		}
	})
}
