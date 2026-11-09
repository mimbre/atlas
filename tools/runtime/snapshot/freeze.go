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
	"time"
)

var (
	savedTurn = regexp.MustCompile(`^turn-[0-9a-f]{16}$`)
	// cloneFile creates one file of a packet tree; tests replace it to force the streamed copy.
	cloneFile = clone
	// afterFolderScan runs between the scan of the author folder and the copy; tests change the folder there.
	afterFolderScan = func() {}
)

// ended are the turn states after which a turn's folder may be frozen.
var ended = []string{"finished", "stopped", "killed"}

// packetRepository is one repository of a packet: exactly what submit would send for it.
type packetRepository struct {
	Path         string        `json:"path"`
	Repository   string        `json:"repository"`
	BaseRevision string        `json:"base_revision"`
	State        string        `json:"state"`
	Fingerprint  string        `json:"fingerprint"`
	Entries      []changeEntry `json:"entries"`
}

type packetLink struct {
	PacketID    string `json:"packet_id"`
	Fingerprint string `json:"fingerprint"`
}

type incompleteDiff struct {
	Path   string `json:"path"`
	Reason string `json:"reason"`
}

// packet is packet.json, the metadata of one frozen review packet.
type packet struct {
	Version         int                `json:"version"`
	PacketID        string             `json:"packet_id"`
	Previous        *packetLink        `json:"previous"`
	Fingerprint     string             `json:"fingerprint"`
	SnapshotID      string             `json:"snapshot_id"`
	CreatedAt       string             `json:"created_at"`
	Author          map[string]any     `json:"author"`
	Tree            string             `json:"tree"`
	Findings        string             `json:"findings"`
	Repositories    []packetRepository `json:"repositories"`
	Outside         []string           `json:"outside"`
	IncompleteDiffs []incompleteDiff   `json:"incomplete_diffs"`
	Preparation     map[string]any     `json:"preparation"`
}

// packetFingerprint is the identity Flow's decisions apply to: "fpr_" + the SHA-256 of
// {"repositories":[{"fingerprint","path","repository"}…],"snapshot_id","version":1}, every
// repository included and sorted by path, in the encoding of manifest.canonical.
func packetFingerprint(snapshotID string, repositories []packetRepository) string {
	sorted := slices.Clone(repositories)
	slices.SortFunc(sorted, func(a, b packetRepository) int { return strings.Compare(a.Path, b.Path) })
	var b bytes.Buffer
	b.WriteString(`{"repositories":[`)
	for i, r := range sorted {
		if i > 0 {
			b.WriteByte(',')
		}
		field(&b, `{"fingerprint":`, r.Fingerprint)
		field(&b, `,"path":`, r.Path)
		field(&b, `,"repository":`, r.Repository)
		b.WriteByte('}')
	}
	b.WriteByte(']')
	field(&b, `,"snapshot_id":`, snapshotID)
	b.WriteString(`,"version":1}`)
	sum := sha256.Sum256(b.Bytes())
	return "fpr_" + hex.EncodeToString(sum[:])
}

// PacketDir is where Runtime keeps the authoritative records of packet id.
func PacketDir(home, id string) string { return filepath.Join(home, "packets", id) }

