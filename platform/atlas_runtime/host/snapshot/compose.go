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
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"syscall"
)

var (
	// workFolder is the one name a composed folder may have inside the Runtime home, directly in
	// <home>/workers: work-<name>, <name> with the charset of a Runtime work or slot id.
	workFolder = regexp.MustCompile(`^work-[a-z][a-z0-9_-]{0,63}$`)
	// maxChangeSet bounds the change set file Compose reads.
	maxChangeSet int64 = 256 << 20
)

// changeSetFile is a change set as snapshot changes reports it and the Runtime keeps it.
type changeSetFile struct {
	Base  string `json:"base"`
	Roots []struct {
		Root    string            `json:"root"`
		Entries []json.RawMessage `json:"entries"`
	} `json:"roots"`
}

// Compose builds the new folder dest from the baseline of snapshot id, kept under
// <home>/snapshots/<hex>/tree, plus exactly the entries of the change set in the file changeSet,
// whose base must be id. Every written file's content comes from blobs/<sha256> and is checked
// against the entry's size and sha256. With readOnly, files lose their write bits and directories
// are 0555. dest is published by an exclusive rename and recorded as a materialization of id, so
// its later changes are relative to the same baseline. Inside the Runtime home only
// <home>/workers/work-<name> is accepted. It never contacts Code or runs Git.
func Compose(home, id, changeSet, blobs, dest string, readOnly bool) (map[string]any, error) {
	home, err := canonicalDirectory(home)
	if err != nil {
		return nil, fail("io", err)
	}
	match := snapshotID.FindStringSubmatch(id)
	if match == nil {
		return nil, failf("baseline_missing", "base ID must be sha256:<64 lowercase hex characters>, not %q", id)
	}
	baseline := filepath.Join(home, "snapshots", match[1])
	m, base, err := loadBaseline(baseline, id)
	if err != nil {
		return nil, failf("baseline_missing", "no usable baseline for %s under %s: %v", id, filepath.Join(home, "snapshots"), err)
	}
	wanted, err := readChangeSet(changeSet, id, m, base)
	if err != nil {
		return nil, err
	}
	if dest, err = composeDestination(home, dest); err != nil {
		return nil, err
	}

	// Private staging next to dest, so publishing is a rename on one filesystem.
	staging, err := os.MkdirTemp(filepath.Dir(dest), ".atlas-snapshot-*")
	if err != nil {
		return nil, fail("io", err)
	}
	defer remove(staging)
	t, err := newTree(filepath.Join(staging, "tree"), readOnly)
	if err != nil {
		return nil, fail("io", err)
	}
	for _, r := range m.Repositories {
		if err = t.mkdirs(r.Path); err != nil {
			return nil, fail("io", err)
		}
	}
	paths := make([]string, 0, len(wanted))
	for path := range wanted {
		paths = append(paths, path)
	}
	slices.Sort(paths)
	for _, path := range paths {
		e := wanted[path]
		switch {
		case e.Kind == "symlink":
			err = t.symlink(path, *e.Target)
			if err != nil {
				err = fail("io", err)
			}
		case base[path] == e:
			err = t.copyBase(path, filepath.Join(baseline, "tree", filepath.FromSlash(path)), e)
		default:
			err = t.copyBlob(path, blobs, e)
		}
		if err != nil {
			return nil, err
		}
	}
	if err = t.finish(); err != nil {
		return nil, fail("io", err)
	}
	if err = t.publish(dest); err != nil {
		return nil, err
	}
	// The folder is the caller's now: a failed record is reported, never cleaned up.
	if err = record(home, dest, id); err != nil {
		return nil, failf("io", "published %s but could not record its snapshot: %v", dest, err)
	}
	return map[string]any{"snapshot_id": id, "destination": dest, "read_only": readOnly}, nil
}

