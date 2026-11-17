package snapshot

// Uploaded bases (S5c P6). The core reads a client's base stream into <home>/bases/.staging-*/
// (entries.json, the stream's line 1, and blobs/<sha256>); base-import turns that into a read-only,
// content-addressed baseline with a Runtime-owned version 3 manifest, and MaterializeBaseline builds
// a work folder from any complete baseline (v2 or v3). Neither ever contacts Code or runs Git.

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
	"slices"
	"strconv"
	"strings"
	"syscall"
)

// maxBaseLine bounds entries.json, line 1 of a base stream (B7: at most 64 MiB).
const maxBaseLine int64 = 64 << 20

// beforeMaterializePublish runs between MaterializeBaseline's destination check and its exclusive
// rename; the race test creates the destination there. Like afterFolderScan, only tests change it.
var beforeMaterializePublish = func(string) {}

// baseEntry is one entry of a version 3 manifest: a file or symlink at path, relative to its root.
type baseEntry struct {
	Kind   string  `json:"kind"`
	Mode   string  `json:"mode"`
	Path   string  `json:"path"`
	Root   string  `json:"root"`
	SHA256 string  `json:"sha256"`
	Size   int64   `json:"size"`
	Target *string `json:"target,omitempty"`
}

// baseManifest is the Runtime-owned version 3 manifest of an uploaded base (B9). It names no Code
// repository or revision. Its canonical JSON is the file manifest.json, and baseline_id is
// sha256:<hex> of exactly those bytes.
type baseManifest struct {
	Entries []baseEntry `json:"entries"`
	Roots   []struct {
		Root string `json:"root"`
	} `json:"roots"`
	Version int `json:"version"`
}

// canonical is the manifest's JSON with sorted keys, no whitespace and the string escaping of
// field (as for version 2): {"entries":[…],"roots":[{"root":…}],"version":3}, roots sorted by
// root and entries by root then path, in byte order.
func (b *baseManifest) canonical() []byte {
	var out bytes.Buffer
	out.WriteString(`{"entries":[`)
	for i, e := range b.Entries {
		if i > 0 {
			out.WriteByte(',')
		}
		field(&out, `{"kind":`, e.Kind)
		field(&out, `,"mode":`, e.Mode)
		field(&out, `,"path":`, e.Path)
		field(&out, `,"root":`, e.Root)
		field(&out, `,"sha256":`, e.SHA256)
		out.WriteString(`,"size":` + strconv.FormatInt(e.Size, 10))
		if e.Target != nil {
			field(&out, `,"target":`, *e.Target)
		}
		out.WriteByte('}')
	}
	out.WriteString(`],"roots":[`)
	for i, r := range b.Roots {
		if i > 0 {
			out.WriteByte(',')
		}
		field(&out, `{"root":`, r.Root)
		out.WriteByte('}')
	}
	out.WriteString(`],"version":3}`)
	return out.Bytes()
}

// sort puts roots and entries in canonical order.
func (b *baseManifest) sort() {
	slices.SortFunc(b.Roots, func(x, y struct {
		Root string `json:"root"`
	}) int {
		return strings.Compare(x.Root, y.Root)
	})
	slices.SortFunc(b.Entries, func(x, y baseEntry) int {
		if c := strings.Compare(x.Root, y.Root); c != 0 {
			return c
		}
		return strings.Compare(x.Path, y.Path)
	})
}

// internal is the manifest as the rest of the package reads one: each root a "repository" whose
// path and name are the root, and each entry at its full path root/path. Version stays 3, so the
// Code-shaped paths (freeze, findings, discard) can tell an uploaded base apart.
func (b *baseManifest) internal(id string) *manifest {
	m := &manifest{Version: 3, SnapshotID: id, Repositories: []repository{}, Entries: []entry{}}
	for _, r := range b.Roots {
		m.Repositories = append(m.Repositories, repository{Path: r.Root, Repository: r.Root})
	}
	for _, e := range b.Entries {
		m.Entries = append(m.Entries, entry{Kind: e.Kind, Mode: e.Mode, Path: e.Root + "/" + e.Path, Repository: e.Root,
			SHA256: e.SHA256, Size: e.Size, Target: e.Target})
	}
	return m
}