// Freeze copies the materialized folder dest, after the ended turn that ran in it, into the new
// review packet folder at path: a read-only tree recorded as a materialization of the same
// snapshot, packet.json, diff.json and an empty findings folder. The authoritative packet.json and
// diff.json are kept under <home>/packets/<id>/. previous, when set, names the packet this one
// follows. It runs offline under the folder's lock and writes nothing to dest or its baseline.
// A repeat with the same packet ID and arguments returns the recorded packet.
func Freeze(home, dest, turn, path, id, previous string) (map[string]any, error) {
	started := time.Now()
	switch {
	case !changeID.MatchString(id):
		return nil, errors.New("packet ID must be a lowercase UUID")
	case previous != "" && !changeID.MatchString(previous):
		return nil, errors.New("previous packet ID must be a lowercase UUID")
	case previous == id:
		return nil, fmt.Errorf("packet %s cannot follow itself; --previous names an earlier packet", id)
	case !savedTurn.MatchString(turn):
		return nil, errors.New("turn must be turn-<16 lowercase hex characters>")
	}
	home, err := filepath.EvalSymlinks(home)
	if err != nil {
		return nil, err
	}
	target, err := packetPath(path)
	if err != nil {
		return nil, err
	}
	if existing, err := repeated(home, dest, turn, target, id, previous); existing != nil || err != nil {
		return existing, err
	}

	f, err := openFolder(home, dest)
	if err != nil {
		return nil, err
	}
	if _, err = os.Lstat(target); err == nil {
		return nil, fmt.Errorf("packet folder %s already exists; a packet is frozen into a new path", target)
	} else if !errors.Is(err, fs.ErrNotExist) {
		return nil, err
	}
	if within(f.dest, target) || within(target, f.dest) {
		return nil, fmt.Errorf("packet folder %s overlaps the folder %s; freeze into a path outside it", target, f.dest)
	}
	if within(home, target) || within(target, home) {
		return nil, fmt.Errorf("packet folder %s overlaps the Runtime home %s; freeze into a path outside it", target, home)
	}
	for dir := filepath.Dir(target); ; dir = filepath.Dir(dir) {
		if _, err := os.Lstat(filepath.Join(dir, ".git")); err == nil {
			return nil, fmt.Errorf("packet folder %s cannot be inside a Git work tree (%s)", target, dir)
		} else if !errors.Is(err, fs.ErrNotExist) {
			return nil, err
		}
		if dir == filepath.Dir(dir) {
			break
		}
	}

	lock, err := hold(f.dest, "freeze", "nothing was frozen")
	if err != nil {
		return nil, err
	}
	defer lock.Close()
	author, err := endedTurn(home, turn, f.dest)
	if err != nil {
		return nil, err
	}
	var link *packetLink
	if previous != "" {
		earlier, err := loadPacket(home, previous)
		if err != nil {
			return nil, err
		}
		link = &packetLink{PacketID: earlier.PacketID, Fingerprint: earlier.Fingerprint}
	}

	// The author folder's content, as submit would send it.
	changes, err := f.changes(nil, false)
	if err != nil {
		return nil, err
	}
	scanned, outside, err := f.packetRepositories(changes)
	if err != nil {
		return nil, err
	}
	afterFolderScan()

	free, _ := freeBytes(filepath.Dir(target))
	staging, err := os.MkdirTemp(filepath.Dir(target), ".atlas-packet-*")
	if err != nil {
		return nil, err
	}
	published := false
	defer func() {
		if !published {
			remove(staging)
		}
	}()
	cost, err := copyTree(f.dest, filepath.Join(staging, "tree"))
	if err != nil {
		return nil, err
	}
	if err = renameExclusive(staging, target); err != nil {
		if errors.Is(err, fs.ErrExist) {
			return nil, fmt.Errorf("packet folder %s already exists; a packet is frozen into a new path", target)
		}
		return nil, err
	}
	// Until the packet is recorded under the home, a failure removes the folder and its records.
	tree := filepath.Join(target, "tree")
	committed := false
	defer func() {
		if !committed {
			remove(target)
			os.Remove(recordPath(home, tree))
			os.RemoveAll(preparationDir(home, tree))
		}
	}()
	published = true
	if tree, err = materialized(tree); err != nil {
		return nil, err
	}
	target = filepath.Dir(tree)
	if err = writeRecord(home, tree, map[string]string{"destination": tree, "snapshot_id": f.id, "packet_id": id,
		"materialized_at": time.Now().UTC().Format(time.RFC3339)}); err != nil {
		return nil, err
	}
	if p := f.preparation; p != nil {
		if err = copyPreparation(home, p, tree); err != nil {
			return nil, err
		}
	}

	// The tree, scanned as a recorded folder, must hold exactly what was scanned in dest.
	t, err := openFolder(home, tree)
	if err != nil {
		return nil, err
	}
	frozen, err := t.changes(nil, true)
	if err != nil {
		return nil, err
	}
	repositories, frozenOutside, err := t.packetRepositories(frozen)
	if err != nil {
		return nil, err
	}
	if !jsonEqual(repositories, scanned) || !slices.Equal(frozenOutside, outside) {
		return nil, fmt.Errorf("folder %s changed during freeze; nothing was frozen, run the command again", f.dest)
	}
	report := t.report(frozen)
	diff, err := json.Marshal(report)
	if err != nil {
		return nil, err
	}
	incomplete := []incompleteDiff{}
	for _, c := range frozen {
		switch {
		case c.Binary:
			incomplete = append(incomplete, incompleteDiff{c.Path, "binary"})
		case strings.HasPrefix(c.Note, "larger than"):
			incomplete = append(incomplete, incompleteDiff{c.Path, "larger_than_1_mib"})
		case strings.HasPrefix(c.Note, "more than"):
			incomplete = append(incomplete, incompleteDiff{c.Path, "more_than_2000_lines"})
		}
	}
	summary, _ := report["preparation"].(map[string]any)
	author["dest"] = f.dest
	metadata, err := json.Marshal(packet{Version: 1, PacketID: id, Previous: link, Fingerprint: packetFingerprint(f.id, repositories),
		SnapshotID: f.id, CreatedAt: time.Now().UTC().Format(time.RFC3339), Author: author, Tree: tree,
		Findings: filepath.Join(target, "findings"), Repositories: repositories, Outside: outside, IncompleteDiffs: incomplete, Preparation: summary})
	if err != nil {
		return nil, err
	}

	if err = os.Chmod(target, 0700); err != nil {
		return nil, err
	}
	if err = os.Mkdir(filepath.Join(target, "findings"), 0700); err != nil {
		return nil, err
	}
	for name, data := range map[string][]byte{"packet.json": metadata, "diff.json": diff} {
		if err = readOnly(filepath.Join(target, name), data); err != nil {
			return nil, err
		}
	}
	if err = os.Chmod(target, 0555); err != nil {
		return nil, err
	}
	if err = recordPacket(home, id, metadata, diff); err != nil {
		if errors.Is(err, fs.ErrExist) {
			return nil, fmt.Errorf("packet ID %s was used by a concurrent freeze; nothing was frozen", id)
		}
		return nil, err
	}
	committed = true

	result, err := decodePacket(metadata)
	if err != nil {
		return nil, err
	}
	after, _ := freeBytes(target)
	cost["elapsed_ms"] = time.Since(started).Milliseconds()
	cost["free_bytes_before"], cost["free_bytes_after"], cost["disk_used_bytes"] = free, after, free-after
	result["state"], result["packet"], result["cost"] = "frozen", target, cost
	return result, nil
}