// readChangeSet reads the change set file name against snapshot id's manifest m and returns the
// composed folder's content: every baseline entry the change set keeps, with its writes, by path.
func readChangeSet(name, id string, m *manifest, base map[string]*entry) (map[string]*entry, error) {
	invalid := func(format string, args ...any) error {
		return failf("invalid_change_set", "invalid change set %s: "+format, append([]any{name}, args...)...)
	}
	file, err := os.Open(name)
	if err != nil {
		return nil, failf("io", "cannot read change set %s: %v", name, reason(err))
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, maxChangeSet+1))
	if err != nil {
		return nil, failf("io", "cannot read change set %s: %v", name, reason(err))
	}
	if int64(len(data)) > maxChangeSet {
		return nil, invalid("larger than %d bytes", maxChangeSet)
	}
	var set changeSetFile
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err = decoder.Decode(&set); err != nil || decoder.More() {
		return nil, invalid("not a change set object: %v", err)
	}
	if set.Base != id {
		return nil, invalid("its base %q is not %s", set.Base, id)
	}

	result := make(map[string]*entry, len(base))
	for path, e := range base {
		result[path] = e
	}
	roots := map[string]bool{}
	for _, root := range set.Roots {
		r := owner(m.Repositories, root.Root)
		if r == nil || r.Path != root.Root {
			return nil, invalid("root %q is not a repository path of %s", root.Root, id)
		}
		if roots[root.Root] {
			return nil, invalid("duplicate root %q", root.Root)
		}
		roots[root.Root] = true
		seen := map[string]bool{}
		for _, raw := range root.Entries {
			e, op, err := changeSetEntry(raw)
			if err != nil {
				return nil, invalid("root %q: %v", root.Root, err)
			}
			if !safe(e.Path) || seen[e.Path] {
				return nil, invalid("root %q: unsafe or duplicate path %q", root.Root, e.Path)
			}
			seen[e.Path] = true
			full := root.Root + "/" + e.Path
			if op == "delete" {
				if was := base[full]; was == nil || !within(root.Root, was.Path) {
					return nil, invalid("root %q: deletes %q, which the baseline does not hold", root.Root, e.Path)
				}
				delete(result, full)
				continue
			}
			e.Path, e.Repository = full, r.Repository
			if why := e.problem(r.Path); why != "" {
				return nil, invalid("root %q: entry %q: %s", root.Root, full, why)
			}
			result[full] = e
		}
	}

	// The result must be a tree a manifest could describe: nothing inside a file or symlink, and
	// every symlink resolving inside its repository through the others, as Materialize requires.
	links, folded := map[string]string{}, map[string]string{}
	for path, e := range result {
		if e.Target == nil {
			continue
		}
		links[path] = *e.Target
		if _, ok := folded[strings.ToLower(path)]; ok {
			folded[strings.ToLower(path)] = "\x00"
		} else {
			folded[strings.ToLower(path)] = *e.Target
		}
	}
	for path, e := range result {
		root := owner(m.Repositories, path).Path
		for dir := parent(path); len(dir) > len(root); dir = parent(dir) {
			if result[dir] != nil {
				return nil, invalid("entry %q lies inside file or symlink %q", path, dir)
			}
		}
		if e.Target != nil && !resolvesInside(links, folded, root, path, *e.Target) {
			return nil, invalid("symlink %q with target %q leaves its repository or loops", path, *e.Target)
		}
	}
	return result, nil
}

// changeSetEntry decodes one entry with exactly the keys its op and kind have: a delete is
// {path, op}; a write has kind, mode, size and sha256, and target only for a symlink.
func changeSetEntry(raw json.RawMessage) (*entry, string, error) {
	var keys map[string]json.RawMessage
	if err := json.Unmarshal(raw, &keys); err != nil {
		return nil, "", fmt.Errorf("entry is not an object: %v", err)
	}
	var c changeEntry
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&c); err != nil {
		return nil, "", fmt.Errorf("invalid entry %s: %v", raw, err)
	}
	want := []string{"path", "op"}
	switch c.Op {
	case "delete":
	case "write":
		want = append(want, "kind", "mode", "size", "sha256")
		if c.Kind == "symlink" {
			want = append(want, "target")
		}
	default:
		return nil, "", fmt.Errorf("entry %s: op must be write or delete", raw)
	}
	got := []string{}
	for key := range keys {
		got = append(got, key)
	}
	slices.Sort(got)
	slices.Sort(want)
	if !slices.Equal(got, want) {
		return nil, "", fmt.Errorf("entry %s: a %s %s has exactly the keys %q", raw, c.Kind, c.Op, want)
	}
	return &entry{Kind: c.Kind, Mode: c.Mode, Path: c.Path, SHA256: c.SHA256, Size: c.Size, Target: c.Target}, c.Op, nil
}

// composeDestination is dest's absolute path below its resolved parent. Of all paths that are or
// lie inside the Runtime home, only <home>/workers/work-<name> is accepted; an existing dest is refused.
func composeDestination(home, dest string) (string, error) {
	dest, err := filepath.Abs(dest)
	if err != nil {
		return "", fail("io", err)
	}
	// The kernel's paths, with every symlink resolved: a path through a symlink or another
	// spelling of the home is compared as the home it reaches.
	parent, err := canonicalDirectory(filepath.Dir(dest))
	if err != nil {
		return "", failf("io", "destination parent must be an existing directory: %v", err)
	}
	dest = filepath.Join(parent, filepath.Base(dest))
	if insideHome(home, parent, dest) && (parent != filepath.Join(home, "workers") || !workFolder.MatchString(filepath.Base(dest))) {
		return "", failf("destination_not_allowed", "destination %s lies inside the Runtime home %s; only %s is accepted there",
			dest, home, filepath.Join(home, "workers", "work-<name>"))
	}
	if _, err = os.Lstat(dest); err == nil {
		return "", failf("destination_exists", "destination %s already exists", dest)
	} else if !errors.Is(err, fs.ErrNotExist) {
		return "", fail("io", err)
	}
	return dest, nil
}