// uploaded checks the safety rules of an uploaded base's internal manifest m (B8): every root one
// normalized name, every path normalized without a .git segment, nothing inside a file or symlink,
// every symlink resolving inside its root, and no two names that differ only in case.
func uploaded(m *manifest) (map[string]*entry, error) {
	if len(m.Repositories) == 0 {
		return nil, errors.New("base has no roots")
	}
	for _, r := range m.Repositories {
		if !safe(r.Path) || strings.Contains(r.Path, "/") {
			return nil, fmt.Errorf("unsafe root %q: a root is one normalized name, without .git, backslashes or control characters", r.Path)
		}
	}
	entries, err := m.safety()
	if err != nil {
		return nil, err
	}
	folded := map[string]string{}
	name := func(path string) error {
		key := strings.ToLower(path)
		if other, ok := folded[key]; ok && other != path {
			return fmt.Errorf("unsafe base: %q and %q differ only in case", other, path)
		}
		folded[key] = path
		return nil
	}
	for _, r := range m.Repositories {
		if err := name(r.Path); err != nil {
			return nil, err
		}
	}
	for _, e := range m.Entries {
		for dir := parent(e.Path); dir != ""; dir = parent(dir) {
			if err := name(dir); err != nil {
				return nil, err
			}
		}
		if err := name(e.Path); err != nil {
			return nil, err
		}
	}
	return entries, nil
}

// loadBaseManifest decodes the version 3 manifest.json raw strictly; it must be canonical, so that
// one tree has exactly one baseline_id.
func loadBaseManifest(raw []byte, id string) (*manifest, map[string]*entry, error) {
	var b baseManifest
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&b); err != nil || decoder.More() || b.Version != 3 {
		return nil, nil, fmt.Errorf("invalid baseline manifest: not a version 3 manifest: %v", err)
	}
	b.sort()
	if !bytes.Equal(b.canonical(), raw) {
		return nil, nil, errors.New("invalid baseline manifest: version 3 manifest is not canonical")
	}
	m := b.internal(id)
	entries, err := uploaded(m)
	if err != nil {
		return nil, nil, fmt.Errorf("invalid baseline manifest: %v", err)
	}
	return m, entries, nil
}

// ImportBase builds the read-only baseline of the base the core staged in staging, below the
// Runtime home: staging/entries.json is line 1 of the base stream ({"format":"atlas-base",
// "version":1,"roots":[{"root","entries":[…]}]}, entries in the change-set write shape) and
// staging/blobs/<sha256> holds each file's content. It applies the safety rules, re-hashes every
// blob, and publishes <home>/snapshots/<hex>/{tree/, manifest.json (version 3), complete} with an
// exclusive rename, or reuses a complete baseline of the same manifest. It writes nothing outside
// <home>/snapshots and never writes to staging.
func ImportBase(home, staging string) (map[string]any, error) {
	home, err := canonicalDirectory(home)
	if err != nil {
		return nil, fmt.Errorf("Runtime home: %v", err)
	}
	staging, err = canonicalDirectory(staging)
	if err != nil {
		return nil, fmt.Errorf("staging: %v", err)
	}
	b, err := readBaseLine(filepath.Join(staging, "entries.json"))
	if err != nil {
		return nil, err
	}
	canonical := b.canonical()
	sum := sha256.Sum256(canonical)
	id := "sha256:" + hex.EncodeToString(sum[:])
	m := b.internal(id)
	entries, err := uploaded(m)
	if err != nil {
		return nil, fmt.Errorf("invalid base: %v", err)
	}
	blobs := filepath.Join(staging, "blobs")
	var files, size int64
	verified := map[string]bool{}
	for _, e := range m.Entries {
		if e.Kind != "file" {
			continue
		}
		files, size = files+1, size+e.Size
		if !verified[e.SHA256] {
			if err = checkFile(filepath.Join(blobs, e.SHA256), &e); err != nil {
				return nil, fmt.Errorf("invalid base: blob %s of %q: %v", e.SHA256, e.Path, err)
			}
			verified[e.SHA256] = true
		}
	}
	result := map[string]any{"baseline_id": id, "files": files, "bytes": size}

	baseline := filepath.Join(home, "snapshots", hex.EncodeToString(sum[:]))
	if reuse, err := complete(baseline); err != nil {
		return nil, err
	} else if reuse {
		if _, _, err = loadBaseline(baseline, id); err != nil {
			return nil, err
		}
		return result, nil
	}
	if err = os.MkdirAll(filepath.Dir(baseline), 0700); err != nil {
		return nil, err
	}
	building, err := os.MkdirTemp(filepath.Dir(baseline), ".staging-*")
	if err != nil {
		return nil, err
	}
	defer func() {
		if building != "" {
			remove(building)
		}
	}()
	t, err := newTree(filepath.Join(building, "tree"), true)
	if err != nil {
		return nil, err
	}
	for _, r := range m.Repositories {
		if err = t.mkdirs(r.Path); err != nil {
			return nil, err
		}
	}
	for _, e := range m.Entries {
		if e.Kind == "symlink" {
			err = t.symlink(e.Path, *e.Target)
		} else {
			err = t.importBlob(filepath.Join(blobs, e.SHA256), entries[e.Path])
		}
		if err != nil {
			return nil, err
		}
	}
	if err = t.finish(); err != nil {
		return nil, err
	}
	if err = readOnly(filepath.Join(building, "manifest.json"), canonical); err != nil {
		return nil, err
	}
	if err = readOnly(filepath.Join(building, "complete"), []byte(id+"\n")); err != nil {
		return nil, err
	}
	err = renameExclusive(building, baseline)
	if err == nil {
		building = ""
	} else if !errors.Is(err, fs.ErrExist) {
		return nil, err
	} else if ok, cerr := complete(baseline); !ok {
		// Otherwise a concurrent import published the same baseline first.
		return nil, errors.Join(err, cerr)
	}
	if err = seal(baseline); err != nil {
		return nil, err
	}
	return result, nil
}