// packetPath is path's absolute form below its resolved parent, which must exist.
func packetPath(path string) (string, error) {
	path, err := filepath.Abs(path)
	if err != nil {
		return "", err
	}
	parent, err := filepath.EvalSymlinks(filepath.Dir(path))
	if err == nil {
		var info os.FileInfo
		if info, err = os.Stat(parent); err == nil && !info.IsDir() {
			err = errors.New("not a directory")
		}
	}
	if err != nil {
		return "", fmt.Errorf("the parent of packet folder %s must be an existing directory: %v", path, reason(err))
	}
	return filepath.Join(parent, filepath.Base(path)), nil
}

// repeated returns the recorded packet id when this request repeats its freeze; another request
// under a recorded ID is a conflict. It returns nothing when the ID is unused.
func repeated(home, dest, turn, target, id, previous string) (map[string]any, error) {
	data, err := os.ReadFile(filepath.Join(PacketDir(home, id), "packet.json"))
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	} else if err != nil {
		return nil, fmt.Errorf("cannot read packet %s: %v", id, reason(err))
	}
	recorded, err := decodePacket(data)
	if err != nil {
		return nil, fmt.Errorf("invalid packet record %s: %v", id, err)
	}
	if canonical, err := materialized(dest); err == nil {
		dest = canonical
	} else if dest, err = packetPath(dest); err != nil {
		return nil, err
	}
	if canonical, err := materialized(target); err == nil {
		target = canonical
	}
	author, _ := recorded["author"].(map[string]any)
	link, _ := recorded["previous"].(map[string]any)
	was := ""
	if link != nil {
		was, _ = link["packet_id"].(string)
	}
	tree, _ := recorded["tree"].(string)
	if author["dest"] != dest || author["turn_id"] != turn || filepath.Dir(tree) != target || was != previous {
		return nil, fmt.Errorf("packet ID %s was already used to freeze turn %v of %v into %s with previous %q; use a new packet ID", id, author["turn_id"], author["dest"], filepath.Dir(tree), was)
	}
	recorded["state"], recorded["packet"] = "existing", filepath.Dir(tree)
	return recorded, nil
}