// insideHome reports whether dest, below its canonical parent, is or lies inside the canonical
// home. Names are also compared case-insensitively, and every ancestor that can be examined is
// compared with the home as a file, so another spelling of the home never counts as outside.
func insideHome(home, parent, dest string) bool {
	if within(home, dest) || within(strings.ToLower(home), strings.ToLower(dest)) {
		return true
	}
	info, err := os.Stat(home)
	if err != nil {
		return true // a home that cannot be examined is never assumed to be elsewhere
	}
	for dir := parent; ; dir = filepath.Dir(dir) {
		if other, err := os.Stat(dir); err == nil && os.SameFile(info, other) {
			return true
		}
		if dir == filepath.Dir(dir) {
			return false
		}
	}
}

// copyBase copies the baseline file name, which holds the kept entry e, into the tree at path:
// an APFS clone or, where the filesystem cannot clone, a streamed copy, with e's mode.
func (t *tree) copyBase(path, name string, e *entry) error {
	if err := t.mkdirs(parent(path)); err != nil {
		return fail("io", err)
	}
	out := filepath.Join(t.root, filepath.FromSlash(path))
	err := cloneFile(name, out)
	if errors.Is(err, syscall.ENOTSUP) || errors.Is(err, syscall.EOPNOTSUPP) || errors.Is(err, syscall.EXDEV) {
		_, err = t.stream(path, name)
	}
	if err != nil {
		return failf("io", "cannot copy baseline file %s: %v", path, err)
	}
	if info, err := os.Lstat(out); err != nil || !info.Mode().IsRegular() {
		return failf("io", "baseline file %s is not a regular file", path)
	}
	return chmodEntry(out, t, e)
}

// copyBlob copies blobs/<sha256> of the written entry e into the tree at path, as a clone where
// possible, and checks the copy's size and sha256 against e: a wrong or missing blob is refused.
func (t *tree) copyBlob(path, blobs string, e *entry) error {
	if err := t.mkdirs(parent(path)); err != nil {
		return fail("io", err)
	}
	name := filepath.Join(blobs, e.SHA256)
	out := filepath.Join(t.root, filepath.FromSlash(path))
	err := cloneFile(name, out)
	if errors.Is(err, syscall.ENOTSUP) || errors.Is(err, syscall.EOPNOTSUPP) || errors.Is(err, syscall.EXDEV) {
		err = t.streamBlob(path, name)
	}
	if errors.Is(err, fs.ErrNotExist) {
		return failf("blob_mismatch", "blob %s of %s is missing from %s", e.SHA256, path, blobs)
	} else if err != nil {
		return failf("io", "cannot copy blob %s of %s: %v", e.SHA256, path, err)
	}
	// The copy itself is checked, so what was checked is exactly what the folder holds.
	copied, err := os.OpenFile(out, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if err != nil {
		return failf("blob_mismatch", "blob %s of %s is not a regular file", e.SHA256, path)
	}
	defer copied.Close()
	info, err := copied.Stat()
	if err != nil {
		return fail("io", err)
	}
	if !info.Mode().IsRegular() {
		return failf("blob_mismatch", "blob %s of %s is not a regular file", e.SHA256, path)
	}
	hash := sha256.New()
	size, err := io.Copy(hash, copied)
	if err != nil {
		return fail("io", err)
	}
	if size != e.Size || hex.EncodeToString(hash.Sum(nil)) != e.SHA256 {
		return failf("blob_mismatch", "blob %s of %s holds %d bytes with sha256 %x, not %d bytes with that sha256", e.SHA256, path, size, hash.Sum(nil), e.Size)
	}
	return chmodEntry(out, t, e)
}

// streamBlob copies the blob name into the tree at path without following a symlink.
func (t *tree) streamBlob(path, name string) error {
	source, err := os.OpenFile(name, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if err != nil {
		return err
	}
	defer source.Close()
	out, err := t.create(path)
	if err != nil {
		return err
	}
	_, err = io.Copy(out, source)
	if cerr := out.Close(); err == nil {
		err = cerr
	}
	return err
}

// chmodEntry gives the file out the mode of entry e, without write bits in a read-only tree.
func chmodEntry(out string, t *tree, e *entry) error {
	mode := os.FileMode(0644)
	if e.Mode == "100755" {
		mode = 0755
	}
	if err := os.Chmod(out, t.perm(mode)); err != nil {
		return fail("io", err)
	}
	return nil
}

// publish renames the finished tree to dest without replacing anything there. A read-only tree's
// own root is sealed only after the rename, because macOS 15 refuses to move a directory without
// write permission to another parent; everything below it is sealed before.
func (t *tree) publish(dest string) error {
	if t.readOnly {
		if err := os.Chmod(t.root, 0700); err != nil {
			return fail("io", err)
		}
	}
	if err := renameExclusive(t.root, dest); err != nil {
		if errors.Is(err, fs.ErrExist) {
			return failf("destination_exists", "destination %s already exists", dest)
		}
		return failf("io", "cannot publish %s: %v", dest, err)
	}
	if t.readOnly {
		if err := os.Chmod(dest, 0555); err != nil {
			return failf("io", "published %s but could not seal it: %v", dest, err)
		}
	}
	return nil
}