// readBaseLine reads and checks the line 1 file name: one JSON object of the B3 shape, with
// nothing after its newline, every entry a write. The roots and entries come back canonically sorted.
func readBaseLine(name string) (*baseManifest, error) {
	invalid := func(format string, args ...any) error {
		return fmt.Errorf("invalid base: entries.json: "+format, args...)
	}
	file, err := os.OpenFile(name, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if err != nil {
		return nil, fmt.Errorf("cannot read entries.json: %v", reason(err))
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, maxBaseLine+1))
	if err != nil {
		return nil, fmt.Errorf("cannot read entries.json: %v", reason(err))
	}
	if int64(len(data)) > maxBaseLine {
		return nil, invalid("larger than %d bytes", maxBaseLine)
	}
	if i := bytes.IndexByte(data, '\n'); i >= 0 && i != len(data)-1 {
		return nil, invalid("more than one line")
	}
	var line struct {
		Format  string `json:"format"`
		Version int    `json:"version"`
		Roots   []struct {
			Root    string            `json:"root"`
			Entries []json.RawMessage `json:"entries"`
		} `json:"roots"`
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err = decoder.Decode(&line); err != nil || decoder.More() {
		return nil, invalid("not one base object: %v", err)
	}
	if line.Format != "atlas-base" || line.Version != 1 || line.Roots == nil {
		return nil, invalid(`format must be "atlas-base", version 1, with roots`)
	}
	b := &baseManifest{Version: 3, Entries: []baseEntry{}}
	roots := map[string]bool{}
	for _, root := range line.Roots {
		if roots[root.Root] {
			return nil, invalid("duplicate root %q", root.Root)
		}
		roots[root.Root] = true
		b.Roots = append(b.Roots, struct {
			Root string `json:"root"`
		}{root.Root})
		seen := map[string]bool{}
		for _, raw := range root.Entries {
			e, op, err := changeSetEntry(raw)
			if err != nil {
				return nil, invalid("root %q: %v", root.Root, err)
			}
			if op != "write" {
				return nil, invalid("root %q: entry %q: a base holds writes only", root.Root, e.Path)
			}
			if seen[e.Path] {
				return nil, invalid("root %q: duplicate path %q", root.Root, e.Path)
			}
			seen[e.Path] = true
			if !safe(e.Path) {
				return nil, invalid("root %q: unsafe path %q", root.Root, e.Path)
			}
			full := entry{Kind: e.Kind, Mode: e.Mode, Path: root.Root + "/" + e.Path, SHA256: e.SHA256, Size: e.Size, Target: e.Target}
			if why := full.problem(root.Root); why != "" {
				return nil, invalid("root %q: entry %q: %s", root.Root, e.Path, why)
			}
			b.Entries = append(b.Entries, baseEntry{Kind: e.Kind, Mode: e.Mode, Path: e.Path, Root: root.Root, SHA256: e.SHA256, Size: e.Size, Target: e.Target})
		}
	}
	b.sort()
	return b, nil
}

// checkFile hashes the regular file name, never following a symlink, and refuses it unless its
// size and sha256 are e's.
func checkFile(name string, e *entry) error {
	file, err := os.OpenFile(name, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if err != nil {
		return fmt.Errorf("missing or unreadable: %v", reason(err))
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() {
		return errors.New("not a regular file")
	}
	hash := sha256.New()
	n, err := io.Copy(hash, file)
	if err != nil {
		return err
	}
	if n != e.Size || hex.EncodeToString(hash.Sum(nil)) != e.SHA256 {
		return fmt.Errorf("content has %d bytes and sha256 %x, not the entry's %d and %s", n, hash.Sum(nil), e.Size, e.SHA256)
	}
	return nil
}

// importBlob copies the verified blob name into the tree at e's path, as a clone where possible,
// and checks the copy itself, so the baseline holds exactly what was checked.
func (t *tree) importBlob(name string, e *entry) error {
	if err := t.mkdirs(parent(e.Path)); err != nil {
		return err
	}
	out := filepath.Join(t.root, filepath.FromSlash(e.Path))
	err := cloneFile(name, out)
	if errors.Is(err, syscall.ENOTSUP) || errors.Is(err, syscall.EOPNOTSUPP) || errors.Is(err, syscall.EXDEV) {
		_, err = t.stream(e.Path, name)
	}
	if err != nil {
		return fmt.Errorf("cannot copy blob %s of %q: %v", e.SHA256, e.Path, err)
	}
	if err = checkFile(out, e); err != nil {
		return fmt.Errorf("invalid base: blob %s of %q: %v", e.SHA256, e.Path, err)
	}
	return chmodEntry(out, t, e)
}

// MaterializeBaseline builds the new work folder dest from the complete baseline id under
// <home>/snapshots, version 2 or 3, and records dest as its materialization. dest must be a direct,
// not yet existing child of <home>/workers; the caller (workspace materialize) checks it is exactly
// the Runtime work folder. It is published with an exclusive rename, so a path created meanwhile is
// refused and left untouched. It never contacts Code or runs Git.
func MaterializeBaseline(home, id, dest string) (map[string]any, error) {
	home, err := canonicalDirectory(home)
	if err != nil {
		return nil, fail("io", fmt.Errorf("Runtime home: %v", err))
	}
	match := snapshotID.FindStringSubmatch(id)
	if match == nil {
		return nil, failf("baseline_missing", "baseline must be sha256:<64 lowercase hex characters>, not %q", id)
	}
	if !filepath.IsAbs(dest) || filepath.Clean(dest) != dest || filepath.Dir(dest) != filepath.Join(home, "workers") {
		return nil, failf("destination_not_allowed", "destination %s is not a folder directly in %s", dest, filepath.Join(home, "workers"))
	}
	if _, err = os.Lstat(dest); err == nil {
		return nil, failf("destination_exists", "destination %s already exists", dest)
	} else if !errors.Is(err, fs.ErrNotExist) {
		return nil, fail("io", err)
	}
	baseline := filepath.Join(home, "snapshots", match[1])
	m, _, err := loadBaseline(baseline, id)
	if err != nil {
		return nil, failf("baseline_missing", "no usable baseline for %s: %v", id, err)
	}
	staging, err := os.MkdirTemp(filepath.Dir(dest), ".atlas-snapshot-*")
	if err != nil {
		return nil, fail("io", err)
	}
	defer remove(staging)
	t, err := newTree(filepath.Join(staging, "tree"), false)
	if err != nil {
		return nil, fail("io", err)
	}
	for _, r := range m.Repositories {
		if err = t.mkdirs(r.Path); err != nil {
			return nil, fail("io", err)
		}
	}
	for i := range m.Entries {
		e := &m.Entries[i]
		if e.Kind == "symlink" {
			if err = t.symlink(e.Path, *e.Target); err != nil {
				return nil, fail("io", err)
			}
		} else if err = t.copyBase(e.Path, filepath.Join(baseline, "tree", filepath.FromSlash(e.Path)), e); err != nil {
			return nil, err
		}
	}
	if err = t.finish(); err != nil {
		return nil, fail("io", err)
	}
	beforeMaterializePublish(dest)
	if err = t.publish(dest); err != nil {
		return nil, err
	}
	// The folder is the work's now: a failed record is reported, never cleaned up.
	if err = record(home, dest, id); err != nil {
		return nil, failf("io", "published %s but could not record its baseline: %v", dest, err)
	}
	return map[string]any{"baseline_id": id, "destination": dest}, nil
}

// uploadedBase refuses op on dest when its recorded baseline is an uploaded base (version 3): the
// Code-shaped review packets do not apply to it (B13). Anything else, an unrecorded or unreadable
// folder included, is left to op's own checks.
func uploadedBase(home, dest, op string) error {
	canonical, err := materialized(dest)
	if err != nil {
		return nil
	}
	id, err := recorded(home, canonical)
	if err != nil {
		return nil
	}
	raw, err := os.ReadFile(filepath.Join(home, "snapshots", strings.TrimPrefix(id, "sha256:"), "manifest.json"))
	if err != nil {
		return nil
	}
	var version struct {
		Version *int `json:"version"`
	}
	if json.Unmarshal(raw, &version) == nil && version.Version != nil && *version.Version == 3 {
		return fmt.Errorf("cannot %s %s: it is built from an uploaded base; use from_work / get_frozen", op, canonical)
	}
	return nil
}