func decodePacket(data []byte) (map[string]any, error) {
	var p map[string]any
	if err := json.Unmarshal(data, &p); err != nil {
		return nil, err
	}
	return p, nil
}

// loadPacket reads the recorded packet id.
func loadPacket(home, id string) (*packet, error) {
	data, err := os.ReadFile(filepath.Join(PacketDir(home, id), "packet.json"))
	if errors.Is(err, fs.ErrNotExist) {
		return nil, fmt.Errorf("previous packet %s does not exist under %s", id, filepath.Join(home, "packets"))
	} else if err != nil {
		return nil, fmt.Errorf("cannot read packet %s: %v", id, reason(err))
	}
	var p packet
	if json.Unmarshal(data, &p) != nil || p.PacketID != id || !fingerprintID.MatchString(p.Fingerprint) {
		return nil, fmt.Errorf("invalid packet record %s", id)
	}
	return &p, nil
}

// endedTurn reads turn's saved record, which must have run in dest and ended, and returns the
// identity a packet records for its author.
func endedTurn(home, turn, dest string) (map[string]any, error) {
	path := filepath.Join(home, "turns", turn, "turn.json")
	data, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, fmt.Errorf("unknown turn %s", turn)
	} else if err != nil {
		return nil, fmt.Errorf("cannot read turn %s: %v", turn, reason(err))
	}
	var run map[string]any
	if json.Unmarshal(data, &run) != nil || run["id"] != turn {
		return nil, fmt.Errorf("invalid saved turn %s", turn)
	}
	cwd, _ := run["cwd"].(string)
	if canonical, err := materialized(cwd); cwd == "" || cwd != dest && (err != nil || canonical != dest) {
		return nil, fmt.Errorf("turn %s ran in %q, not in %s; freeze the folder its author turn ran in", turn, cwd, dest)
	}
	if state, _ := run["state"].(string); !slices.Contains(ended, state) {
		return nil, fmt.Errorf("turn %s is %v; only a finished, stopped or killed turn's folder is frozen", turn, run["state"])
	}
	author := map[string]any{"turn_id": turn}
	for _, key := range []string{"source_turn_id", "worker_id", "backend", "model", "state"} {
		author[key] = run[key]
	}
	return author, nil
}

// packetRepositories converts changes into every repository's submit entries and fingerprint, in
// manifest order, and lists the paths outside every repository. Content submit refuses is refused.
func (f *folder) packetRepositories(changes []change) ([]packetRepository, []string, error) {
	repositories, outside := []packetRepository{}, []string{}
	for _, c := range changes {
		if c.Repository == "" {
			if c.NewKind == "other" {
				return nil, nil, fmt.Errorf("cannot freeze %s: only files, symlinks and directories can be frozen, not a FIFO, socket or device", c.Path)
			}
			outside = append(outside, c.Path)
		}
	}
	for _, r := range f.m.Repositories {
		mine := []change{}
		for _, c := range changes {
			if within(r.Path, c.Path) {
				mine = append(mine, c)
			}
		}
		if err := f.ancestors(r); err != nil {
			return nil, nil, err
		}
		entries, err := f.convert(r, mine, "")
		if err != nil {
			return nil, nil, err
		}
		body, err := json.Marshal(map[string]any{"change_id": strings.Repeat("0", 36), "snapshot_id": f.id, "repository": r.Repository, "base_revision": r.Revision, "entries": entries})
		if err != nil {
			return nil, nil, err
		}
		if len(body) > maxChange {
			return nil, nil, fmt.Errorf("the change request for %s would be %d bytes, over Code's 1 MiB limit; it could not be submitted, so nothing was frozen", r.Path, len(body))
		}
		state := "changed"
		if len(entries) == 0 {
			state = "clean"
		}
		repositories = append(repositories, packetRepository{Path: r.Path, Repository: r.Repository, BaseRevision: r.Revision, State: state,
			Fingerprint: fingerprint(f.id, r.Repository, r.Revision, entries), Entries: entries})
	}
	return repositories, outside, nil
}

func jsonEqual(a, b any) bool {
	left, lerr := json.Marshal(a)
	right, rerr := json.Marshal(b)
	return lerr == nil && rerr == nil && bytes.Equal(left, right)
}

// copyTree builds the new read-only tree to from the folder from: directories, symlinks and
// regular files, each file a clone or, where the filesystem cannot clone, a streamed copy. Nothing
// is followed, and anything else is refused. It returns what the copy cost.
func copyTree(from, to string) (map[string]any, error) {
	t, err := newTree(to, true)
	if err != nil {
		return nil, err
	}
	var files, cloned, copied, size, copiedBytes int64
	err = filepath.WalkDir(from, func(name string, d fs.DirEntry, err error) error {
		if err != nil {
			return fmt.Errorf("cannot freeze %s: %v", name, err)
		}
		if name == from {
			return nil
		}
		rel, err := filepath.Rel(from, name)
		if err != nil {
			return err
		}
		rel = filepath.ToSlash(rel)
		switch kind(d) {
		case "directory":
			return t.mkdirs(rel)
		case "symlink":
			link, err := os.Readlink(name)
			if err != nil {
				return err
			}
			return t.symlink(rel, link)
		case "file":
			info, err := d.Info()
			if err != nil {
				return err
			}
			if err = t.mkdirs(parent(rel)); err != nil {
				return err
			}
			files, size = files+1, size+info.Size()
			out := filepath.Join(t.root, filepath.FromSlash(rel))
			err = cloneFile(name, out)
			if errors.Is(err, syscall.ENOTSUP) || errors.Is(err, syscall.EOPNOTSUPP) || errors.Is(err, syscall.EXDEV) {
				n, err := t.stream(rel, name)
				copied, copiedBytes = copied+1, copiedBytes+n
				return err
			} else if err != nil {
				return err
			}
			cloned++
			// A clone keeps the original's mode; the tree keeps only its read and execute bits.
			if info, err = os.Lstat(out); err != nil {
				return err
			}
			if !info.Mode().IsRegular() {
				return fmt.Errorf("cannot freeze %s: is no longer a regular file", rel)
			}
			return os.Chmod(out, t.perm(info.Mode().Perm()))
		}
		return fmt.Errorf("cannot freeze %s: only files, symlinks and directories can be frozen, not a FIFO, socket or device", rel)
	})
	if err != nil {
		return nil, err
	}
	if err = t.finish(); err != nil {
		return nil, err
	}
	return map[string]any{"files": files, "bytes": size, "cloned_files": cloned, "copied_files": copied, "copied_bytes": copiedBytes}, nil
}

// stream copies the regular file name into the tree at path, keeping its execute bits.
func (t *tree) stream(path, name string) (int64, error) {
	source, err := os.OpenFile(name, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if err != nil {
		return 0, fmt.Errorf("cannot freeze %s: %v", path, reason(err))
	}
	defer source.Close()
	info, err := source.Stat()
	if err != nil {
		return 0, err
	}
	if !info.Mode().IsRegular() {
		return 0, fmt.Errorf("cannot freeze %s: is no longer a regular file", path)
	}
	out, err := t.create(path)
	if err != nil {
		return 0, err
	}
	n, err := io.Copy(out, source)
	if err == nil {
		err = out.Chmod(t.perm(info.Mode().Perm()))
	}
	if cerr := out.Close(); err == nil {
		err = cerr
	}
	return n, err
}

// copyPreparation records the preparation p of the author folder for the packet tree, so status,
// diff and submit of the tree skip exactly the outputs they skip in the folder.
func copyPreparation(home string, p *Preparation, tree string) error {
	moved := *p
	moved.Destination, moved.excluded = tree, nil
	if p.Previous != nil {
		previous := *p.Previous
		previous.Destination, previous.excluded = tree, nil
		moved.Previous = &previous
	}
	body, err := json.Marshal(moved)
	if err != nil {
		return err
	}
	if err = os.MkdirAll(preparationDir(home, tree), 0700); err != nil {
		return err
	}
	return replace(PreparationResult(home, tree), append(body, '\n'), 0600)
}

// recordPacket publishes <home>/packets/<id>/ with packet.json, diff.json and an empty findings
// folder in one exclusive rename; an existing record is never replaced.
func recordPacket(home, id string, metadata, diff []byte) error {
	parent := filepath.Join(home, "packets")
	if err := os.MkdirAll(parent, 0700); err != nil {
		return err
	}
	staging, err := os.MkdirTemp(parent, ".staging-")
	if err != nil {
		return err
	}
	defer func() {
		if staging != "" {
			remove(staging)
		}
	}()
	if err = os.Mkdir(filepath.Join(staging, "findings"), 0700); err != nil {
		return err
	}
	for name, data := range map[string][]byte{"packet.json": metadata, "diff.json": diff} {
		if err = readOnly(filepath.Join(staging, name), data); err != nil {
			return err
		}
	}
	if err = renameExclusive(staging, PacketDir(home, id)); err != nil {
		return err
	}
	staging = ""
	return os.Chmod(PacketDir(home, id), 0555)
}

// RecordedPacket is the packet ID Freeze recorded for the materialized folder dest, or "" when dest
// is not a packet tree.
func RecordedPacket(home, dest string) (string, error) {
	path := recordPath(home, dest)
	data, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("cannot read materialization record %s: %v", path, reason(err))
	}
	var r struct {
		PacketID *string `json:"packet_id"`
	}
	if json.Unmarshal(data, &r) != nil || r.PacketID != nil && !changeID.MatchString(*r.PacketID) {
		return "", fmt.Errorf("invalid materialization record %s for %s", path, dest)
	}
	if r.PacketID == nil {
		return "", nil
	}
	return *r.PacketID, nil
}

// VerifiedPacket checks that tree is the tree of a frozen packet and still holds exactly what was
// frozen: its record names the packet, the packet's metadata files equal the authoritative copies
// under the home, and the tree's content has the packet's fingerprint. It returns the packet folder,
// its findings folder, the packet ID and the fingerprint.
func VerifiedPacket(home, tree string) (map[string]any, error) {
	t, err := openFolder(home, tree)
	if err != nil {
		return nil, err
	}
	id, err := RecordedPacket(home, t.dest)
	if err != nil {
		return nil, err
	}
	if id == "" {
		return nil, fmt.Errorf("%s is not the tree of a review packet; review the tree that snapshot freeze made", t.dest)
	}
	mismatch := func(what string) error {
		return fmt.Errorf("review packet %s does not match its record under %s: %s; freeze a new packet", filepath.Dir(t.dest), PacketDir(home, id), what)
	}
	data, err := os.ReadFile(filepath.Join(PacketDir(home, id), "packet.json"))
	if err != nil {
		return nil, fmt.Errorf("cannot read packet %s: %v", id, reason(err))
	}
	var p packet
	if json.Unmarshal(data, &p) != nil || p.PacketID != id || !fingerprintID.MatchString(p.Fingerprint) {
		return nil, fmt.Errorf("invalid packet record %s", id)
	}
	dir := filepath.Dir(t.dest)
	if p.Tree != t.dest || p.SnapshotID != t.id || p.Findings != filepath.Join(dir, "findings") {
		return nil, mismatch("the record names another tree, snapshot or findings folder")
	}
	for _, name := range []string{"packet.json", "diff.json"} {
		recorded, err := os.ReadFile(filepath.Join(PacketDir(home, id), name))
		if err != nil {
			return nil, fmt.Errorf("cannot read packet %s: %v", id, reason(err))
		}
		if present, err := os.ReadFile(filepath.Join(dir, name)); err != nil || !bytes.Equal(present, recorded) {
			return nil, mismatch(name + " was changed or removed")
		}
	}
	if info, err := os.Lstat(p.Findings); err != nil || !info.IsDir() {
		return nil, mismatch("findings is not a directory")
	}
	changes, err := t.changes(nil, false)
	if err != nil {
		return nil, err
	}
	repositories, outside, err := t.packetRepositories(changes)
	if err != nil {
		return nil, err
	}
	if current := packetFingerprint(t.id, repositories); current != p.Fingerprint || !slices.Equal(outside, p.Outside) {
		return nil, mismatch(fmt.Sprintf("the tree was modified after the freeze (fingerprint %s, frozen %s)", current, p.Fingerprint))
	}
	return map[string]any{"packet": dir, "findings": p.Findings, "packet_id": id, "fingerprint": p.Fingerprint}, nil
}
